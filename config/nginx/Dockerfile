FROM nginx:1.27-alpine

COPY config/nginx/upanel-docker.conf /etc/nginx/conf.d/default.conf
COPY website/app /var/www/upanel-app

RUN test -f /var/www/upanel-app/index.html || (echo "Missing website/app — run flutter build web first" >&2 && exit 1) \
    && test -f /var/www/upanel-app/.well-known/assetlinks.json || (echo "Missing website/app/.well-known/assetlinks.json" >&2 && exit 1)
