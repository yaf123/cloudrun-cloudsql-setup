FROM nginx:1.27-alpine AS production

RUN apk add --no-cache tzdata \
    && cp /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && echo "Asia/Tokyo" > /etc/timezone \
    && apk del tzdata

# デフォルト設定を削除
RUN rm -f /etc/nginx/conf.d/default.conf

# Nginx設定
COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx/conf.d/default.conf.template /etc/nginx/templates/default.conf.template

# 静的ファイル（本番用: イメージに含める）
COPY app/public/ /var/www/html/public/

# non-root実行の準備
RUN mkdir -p /tmp/nginx \
    && chown -R nginx:nginx /tmp/nginx /var/cache/nginx /var/www/html

EXPOSE 8080

# envsubst で PHP_FPM_HOST を展開してから起動
# ローカル: PHP_FPM_HOST=php-fpm  (docker-compose サービス名)
# Cloud Run: PHP_FPM_HOST=127.0.0.1 (同一Pod内 localhost)
CMD ["/bin/sh", "-c", "envsubst '${PHP_FPM_HOST}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"]
