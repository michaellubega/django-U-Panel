FROM nginx:1.27-alpine

COPY config/nginx/upanel-docker.conf /etc/nginx/conf.d/default.conf
COPY website/app /var/www/upanel-app
COPY website/downloads /var/www/upanel-downloads
COPY website/index.html website/app.js website/releases.json website/styles.css /var/www/upanel-site/
COPY website/privacy.html website/delete-account.html /var/www/upanel-site/
COPY website/assets /var/www/upanel-site/assets

RUN test -f /var/www/upanel-app/index.html || (echo "Missing website/app — run flutter build web first" >&2 && exit 1) \
    && test -f /var/www/upanel-app/.well-known/assetlinks.json || (echo "Missing website/app/.well-known/assetlinks.json" >&2 && exit 1) \
    && test -f /var/www/upanel-site/index.html || (echo "Missing website download landing page" >&2 && exit 1)
