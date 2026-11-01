FROM wordpress:php8.3-apache

# Réglages PHP (envois de fichiers), cohérents avec client_max_body_size de Nginx
COPY docker/uploads.ini /usr/local/etc/php/conf.d/uploads.ini

# Thème et plugins versionnés dans le dépôt : ils sont copiés dans une zone
# de l'image, puis synchronisés dans le volume wp-content à chaque démarrage
# par custom-entrypoint.sh (sinon le volume garderait l'ancienne version).
COPY --chown=www-data:www-data wp-content /usr/src/custom/wp-content
COPY --chmod=755 docker/custom-entrypoint.sh /usr/local/bin/custom-entrypoint.sh

# Redéfinir ENTRYPOINT efface le CMD hérité de l'image de base : on le remet.
ENTRYPOINT ["custom-entrypoint.sh"]
CMD ["apache2-foreground"]
