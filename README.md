# boosterMTG

## Deploiement en production

Le workflow `.github/workflows/deploy.yml` valide le Dockerfile et la configuration
Compose, puis déploie sur le VPS après chaque push sur `main`.

### Préparer le VPS

- Installer Git, Docker et le plugin Docker Compose.
- Cloner ce dépôt dans le répertoire de déploiement.
- Créer dans ce répertoire un fichier `.env` contenant la configuration de production.
- Configurer l'accès Git du serveur au dépôt pour que `git pull` puisse fonctionner.
- Vérifier que l'utilisateur SSH peut accéder au répertoire et exécuter Docker.

Le dépôt doit contenir `Dockerfile`, un fichier Compose reconnu par Docker Compose
et `.env.example` pour que les vérifications CI passent.

### Configurer GitHub

Dans **Settings > Secrets and variables > Actions**, ajouter les secrets suivants :

- `SSH_HOST` : adresse ou nom d'hôte du VPS.
- `SSH_USER` : utilisateur SSH de déploiement.
- `SSH_PRIVATE_KEY` : clé privée SSH autorisée sur le VPS.
- `DEPLOY_PATH` : chemin absolu du dépôt cloné sur le VPS.
- `SSH_PORT` : port SSH, facultatif (22 par défaut).

Ne pas ajouter le fichier `.env` de production au dépôt. Le déploiement utilise celui
qui est déjà présent sur le VPS.