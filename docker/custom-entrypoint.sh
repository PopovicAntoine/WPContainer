#!/bin/sh
# Synchronise le thème et les plugins de l'image vers le volume wp-content,
# puis passe la main à l'entrypoint officiel de WordPress.
#
# Les envois de fichiers (uploads) et les plugins installés depuis
# l'interface ne sont pas touchés : seuls les fichiers présents dans l'image
# sont écrasés.
set -e

if [ -d /usr/src/custom/wp-content ]; then
  mkdir -p /var/www/html/wp-content
  cp -a /usr/src/custom/wp-content/. /var/www/html/wp-content/
fi

exec docker-entrypoint.sh "$@"
