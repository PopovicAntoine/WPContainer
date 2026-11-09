# boosterMTG

Application WordPress + MariaDB conteneurisée (Docker Compose), construite et
déployée automatiquement par GitHub Actions sur une VM de test, avec supervision
Prometheus + Grafana.

## Architecture

| Service | Image | Rôle |
|---|---|---|
| `db` | `mariadb:11` | base de données (volume `db_data`, healthcheck) |
| `wordpress` | `ghcr.io/<compte>/wordpress-custom` | WordPress (PHP 8.3 + Apache) avec le thème et les plugins du dépôt (volume `wp_content`) |
| `proxy` | `nginx:stable` | reverse proxy, seul service publié (port 80) |

- Réseau `frontend` : proxy et WordPress. Réseau `backend` (interne) : la base n'est joignable que par WordPress.
- L'image `wordpress-custom` est construite à partir du `Dockerfile` : réglages PHP (`docker/uploads.ini`)
  et thème/plugins de `wp-content/`, synchronisés dans le volume à chaque démarrage (`docker/custom-entrypoint.sh`).
- Les mots de passe ne sont jamais dans le dépôt : ils viennent du fichier `.env`, écrit par le pipeline à partir des secrets GitHub.

## Déploiement continu

Le workflow `.github/workflows/deploy.yml` (« CI/CD WordPress ») se lance à chaque push sur `main`
ou manuellement (`workflow_dispatch`). Un seul déploiement s'exécute à la fois.

1. **lint** : contrôle du `Dockerfile` (hadolint), validation de Compose et de la supervision.
2. **build** : construction de l'image (buildx, cache GitHub Actions) et envoi vers GHCR avec les tags `latest` et `sha-<commit>`.
3. **deploy-test** : exécuté sur le runner auto-hébergé de la VM, environnement GitHub `test` :
   copie des fichiers dans `/opt/wordpress`, écriture du `.env`, `docker compose pull` puis `up -d --remove-orphans`,
   smokescreen test du site, contrôle de la supervision, nettoyage des anciennes images.

### Préparer la VM

- Docker et le plugin Docker Compose installés.
- Runner GitHub Actions auto-hébergé installé et enregistré sur le dépôt.
- L'utilisateur du runner appartient au groupe `docker` et peut écrire dans `/opt/wordpress`
  (ainsi que dans `/backup/wordpress` pour les sauvegardes).

### Configurer GitHub

Dans **Settings > Environments > test**, ajouter les secrets :

- `DB_PASSWORD` : mot de passe de l'utilisateur MariaDB `wp`.
- `DB_ROOT_PASSWORD` : mot de passe root de MariaDB.
- Les secrets de la supervision, décrits plus bas.

L'envoi de l'image vers GHCR utilise le `GITHUB_TOKEN` fourni automatiquement.

### Lancement manuel

```bash
cp .env.example .env     # puis remplacer les mots de passe (openssl rand -base64 24)
docker compose up -d
```

Le site répond sur http://localhost.

## Sauvegarde et restauration

Les scripts `backup.sh` et `restore.sh` sont déployés dans `/opt/wordpress` par le pipeline.

```bash
/opt/wordpress/backup.sh              # dump SQL + archive de wp-content + sommes de contrôle
/opt/wordpress/restore.sh latest      # restaure la sauvegarde la plus récente (demande confirmation)
/opt/wordpress/restore.sh 2026-10-28_023000 --yes
```

Les sauvegardes sont écrites dans `/backup/wordpress` et conservées 7 jours
(`BACKUP_DIR` et `RETENTION_DAYS` permettent de changer ces valeurs).
Planification quotidienne à 2 h 30 (cron) :

```
30 2 * * * /opt/wordpress/backup.sh >> /var/log/wp-backup.log 2>&1
```

## Supervision (Prometheus + Grafana)

La stack de supervision est déployée avec l'application par le même pipeline.
Elle est décrite dans `docker-compose.monitoring.yml` (activé par `COMPOSE_FILE`)
et configurée dans `monitoring/`.

| Composant | Rôle |
|---|---|
| Prometheus | collecte et stocke les métriques, évalue les règles d'alerte |
| Alertmanager | envoie les notifications (mail) |
| Grafana | tableau de bord « Vue d'ensemble » (provisionné par fichier) |
| node-exporter | métriques de la VM (CPU, mémoire, disque) |
| cAdvisor | métriques des containers (`db`, `wordpress`, `proxy`, ...) |
| mysqld-exporter | métriques MariaDB (connexions, requêtes, requêtes lentes) |
| blackbox-exporter | sonde HTTP sur le site, via le proxy nginx |

Les exporters rejoignent les réseaux existants : `backend` (base de données,
réseau interne) et `frontend` (sonde sur le proxy). Seul le port 80 du proxy
reste publié sur toutes les interfaces ; Prometheus, Alertmanager et Grafana
n'écoutent que sur `127.0.0.1` par défaut.



### Ce que fait le pipeline

- **lint** : valide Compose, la configuration Prometheus et Alertmanager (`promtool`, `amtool`),
  exécute les tests des règles d'alerte (`monitoring/prometheus/alert_rules_test.yml`) et vérifie le JSON des dashboards.
- **deploy-test** : copie `monitoring/`, écrit le `.env` et les fichiers de secrets
  (`/opt/wordpress/secrets/`, hors Git), démarre la stack, crée l'utilisateur MariaDB
  `exporter` (lecture seule), puis vérifie que toutes les cibles Prometheus sont `up`.

### Accès

| Service | Adresse (sur la VM) |
|---|---|
| Grafana | http://127.0.0.1:3000, dossier Supervision, tableau « Vue d'ensemble » |
| Prometheus | http://127.0.0.1:9090 (onglets Targets et Alerts) |
| Alertmanager | http://127.0.0.1:9093 |

Depuis un autre poste : par tunnel SSH (`ssh -L 3000:127.0.0.1:3000 utilisateur@vm`).

### Indicateurs et seuils d'alerte

| Service | Indicateur | Seuil |
|---|---|---|
| Site (via nginx) | disponibilité HTTP | échec pendant 1 min |
| Site (via nginx) | temps de réponse | > 2 s pendant 5 min |
| Site | certificat TLS (si HTTPS) | expire dans moins de 15 jours |
| MariaDB | service joignable | arrêt pendant 1 min |
| MariaDB | connexions utilisées | > 80 % du maximum |
| MariaDB | requêtes lentes | > 5 sur 5 min |
| Application | `db`, `wordpress`, `proxy` présents | moins de 3 services pendant 1 min |
| Containers | mémoire / redémarrages | > 85 % de la limite / > 3 en 10 min |
| VM | CPU / mémoire / disque | > 85 % / > 90 % / moins de 20 % libre |

### Tester les alertes

Dans `/opt/wordpress` :

```bash
docker compose stop db      # MariaDBDown puis WordPressDown (environ 1 min), mail envoyé
docker compose start db     # retour à la normale, mail de résolution
docker compose stop proxy   # WordPressDown et ServiceApplicatifAbsent
docker compose start proxy
```

La configuration de supervision est versionnée dans ce dépôt (rien à sauvegarder
en plus par `backup.sh`) ; les métriques de Prometheus sont conservées 15 jours
dans le volume `prometheus_data`.
