#!/usr/bin/env bash
#
# restore.sh — Restauration WordPress + MariaDB (Docker Compose)
#
# Restaure une sauvegarde produite par backup.sh : base SQL + wp-content.
# ATTENTION : la base et le contenu actuels sont ÉCRASÉS.
#
# Usage :
#   ./restore.sh <horodatage>          ex : ./restore.sh 2026-10-28_023000
#   ./restore.sh latest                restaure la sauvegarde la plus récente
#   ./restore.sh <horodatage> --yes    sans demande de confirmation
#
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/wordpress}"
BACKUP_DIR="${BACKUP_DIR:-/backup/wordpress}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERREUR : $*"; exit 1; }

[ $# -ge 1 ] || die "Usage : $0 <horodatage|latest> [--yes]"
TARGET="$1"
ASSUME_YES="${2:-}"

# --- Sélection des fichiers --------------------------------------------------
if [ "${TARGET}" = "latest" ]; then
  DB_FILE="$(ls -1t "${BACKUP_DIR}"/wp_db_*.sql.gz 2>/dev/null | head -n 1 || true)"
  [ -n "${DB_FILE}" ] || die "Aucune sauvegarde trouvée dans ${BACKUP_DIR}."
  STAMP="$(basename "${DB_FILE}" | sed -E 's/^wp_db_(.*)\.sql\.gz$/\1/')"
else
  STAMP="${TARGET}"
  DB_FILE="${BACKUP_DIR}/wp_db_${STAMP}.sql.gz"
fi
FILES_FILE="${BACKUP_DIR}/wp_content_${STAMP}.tar.gz"

[ -f "${DB_FILE}" ]    || die "Fichier introuvable : ${DB_FILE}"
[ -f "${FILES_FILE}" ] || die "Fichier introuvable : ${FILES_FILE}"

# --- Vérification d'intégrité -----------------------------------------------
log "Vérification des sommes de contrôle..."
( cd "${BACKUP_DIR}" && sha256sum -c "$(basename "${DB_FILE}").sha256" )
( cd "${BACKUP_DIR}" && sha256sum -c "$(basename "${FILES_FILE}").sha256" )
gzip -t "${DB_FILE}"
gzip -t "${FILES_FILE}"

# --- Confirmation ------------------------------------------------------------
log "Sauvegarde à restaurer : ${STAMP}"
if [ "${ASSUME_YES}" != "--yes" ]; then
  read -r -p "Cela écrase la base et wp-content actuels. Continuer ? [oui/N] " ANSWER
  [ "${ANSWER}" = "oui" ] || die "Restauration annulée."
fi

cd "${PROJECT_DIR}"
docker compose up -d db wordpress

# --- 1. Restauration des fichiers (wordpress démarré) ------------------------
log "Restauration de wp-content..."
docker compose exec -T wordpress \
  find /var/www/html/wp-content -mindepth 1 -delete
docker compose exec -T wordpress \
  tar xzf - -C /var/www/html < "${FILES_FILE}"

# --- 2. Restauration de la base (wordpress arrêté) --------------------------
log "Arrêt de WordPress pendant l'import de la base..."
docker compose stop wordpress

log "Recréation de la base..."
docker compose exec -T db sh -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" \
     -e "DROP DATABASE IF EXISTS \`$MARIADB_DATABASE\`; CREATE DATABASE \`$MARIADB_DATABASE\`;"'

log "Import du dump SQL..."
gzip -dc "${DB_FILE}" | docker compose exec -T db sh -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"'

# --- 3. Redémarrage et contrôle ----------------------------------------------
log "Redémarrage de WordPress..."
docker compose start wordpress

# Remet aussi en route le reste de la stack (le proxy Nginx n'est pas lancé
# plus haut) : utile après un "docker compose down -v".
log "Démarrage du reste de la stack..."
docker compose up -d

log "Contrôle du nombre de tables restaurées :"
docker compose exec -T db sh -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -N -e \
     "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = \"$MARIADB_DATABASE\";"'

log "Restauration terminée. Vérifie le site dans le navigateur."