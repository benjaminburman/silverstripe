#!/bin/bash

over-ss-32(){
	SS_MAJOR=$(echo ${SILVERSTRIPE_VERSION} | cut -d. -f1)
	SS_MINOR=$(echo ${SILVERSTRIPE_VERSION} | cut -d. -f2)
	if [[ ${SS_MAJOR} == 3 && $((SS_MINOR < 2)) == 1 ]]; then
		echo "false"
	else
		echo "true"
	fi
}

# SOURCE_DIR and WWW_DIR comes from an ENV variable in the Dockerfile
# Copy everything except cms, framework and _ss_environment.php from ${SOURCE_DIR} to ${WWW_DIR}
if [[ $(ls ${SOURCE_DIR}) != "" ]]; then

	# Also exclude siteconfig and reports when version is over 3.2
	if [[ $(over-ss-32) == "false" ]]; then
		(cd ${SOURCE_DIR} && cp -R $(ls ${SOURCE_DIR} | \
			grep -v 'framework' | \
			grep -v 'cms' | \
			grep -v '_ss_environment.php') ${WWW_DIR})
	else
		(cd ${SOURCE_DIR} && cp -R $(ls ${SOURCE_DIR} | \
			grep -v 'framework' | \
			grep -v 'cms' | \
			grep -v 'reports' | \
			grep -v 'siteconfig' | \
			grep -v '_ss_environment.php') ${WWW_DIR})
	fi
fi

# dev mode exposes all web data at the /live mount.
# to use it, start the docker container normally, but set DEV_MODE=1 to enable it and mount the host dir you want to see the live content to /live
# Example: Expose the web content at $(pwd)/live, where $(pwd) is the SilverStripe project root: 
# docker run -d -e DEV_MODE=1 -v $(pwd):/source -v $(pwd)/live:/live {image-name}
DEV_MODE=${DEV_MODE:-0}
DEV_DIR=${DEV_DIR:-/live}
if [[ ${DEV_MODE} == 1 ]]; then
	(cd ${WWW_DIR} && cp -R ${WWW_DIR}/* ${DEV_DIR})
	rm -r ${WWW_DIR}
	ln -s ${DEV_DIR} ${WWW_DIR}
fi

# readwrite mode copies the official source into the repo you're working on
# the site is hosted from the directory on the host
# WARNING: This will modify your current work directory
# Example: docker run -d -e RW_MODE=1 -v $(pwd):/source {image-name}
RW_MODE=${RW_MODE:-0}
if [[ ${RW_MODE} == 1 && ${DEV_MODE} == 0 ]]; then
	rm -rf ${SOURCE_DIR}/cms ${SOURCE_DIR}/framework ${SOURCE_DIR}/_ss_environment.php

	if [[ $(over-ss-32) == "true" ]]; then
		rm -rf ${SOURCE_DIR}/reports ${SOURCE_DIR}/siteconfig
	fi

	# Do not override existing files with the same name
	cp -r --no-clobber ${WWW_DIR}/* ${SOURCE_DIR}
	rm -r ${WWW_DIR}
	ln -s ${SOURCE_DIR} ${WWW_DIR}
fi

# Traverse SilverStipe patches, and apply them
if [[ -d ${WWW_DIR}/_patches/${SILVERSTRIPE_VERSION} ]]; then
	cd ${WWW_DIR}

	for file in ${WWW_DIR}/_patches/${SILVERSTRIPE_VERSION}/*.patch; do
		echo "Patching SilverStripe with file: $file"
		patch -p1 < $file
	done
fi

# Runtime configuration options
SS_ENVIRONMENT_TYPE=${SS_ENVIRONMENT_TYPE:-dev}
SS_DATABASE_SERVER=${SS_DATABASE_SERVER:-127.0.0.1}
SS_DATABASE_PORT=${SS_DATABASE_PORT:-3306}
SS_DATABASE_USERNAME=${SS_DATABASE_USERNAME:-root}
SS_DATABASE_PASSWORD=${SS_DATABASE_PASSWORD:-root}
SS_DEFAULT_ADMIN_USERNAME=${SS_DEFAULT_ADMIN_USERNAME:-admin}
SS_DEFAULT_ADMIN_PASSWORD=${SS_DEFAULT_ADMIN_PASSWORD:-admin}
SS_ERROR_LOG=${SS_ERROR_LOG:-silverstripe.errlog}

NGINX_DOMAIN_NAME=${NGINX_DOMAIN_NAME:-localhost}
NGINX_LISTEN_PORT=${NGINX_LISTEN_PORT:-80}
NGINX_LISTEN_HTTPS_PORT=${NGINX_LISTEN_HTTPS_PORT:-443}
NGINX_ENABLE_HTTPS=${NGINX_ENABLE_HTTPS:-0}
NGINX_ENABLE_HTTP2=${NGINX_ENABLE_HTTP2:-0}

NGINX_WORKER_PROCESSES=${NGINX_WORKER_PROCESSES:-1}
NGINX_WORKER_CONNECTIONS=${NGINX_WORKER_CONNECTIONS:-1024}

PHP_MAX_EXECUTION_TIME=${PHP_MAX_EXECUTION_TIME:-300}
PHP_MAX_UPLOAD_SIZE=${PHP_MAX_UPLOAD_SIZE:-32}

PHP_TIMEZONE=${PHP_TIMEZONE:-"Europe/Helsinki"}

PHP_SERVER=${PHP_SERVER:-localhost}
MAIL_SERVER=${MAIL_SERVER:-localhost}

# If HTTP/2 is used, HTTPS must also be used
if [[ ${NGINX_ENABLE_HTTP2} == 1 ]]; then
	NGINX_ENABLE_HTTPS=1
fi

cat > ${WWW_DIR}/_ss_environment.php <<EOF
<?php
ini_set('date.timezone', '${PHP_TIMEZONE}');
define('SS_ENVIRONMENT_TYPE', '${SS_ENVIRONMENT_TYPE}');
define('SS_DATABASE_SERVER', '${SS_DATABASE_SERVER}');
define('SS_DATABASE_PORT', '${SS_DATABASE_PORT}');
define('SS_DATABASE_USERNAME', '${SS_DATABASE_USERNAME}');
define('SS_DATABASE_PASSWORD', '${SS_DATABASE_PASSWORD}');
define('SS_DEFAULT_ADMIN_USERNAME', '${SS_DEFAULT_ADMIN_USERNAME}');
define('SS_DEFAULT_ADMIN_PASSWORD', '${SS_DEFAULT_ADMIN_PASSWORD}');
define('SS_ERROR_LOG', '${SS_ERROR_LOG}');
global \$_FILE_TO_URL_MAPPING;
\$_FILE_TO_URL_MAPPING['${WWW_DIR}'] = 'http://${NGINX_DOMAIN_NAME}';
EOF

# Replace dynamic values in the default web site config
sed -e "s|NGINX_WORKER_PROCESSES|${NGINX_WORKER_PROCESSES}|g" -i /etc/nginx/nginx.conf
sed -e "s|NGINX_WORKER_CONNECTIONS|${NGINX_WORKER_CONNECTIONS}|g" -i /etc/nginx/nginx.conf
sed -e "s|PHP_MAX_UPLOAD_SIZE|${PHP_MAX_UPLOAD_SIZE}|g" -i /etc/nginx/nginx.conf

sed -e "s|PHP_MAX_EXECUTION_TIME|${PHP_MAX_EXECUTION_TIME}|g" -i /etc/nginx/php.conf
sed -e "s|PHP_SERVER|${PHP_SERVER}|g" -i /etc/nginx/php.conf

sed -e "s|max_execution_time = 30|max_execution_time = ${PHP_MAX_EXECUTION_TIME}|g" -i /etc/php5/fpm/php.ini
sed -e "s|upload_max_filesize = 2M|upload_max_filesize = ${PHP_MAX_UPLOAD_SIZE}M|g" -i /etc/php5/fpm/php.ini
sed -e "s|post_max_size = 3M|post_max_size = $((PHP_MAX_UPLOAD_SIZE+1))M|g" -i /etc/php5/fpm/php.ini

# Require those two files
# docker run -d -e NGINX_ENABLE_HTTPS=1 -v $(pwd)/certs:/certs {image_name}
if [[ ${NGINX_ENABLE_HTTPS} == 1 && (! -f ${CERT_DIR}/site.crt || ! -f ${CERT_DIR}/site.key) ]]; then

	echo "Fatal error: Tried to start in https mode but ${CERT_DIR}/site.crt or ${CERT_DIR}/site.key does not exist."
	echo "Those two files are required in order to enable https."
	echo "Exiting..."
	exit 1
fi

# If we've enabled https, an optional dhparam.pem file may be specified for added encryption
# If there is no such file, remove the statement from the config
# Generate with this command: openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
if [[ ${NGINX_ENABLE_HTTPS} == 1 && ! -f ${CERT_DIR}/dhparam.pem ]]; then
	sed -e "/ssl_dhparam/d" -i /etc/nginx/sites-available/default-https
fi

sed -e "s|SS_ROOT_DIR|${WWW_DIR}|g" -i /etc/nginx/sites-available/default-http /etc/nginx/sites-available/default-https
sed -e "s|NGINX_DOMAIN_NAME|${NGINX_DOMAIN_NAME}|g" -i /etc/nginx/sites-available/default-http /etc/nginx/sites-available/default-https
sed -e "s|NGINX_LISTEN_PORT|${NGINX_LISTEN_PORT}|g" -i /etc/nginx/sites-available/default-http /etc/nginx/sites-available/default-https

sed -e "s|NGINX_LISTEN_HTTPS_PORT|${NGINX_LISTEN_HTTPS_PORT}|g" -i /etc/nginx/sites-available/default-https
sed -e "s|CERT_DIR|${CERT_DIR}|g" -i /etc/nginx/sites-available/default-https

# Set the http2 directive
if [[ ${NGINX_ENABLE_HTTP2} == 1 ]]; then
	sed -e "s|USE_HTTP2|http2|g" -i /etc/nginx/sites-available/default-https
else
	sed -e "s|USE_HTTP2||g" -i /etc/nginx/sites-available/default-https
fi

# If https is disabled, remove the nginx config for HTTPS
mkdir -p /etc/nginx/sites-enabled
if [[ ${NGINX_ENABLE_HTTPS} == 1 ]]; then
	ln -s /etc/nginx/sites-available/default-https /etc/nginx/sites-enabled/default
else
	ln -s /etc/nginx/sites-available/default-http /etc/nginx/sites-enabled/default
fi

# Remove install.php where the $database variable is set in _config.php, i.e. remove install.php from all real projects
if [[ ! -z $(grep "global \$database" ${WWW_DIR}/mysite/_config.php) && -z $(grep "$database = ''" ${WWW_DIR}/mysite/_config.php) ]]; then
	rm -f ${WWW_DIR}/install.php
fi

# Make the user and group www-data own the content. nginx is using that user for displaying content 
chown -R www-data:www-data ${WWW_DIR}

# Only start PHP if we're listening on it here
if [[ ${PHP_SERVER} == "localhost" ]]; then

	# Start the FastCGI server
	exec php5-fpm &
fi

# Start a socat forwarder process if the mail forwarder is present somewhere else
if [[ ${MAIL_SERVER} != "localhost" ]]; then
	exec socat -ls TCP4-LISTEN:25,fork,reuseaddr TCP4:${MAIL_SERVER}:25 &
fi

# Start the nginx webserver in foreground mode. The docker container lifecycle will be tied to nginx.
exec nginx -g "daemon off;"
