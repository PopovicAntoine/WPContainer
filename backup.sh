#!/usr/bin/env bash
#
# backup.sh — Sauvegarde WordPress + MariaDB (Docker Compose)
#
# Produit, à chaque exécution :
#   - wp_db_<horodatage>.sql.gz         dump SQL de la base
#   - wp_content_<horodatage>.tar.gz    archive de wp-content (uploads, thèmes, plugins)
#   - <fichier>.sha256                  somme de contrôle de chaque archive
#
# Usage :
#   ./backup.sh
#   PROJECT_DIR=/opt/wordpress BACKUP_DIR=/backup/wordpress RETENTION_DAYS=14 ./backup.sh
#
# Planification (cron, tous les jours à 02h30) :
#   30 2 * * * /opt/wordpress/backup.sh >> /var/log/wp-backup.log 2>&1
#
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/wordpress}"
BACKUP_DIR="${BACKUP_DIR:-/backup/wordpress}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOCK_FILE="${LOCK_FILE:-/tmp/wp-backup.lock}"

STAMP="$(date +%F_%H%M%S)"
DB_FILE="${BACKUP_DIR}/wp_db_${STAMP}.sql.gz"
FILES_FILE="${BACKUP_DIR}/wp_content_${STAMP}.tar.gz"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

cleanup_on_error() {
  log "ERREUR : sauvegarde interrompue, suppression des fichiers partiels."
  rm -f "${DB_FILE}" "${FILES_FILE}" "${DB_FILE}.sha256" "${FILES_FILE}.sha256"
}
trap cleanup_on_error ERR

# --- Empêche deux sauvegardes simultanées -----------------------------------
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "Une sauvegarde est déjà en cours, abandon."
  exit 1
fi

# --- Pré-vérifications -------------------------------------------------------
cd "${PROJECT_DIR}"
mkdir -p "${BACKUP_DIR}"

if ! docker compose ps --status running --services | grep -qx db; then
  log "Le service 'db' n'est pas démarré, abandon."
  exit 1
fi
if ! docker compose ps --status running --services | grep -qx wordpress; then
  log "Le service 'wordpress' n'est pas démarré, abandon."
  exit 1
fi

# --- 1. Dump de la base ------------------------------------------------------
# Les identifiants sont lus dans le container (variables MARIADB_*), jamais
# passés en clair sur la ligne de commande de l'hôte.
log "Dump de la base de données..."
docker compose exec -T db sh -c \
  'mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" \
     --single-transaction --routines --triggers --events \
     "$MARIADB_DATABASE"' \
  | gzip -9 > "${DB_FILE}"

# --- 2. Archive de wp-content ------------------------------------------------
log "Archivage de wp-content..."
docker compose exec -T wordpress \
  tar czf - -C /var/www/html wp-content > "${FILES_FILE}"

# --- 3. Vérifications d'intégrité -------------------------------------------
log "Vérification des archives..."
gzip -t "${DB_FILE}"
gzip -t "${FILES_FILE}"

# Un dump valide contient la marque de fin générée par mariadb-dump.
if ! gzip -dc "${DB_FILE}" | tail -n 5 | grep -q "Dump completed"; then
  log "Le dump SQL semble incomplet."
  false
fi

( cd "${BACKUP_DIR}" && sha256sum "$(basename "${DB_FILE}")"    > "$(basename "${DB_FILE}").sha256" )
( cd "${BACKUP_DIR}" && sha256sum "$(basename "${FILES_FILE}")" > "$(basename "${FILES_FILE}").sha256" )

chmod 600 "${DB_FILE}" "${FILES_FILE}" "${DB_FILE}.sha256" "${FILES_FILE}.sha256"

# --- 4. Rotation -------------------------------------------------------------
log "Suppression des sauvegardes de plus de ${RETENTION_DAYS} jours..."
find "${BACKUP_DIR}" -maxdepth 1 -type f \
  \( -name 'wp_db_*' -o -name 'wp_content_*' \) \
  -mtime +"${RETENTION_DAYS}" -print -delete

trap - ERR
log "Sauvegarde terminée :"
log "  $(du -h "${DB_FILE}"    | cut -f1)  ${DB_FILE}"
log "  $(du -h "${FILES_FILE}" | cut -f1)  ${FILES_FILE}"
