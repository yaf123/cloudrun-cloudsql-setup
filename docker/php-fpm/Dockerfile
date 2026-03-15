# =============================================================
# Stage 1: Composer 依存解決
# =============================================================
FROM composer:2 AS composer-deps
WORKDIR /build
COPY app/composer.json app/composer.lock* ./
RUN composer install \
    --no-dev \
    --no-scripts \
    --optimize-autoloader \
    --no-interaction \
    --prefer-dist \
    --ignore-platform-reqs

# =============================================================
# Stage 2: PHP拡張ビルド（ビルドツールを本番に含めない）
# =============================================================
FROM php:8.2-fpm-alpine AS ext-builder
RUN apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        libpng-dev libjpeg-turbo-dev freetype-dev \
        icu-dev oniguruma-dev libzip-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql mysqli gd intl mbstring zip opcache \
    && apk del .build-deps

# =============================================================
# Stage 3: 本番イメージ（ローカルでもCloud Runでもこれを使う）
# =============================================================
FROM php:8.2-fpm-alpine AS production

# ランタイムライブラリのみ
RUN apk add --no-cache \
        libpng libjpeg-turbo freetype \
        icu-libs oniguruma libzip \
        tzdata \
    && cp /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && echo "Asia/Tokyo" > /etc/timezone \
    && apk del tzdata

# Stage 2 のPHP拡張をコピー
COPY --from=ext-builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=ext-builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# PHP / FPM 設定
COPY docker/php-fpm/php.ini /usr/local/etc/php/php.ini
COPY docker/php-fpm/www.conf /usr/local/etc/php-fpm.d/www.conf

# アプリケーションコード
WORKDIR /var/www/html
COPY app/ ./
COPY --from=composer-deps /build/vendor ./vendor

RUN chown -R www-data:www-data /var/www/html

EXPOSE 9000
CMD ["php-fpm", "-F"]
