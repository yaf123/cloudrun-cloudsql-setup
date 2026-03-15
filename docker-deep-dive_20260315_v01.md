# Docker構成 深堀りガイド

<br>

---

<br>

## 1. Nginx + PHP-FPM チューニング

<br>

### 1-1. 全体のリクエストフロー

```
Cloud Run が受け取るリクエスト
  │
  │  Cloud Run の concurrency 設定で制御
  │  （1インスタンスあたり最大同時リクエスト数）
  │
  ▼
┌────────────────────────────────────────────────────────────┐
│  Nginx (Ingress Container)                                 │
│                                                            │
│  worker_processes × worker_connections = 最大同時接続数      │
│                                                            │
│  ┌─ 静的ファイル → Nginx が直接返却（PHP-FPM を経由しない）   │
│  │                                                         │
│  └─ PHPリクエスト → FastCGI で PHP-FPM に転送               │
│                      │                                     │
└──────────────────────│─────────────────────────────────────┘
                       │  localhost:9000 (FastCGI)
                       ▼
┌────────────────────────────────────────────────────────────┐
│  PHP-FPM (Sidecar Container)                               │
│                                                            │
│  pm.max_children = 同時に処理できるPHPリクエスト数            │
│                                                            │
│  ┌─ Worker Process 1 ─── リクエスト処理 → DB → レスポンス   │
│  ├─ Worker Process 2 ─── リクエスト処理 → DB → レスポンス   │
│  ├─ ...                                                    │
│  └─ Worker Process N ─── リクエスト処理 → DB → レスポンス   │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

**ボトルネックの発生ポイント:**

```
① Nginx worker不足      → 502 Bad Gateway（接続を受けられない）
② PHP-FPM worker不足    → 504 Gateway Timeout（Nginx がFPMの応答を待ちきれない）
③ メモリ不足             → OOM Kill（Cloud Run がコンテナを強制停止）
④ DB接続プール枯渇       → PHP側でDB接続エラー
```

<br>

### 1-2. チューニングの設計方針

Cloud Run では**コンテナに割り当てるリソース（CPU/メモリ）が固定**であるため、
VM のようにリソースを後から追加できない。限られたリソース内で最適なワーカー数を設定する。

```
チューニングの公式:

  PHP-FPM pm.max_children = コンテナメモリ ÷ 1プロセスあたりメモリ消費

  例: 512MiB ÷ 40MiB/process = 12 children
      （OS + PHP-FPM master + バッファで ~30MiB を差し引く）

  Nginx worker_connections ≧ Cloud Run concurrency × 2
      （PHP-FPM への転送 + クライアントへの応答 = 1リクエストあたり2接続）
```

<br>

### 1-3. Nginx チューニング

```nginx
# docker/nginx/nginx.conf

# ---- ワーカー設定 ----
worker_processes auto;
# Cloud Run のCPU割り当てに応じて自動決定
# 0.5 vCPU → 1 worker,  1 vCPU → 1 worker,  2 vCPU → 2 workers
# autoにしておけばCPUコア数に合わせて最適化される

worker_rlimit_nofile 4096;
# 1 worker が開けるファイルディスクリプタの上限
# worker_connections × 2 以上に設定（各接続でFD 2つ使用）

events {
    worker_connections 1024;
    # 1 worker あたりの最大同時接続数
    # Cloud Run concurrency=80 なら、1024で十分
    # （静的ファイル + PHP転送 の合計）

    multi_accept on;
    # 一度に複数の接続を受け付ける（パフォーマンス向上）

    use epoll;
    # Linux の高効率イベント処理（Alpine/Debian で利用可能）
}

http {
    # ---- 基本設定 ----
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 2048;
    server_tokens off;          # Nginx バージョンを隠す（セキュリティ）

    # ---- Keep-Alive ----
    keepalive_timeout 65;
    # Cloud Run ←→ Nginx 間の接続を維持する時間
    # Cloud Run のリクエストタイムアウト（60s）より少し長くする

    keepalive_requests 1000;
    # 1つのKeep-Alive接続で処理する最大リクエスト数
    # Cloud Run は同一インスタンスに複数リクエストを送るため高めに

    # ---- バッファ設定 ----
    client_body_buffer_size 16k;
    # POSTリクエストボディの初期バッファ
    # 16k を超えるとテンポラリファイルに書き出される

    client_header_buffer_size 1k;
    # リクエストヘッダの初期バッファ

    large_client_header_buffers 4 8k;
    # 大きなヘッダ用のバッファ（Cookie が大きい場合に必要）

    client_max_body_size 20M;
    # アップロードサイズ上限（PHP の upload_max_filesize と合わせる）

    # ---- gzip 圧縮 ----
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;
    # 圧縮レベル（1-9）。4がCPU負荷とサイズのバランスが良い
    # Cloud Run の限られたCPUでは 6以上は非推奨

    gzip_min_length 1000;
    # 1000バイト未満のレスポンスは圧縮しない（オーバーヘッドの方が大きい）

    gzip_types
        text/plain
        text/css
        text/javascript
        application/json
        application/javascript
        application/xml
        application/xml+rss
        image/svg+xml;

    # ---- ログ ----
    # JSON構造化ログ（Cloud Logging が自動パース）
    log_format json escape=json '{'
        '"severity":"INFO",'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"request_method":"$request_method",'
        '"request_uri":"$request_uri",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_response_time":"$upstream_response_time",'
        '"upstream_connect_time":"$upstream_connect_time",'
        '"http_user_agent":"$http_user_agent",'
        '"http_referer":"$http_referer",'
        '"http_x_forwarded_for":"$http_x_forwarded_for"'
    '}';
    access_log /dev/stdout json;
    error_log /dev/stderr warn;

    include /etc/nginx/conf.d/*.conf;
}
```

<br>

### 1-4. Nginx FastCGI プロキシ設定

```nginx
# docker/nginx/conf.d/default.conf

upstream php-fpm {
    server 127.0.0.1:9000;

    # Keep-Alive 接続プール（Nginx → PHP-FPM）
    keepalive 16;
    # 常時 16 本の接続をプールしておく
    # Cloud Run concurrency=80 でも、PHP-FPM の処理が高速なら 16 で十分
    # 不足すると都度TCP接続が発生し、レイテンシが増加
}

server {
    listen 8080;
    server_name _;

    root /var/www/html/public;
    index index.php index.html;

    # ---- ヘルスチェック ----
    location = /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # ---- 静的ファイル（Nginx 直接配信） ----
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff2?|ttf|eot|webp|avif)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;           # 静的ファイルのアクセスログは不要
        try_files $uri =404;
    }

    # ---- PHP リクエスト ----
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        # セキュリティ: 存在しないPHPファイルへのリクエストを拒否
        try_files $uri =404;

        fastcgi_pass php-fpm;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;

        # ---- タイムアウト設定 ----
        fastcgi_connect_timeout 5s;
        # PHP-FPM への接続タイムアウト
        # localhost なので 5s で十分（応答しない = FPM が落ちている）

        fastcgi_send_timeout 30s;
        # リクエストボディの送信タイムアウト
        # 大きなファイルアップロード時に関係

        fastcgi_read_timeout 60s;
        # PHP-FPM からのレスポンス待ちタイムアウト
        # Cloud Run のリクエストタイムアウト（60s）と合わせる
        # これを超えると Nginx が 504 を返す

        # ---- バッファ設定 ----
        fastcgi_buffer_size 32k;
        # レスポンスヘッダ用バッファ
        # PHP が大きなヘッダ（Set-Cookie等）を返す場合に増やす

        fastcgi_buffers 16 32k;
        # レスポンスボディ用バッファ（16個 × 32k = 512k）
        # バッファに収まらないレスポンスはテンポラリファイル経由になる

        fastcgi_busy_buffers_size 64k;
        # クライアント送信中に使えるバッファサイズ
        # fastcgi_buffer_size の 2倍が目安

        # ---- Keep-Alive（upstream接続プール用） ----
        fastcgi_keep_conn on;
        # upstream の keepalive と組み合わせて接続を再利用
    }

    # ---- セキュリティ: 隠しファイルへのアクセス拒否 ----
    location ~ /\. {
        deny all;
        return 404;
    }

    # ---- セキュリティ: PHPソースファイルの直接アクセス拒否 ----
    location ~ ^/src/ {
        deny all;
        return 404;
    }
}
```

<br>

### 1-5. PHP-FPM チューニング

```ini
; docker/php-fpm/www.conf

[www]
user = www-data
group = www-data
listen = 0.0.0.0:9000

; ==============================================================
; プロセス管理（pm）設定 — チューニングの核心
; ==============================================================
;
; pm の選択肢:
;   static   → 固定数のワーカーを常時起動（メモリ消費一定、応答安定）
;   dynamic  → 負荷に応じてワーカーを増減（メモリ節約、スパイク時に起動遅延）
;   ondemand → リクエスト時のみワーカー起動（最小メモリ、レイテンシ増）
;
; Cloud Run での推奨:
;   - コンテナ起動時に即座にリクエストを処理する必要がある
;   - リソースが固定（CPU/メモリ）
;   - → static が最もシンプルで予測可能
;
; ただし、dev環境やメモリが少ない場合は dynamic も有効
;

; ---- dev環境（512Mi メモリ）----
;   pm = dynamic で柔軟に
;   1ワーカー ≈ 30-50MiB → 最大 10 ワーカー
;
; ---- prod環境（1Gi メモリ）----
;   pm = static で安定性重視
;   1ワーカー ≈ 30-50MiB → 最大 15-20 ワーカー

pm = dynamic

; ---- pm.max_children ----
; 同時に存在できるワーカープロセスの上限
; これを超えるリクエストは待ちキューに入る
;
; 計算式:
;   (コンテナメモリ - OS/FPM master - バッファ) ÷ 1ワーカーあたりメモリ
;   (512Mi - 50Mi - 50Mi) ÷ 40Mi ≈ 10
;
; Cloud Run concurrency=80 でも max_children=10 で対処可能な理由:
;   PHP の平均処理時間が 100ms なら、10 worker × 10 req/s = 100 req/s
;   80 concurrent のうち多くは Nginx のバッファで吸収される
pm.max_children = 10

; ---- pm.start_servers ----
; 起動時のワーカー数（dynamic/ondemand 時のみ）
; コールドスタート対策として、ある程度起動しておく
pm.start_servers = 4

; ---- pm.min_spare_servers ----
; アイドル状態で最低限維持するワーカー数
; これを下回ると新しいワーカーが起動される
pm.min_spare_servers = 2

; ---- pm.max_spare_servers ----
; アイドル状態で許容する最大ワーカー数
; これを超えるアイドルワーカーは終了される
pm.max_spare_servers = 6

; ---- pm.max_requests ----
; 1ワーカーが処理するリクエスト数の上限
; 上限に達するとワーカーを再起動（メモリリーク対策）
; 0 = 無制限（非推奨）
pm.max_requests = 500

; ---- pm.process_idle_timeout ----
; アイドルワーカーの生存時間（dynamic 時）
; この時間アイドルならワーカーを終了
pm.process_idle_timeout = 10s

; ==============================================================
; タイムアウト設定
; ==============================================================

; ---- request_terminate_timeout ----
; 1リクエストの最大処理時間
; これを超えると FPM がワーカーを強制終了
; Cloud Run のリクエストタイムアウト（60s）と合わせる
request_terminate_timeout = 60s

; ==============================================================
; ログ設定
; ==============================================================

; Cloud Logging に自動転送されるよう stderr に出力
access.log = /dev/stderr
access.format = '{"severity":"INFO","time":"%{%Y-%m-%dT%H:%M:%S%z}T","client":"%R","method":"%m","request_uri":"%r","status":"%s","duration":"%dms","memory":"%{mega}MMB","cpu":"%C%%"}'

; エラーログ
php_admin_value[error_log] = /dev/stderr
php_admin_flag[log_errors] = on

; ワーカーの出力をキャプチャ（error_log への出力が FPM ログに含まれる）
catch_workers_output = yes
decorate_workers_output = no

; ==============================================================
; セキュリティ
; ==============================================================

; open_basedir でファイルアクセスを制限
php_admin_value[open_basedir] = /var/www/html:/tmp:/dev

; 危険な関数を無効化
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen
```

<br>

### 1-6. PHP OPcache チューニング

```ini
; docker/php-fpm/php.ini（OPcache セクション）

[opcache]
; OPcache を有効化（本番では必須）
opcache.enable = 1

; 共有メモリサイズ（コンパイル済みスクリプトのキャッシュ）
; 小規模: 64MB, 中規模: 128MB, 大規模: 256MB
opcache.memory_consumption = 128

; インターン文字列用バッファ
; クラス名・メソッド名等の文字列をメモリ共有
opcache.interned_strings_buffer = 16

; キャッシュできるファイル数の上限
; `find app/ -name "*.php" | wc -l` の 2倍程度
opcache.max_accelerated_files = 10000

; ファイル変更チェック
; 0 = チェックしない（本番用: デプロイ = コンテナ再作成 なので不要）
; 1 = チェックする（開発用: ファイル変更を即反映）
opcache.validate_timestamps = 0

; PHPDoc コメントを保持
; フレームワークのアノテーション機能で必要
opcache.save_comments = 1

; プリロード（PHP 7.4+）
; 起動時に指定したスクリプトをメモリにロード
; フレームワークの設定ファイルや頻繁に使うクラスをプリロード
; opcache.preload = /var/www/html/config/preload.php
; opcache.preload_user = www-data

; JIT コンパイル（PHP 8.0+）
; Cloud Run の限られたメモリでは控えめに設定
; tracing モード: 実行頻度の高いコードをネイティブコンパイル
; opcache.jit = tracing
; opcache.jit_buffer_size = 32M
```

<br>

### 1-7. 環境別チューニング一覧

| 設定 | dev (512Mi) | prod (1Gi) | 説明 |
|---|---|---|---|
| **Nginx** | | | |
| worker_processes | auto (1) | auto (2) | CPU コア数連動 |
| worker_connections | 512 | 1024 | 同時接続数 |
| keepalive (upstream) | 8 | 16 | FPM接続プール |
| gzip_comp_level | 4 | 4 | 圧縮レベル |
| **PHP-FPM** | | | |
| pm | dynamic | static | プロセス管理方式 |
| pm.max_children | 10 | 20 | 最大ワーカー数 |
| pm.start_servers | 4 | — | 初期ワーカー数 |
| pm.max_requests | 500 | 1000 | リサイクル閾値 |
| request_terminate_timeout | 60s | 60s | リクエストタイムアウト |
| **OPcache** | | | |
| memory_consumption | 64 | 128 | キャッシュメモリ |
| validate_timestamps | 1 | 0 | ファイル変更チェック |
| **Cloud Run** | | | |
| concurrency | 40 | 80 | インスタンスあたり同時リクエスト |
| min_instances | 0 | 1 | 最小インスタンス |
| max_instances | 5 | 20 | 最大インスタンス |
| CPU | 1 vCPU | 2 vCPU | CPU割当 |
| Memory | 512Mi | 1Gi | メモリ割当 |

<br>

### 1-8. チューニングの考え方（Cloud Run 固有）

```
Cloud Run のスケーリング:
  同時リクエスト数 > concurrency × 現インスタンス数
  → 新しいインスタンスを起動（スケールアウト）

つまり:
  concurrency を高くする → インスタンス数が減る → コスト減、メモリ圧迫リスク増
  concurrency を低くする → インスタンス数が増える → コスト増、安定性向上

推奨:
  concurrency = pm.max_children × 2〜4
  （PHP処理中 + Nginxバッファ待ち の合計を考慮）

  例: pm.max_children = 10 → concurrency = 40
      pm.max_children = 20 → concurrency = 80
```

<br>

---

<br>

## 2. マルチステージビルドの最適化

<br>

### 2-1. 最適化前後のイメージサイズ比較

| イメージ | 最適化前 | 最適化後 | 削減率 |
|---|---|---|---|
| PHP-FPM | ~350MB | ~120MB | 66% |
| Nginx | ~45MB | ~25MB | 44% |

<br>

### 2-2. PHP-FPM Dockerfile（最適化版）

```dockerfile
# docker/php-fpm/Dockerfile
# ================================================================
# Stage 1: Composer 依存解決（ビルドのみ、本番に含めない）
# ================================================================
FROM composer:2 AS composer-deps

WORKDIR /build

# 依存定義ファイルだけ先にコピー（レイヤーキャッシュ活用）
# composer.json/lock が変わらなければ、このステージはキャッシュされる
COPY app/composer.json app/composer.lock ./

# --no-dev:       開発用パッケージ除外（phpunit, faker 等）
# --no-scripts:   post-install スクリプトを実行しない
# --optimize-autoloader: クラスマップ生成で高速化
RUN composer install \
    --no-dev \
    --no-scripts \
    --optimize-autoloader \
    --no-interaction \
    --prefer-dist

# ================================================================
# Stage 2: PHP拡張ビルド（ビルドツールを本番に含めない）
# ================================================================
FROM php:8.2-fpm-alpine AS php-ext-builder

# ビルドに必要なパッケージ（本番には不要）
RUN apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        icu-dev \
        oniguruma-dev \
        libzip-dev \
    && docker-php-ext-configure gd \
        --with-freetype \
        --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mysqli \
        gd \
        intl \
        mbstring \
        zip \
        opcache \
    && apk del .build-deps
# .build-deps を削除することで、ビルドツールがイメージに残らない

# ================================================================
# Stage 3: 本番イメージ（最小限）
# ================================================================
FROM php:8.2-fpm-alpine AS production

LABEL maintainer="MyCompany Inc."

# ランタイムに必要なライブラリのみ（ヘッダファイル不要）
RUN apk add --no-cache \
        libpng \
        libjpeg-turbo \
        freetype \
        icu-libs \
        oniguruma \
        libzip \
        tzdata \
    && cp /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && echo "Asia/Tokyo" > /etc/timezone \
    && apk del tzdata

# Stage 2 でビルドした PHP拡張をコピー
COPY --from=php-ext-builder /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=php-ext-builder /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# PHP/FPM 設定
COPY docker/php-fpm/php.ini /usr/local/etc/php/php.ini
COPY docker/php-fpm/www.conf /usr/local/etc/php-fpm.d/www.conf

# アプリケーションコード
WORKDIR /var/www/html
COPY app/ ./

# Stage 1 の Composer 依存をコピー
COPY --from=composer-deps /build/vendor ./vendor

# パーミッション設定（1回の RUN で完結）
RUN chown -R www-data:www-data /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \;

# 非root ユーザーで実行
USER www-data

EXPOSE 9000

CMD ["php-fpm", "-F"]
```

<br>

### 2-3. Nginx Dockerfile（最適化版）

```dockerfile
# docker/nginx/Dockerfile
FROM nginx:1.27-alpine AS production

LABEL maintainer="MyCompany Inc."

# 不要なデフォルト設定を削除
RUN rm -f /etc/nginx/conf.d/default.conf \
    && rm -rf /usr/share/nginx/html/*

# 設定ファイル
COPY docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY docker/nginx/conf.d/ /etc/nginx/conf.d/

# 静的ファイル（PHP-FPM イメージと同じソースからビルド）
COPY app/public/ /var/www/html/public/

# Nginx をnon-rootで実行するための準備
# Cloud Run は非rootユーザーでの実行を推奨
RUN mkdir -p /tmp/nginx \
    && chown -R nginx:nginx /tmp/nginx \
    && chown -R nginx:nginx /var/cache/nginx \
    && chown -R nginx:nginx /var/www/html

USER nginx

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
```

<br>

### 2-4. .dockerignore

```
# docker/.dockerignore

# バージョン管理
.git
.gitignore

# 開発用ファイル
.env
.env.*
docker-compose*.yml
Dockerfile*

# テスト・ドキュメント
tests/
docs/
*.md
LICENSE

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Composer（マルチステージで入れるため）
vendor/

# CI/CD
.github/
cloudbuild.yaml

# Terraform
terraform/

# Claude
.claude/
```

<br>

### 2-5. レイヤーキャッシュの最適化

```
Dockerfile の COPY 順序が重要:
  変更頻度が低いもの → 先に COPY（キャッシュが効く）
  変更頻度が高いもの → 後に COPY

  ✅ 良い順序:
    COPY composer.json composer.lock ./    ← 依存は滅多に変わらない
    RUN composer install                   ← ↑のキャッシュが効く
    COPY app/ ./                           ← アプリコードは頻繁に変わる

  ❌ 悪い順序:
    COPY . ./                              ← 全ファイルコピー
    RUN composer install                   ← 毎回実行（キャッシュ無効化）
```

```
レイヤーキャッシュの効き方:

  変更: app/src/Spot/SpotService.php を編集

  Stage 1 (composer-deps):
    COPY composer.json → キャッシュHIT（変更なし）
    RUN composer install → キャッシュHIT
    → このステージは丸ごとスキップ ✅

  Stage 3 (production):
    COPY app/ → キャッシュMISS（ファイル変更あり）
    COPY --from=composer-deps vendor → キャッシュHIT
    → app/ 以降のレイヤーだけ再ビルド

  結果: ビルド時間が大幅短縮（数十秒 → 数秒）
```

<br>

### 2-6. Cloud Build でのキャッシュ活用

```yaml
# cloudbuild.yaml（キャッシュ最適化版）
steps:
  # Kaniko を使ったキャッシュ付きビルド
  - name: 'gcr.io/kaniko-project/executor:latest'
    args:
      - '--dockerfile=docker/php-fpm/Dockerfile'
      - '--context=.'
      - '--destination=${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/php-fpm:${SHORT_SHA}'
      - '--cache=true'
      - '--cache-ttl=168h'    # 7日間キャッシュ保持
      - '--cache-repo=${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/php-fpm-cache'
```

| ビルド方式 | 初回 | 2回目以降（コード変更のみ） |
|---|---|---|
| docker build（キャッシュなし） | ~3分 | ~3分 |
| docker build（レイヤーキャッシュ） | ~3分 | ~30秒 |
| Kaniko（リモートキャッシュ） | ~3分 | ~30秒（CI環境でも有効） |

<br>

---

<br>

## 3. ローカル開発環境（docker-compose）

<br>

### 3-1. 開発用 docker-compose

```yaml
# docker/docker-compose.yml
services:
  # ============================================================
  # Nginx（Webサーバー）
  # ============================================================
  nginx:
    build:
      context: ..
      dockerfile: docker/nginx/Dockerfile
      target: production
    ports:
      - "8080:8080"
    volumes:
      # 静的ファイルのホットリロード（ホストの変更が即反映）
      - ../app/public:/var/www/html/public:ro

      # Nginx設定のホットリロード（変更後 docker compose restart nginx）
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
    depends_on:
      php-fpm:
        condition: service_healthy
    networks:
      - app-network

  # ============================================================
  # PHP-FPM（アプリケーションサーバー）
  # ============================================================
  php-fpm:
    build:
      context: ..
      dockerfile: docker/php-fpm/Dockerfile
      target: production
    volumes:
      # PHPソースのホットリロード（最重要）
      # ホストの app/ を丸ごとマウント → 保存即反映
      - ../app:/var/www/html

      # vendor はコンテナ内のものを使う（ホストと競合しないように）
      - php-vendor:/var/www/html/vendor

      # PHP設定のホットリロード（変更後 docker compose restart php-fpm）
      - ./php-fpm/php.ini:/usr/local/etc/php/php.ini:ro
      - ./php-fpm/www.conf:/usr/local/etc/php-fpm.d/www.conf:ro
    environment:
      APP_ENV: local
      DB_HOST: mysql
      DB_PORT: "3306"
      DB_NAME: myapp
      DB_USER: myapp-app
      DB_PASSWORD: localpassword
      # OPcache のファイル変更チェックを有効化（開発用）
      PHP_OPCACHE_VALIDATE_TIMESTAMPS: "1"
    healthcheck:
      test: ["CMD-SHELL", "php-fpm-healthcheck || kill -USR2 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
    networks:
      - app-network

  # ============================================================
  # MySQL（ローカルDB）
  # ============================================================
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: myapp
      MYSQL_USER: myapp-app
      MYSQL_PASSWORD: localpassword
      TZ: Asia/Tokyo
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
      # 初期化SQL（テーブル作成等）
      - ../db/init:/docker-entrypoint-initdb.d:ro
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --default-authentication-plugin=mysql_native_password
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-prootpassword"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks:
      - app-network

  # ============================================================
  # phpMyAdmin（DB管理GUI、開発用）
  # ============================================================
  phpmyadmin:
    image: phpmyadmin:5
    ports:
      - "8081:80"
    environment:
      PMA_HOST: mysql
      PMA_USER: root
      PMA_PASSWORD: rootpassword
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - app-network
    profiles:
      - tools    # docker compose --profile tools up で起動

  # ============================================================
  # MailHog（メール送信テスト用）
  # ============================================================
  mailhog:
    image: mailhog/mailhog:latest
    ports:
      - "1025:1025"    # SMTP
      - "8025:8025"    # Web UI
    networks:
      - app-network
    profiles:
      - tools

volumes:
  mysql-data:
    driver: local
  php-vendor:
    driver: local

networks:
  app-network:
    driver: bridge
```

<br>

### 3-2. ホットリロードの仕組み

```
ホスト（WSL2）                        Docker コンテナ
┌──────────────────┐               ┌──────────────────┐
│  app/src/         │  bind mount  │  /var/www/html/   │
│  SpotService.php  │─────────────▶│  src/             │
│  (エディタで編集)  │  即時反映     │  SpotService.php  │
└──────────────────┘               └──────────────────┘
                                     │
                                     ▼
                                   PHP-FPM
                                   OPcache validate_timestamps=1
                                   → ファイル変更を検知
                                   → 次のリクエストで再コンパイル
                                   → ブラウザリロードで反映 ✅
```

| ファイル種別 | ホットリロード | 操作 |
|---|---|---|
| PHP ソースコード | 即時反映 | 保存 → ブラウザリロード |
| 静的ファイル（CSS, JS） | 即時反映 | 保存 → ブラウザリロード |
| Nginx 設定 | 再起動必要 | `docker compose restart nginx` |
| PHP-FPM 設定 | 再起動必要 | `docker compose restart php-fpm` |
| composer.json | rebuild必要 | `docker compose build php-fpm` |
| Dockerfile | rebuild必要 | `docker compose build` |

<br>

### 3-3. vendor ボリュームの工夫

```yaml
volumes:
  - ../app:/var/www/html           # ソースをマウント
  - php-vendor:/var/www/html/vendor  # vendor はコンテナ内のものを優先
```

**なぜ vendor を別ボリュームにするか:**

```
問題:
  ホスト（macOS/Windows）で composer install した vendor/ を
  Linux コンテナにマウントすると、以下の問題が発生する:

  1. ネイティブ拡張（grpc等）がOS不一致でエラー
  2. ファイルシステムの差異でパフォーマンス劣化
  3. node_modules 同様の大量ファイルで bind mount が遅くなる

解決:
  php-vendor という名前付きボリュームで vendor/ をマスクする
  → コンテナ内の vendor/（Docker ビルド時に install したもの）が使われる
  → ホストの vendor/ は見えない（マスクされる）

  composer.json を変更した場合:
  → docker compose build php-fpm でイメージ再ビルド
  → または docker compose exec php-fpm composer install でコンテナ内で実行
```

<br>

### 3-4. WSL2 でのパフォーマンス改善

```
WSL2 でのファイルシステムパフォーマンス:

  /mnt/d/ (Windows ファイルシステム)  → 遅い（9p プロトコル経由）
  ~/projects/ (Linux ファイルシステム) → 速い（ネイティブ ext4）

  bind mount のパフォーマンス比較:
    /mnt/d/repos/myapp → コンテナ:  ~5x 遅い
    ~/repos/myapp → コンテナ:        ネイティブ速度

推奨:
  開発時のソースコードは WSL2 の Linux ファイルシステム側に配置する
  （/home/user/projects/ 配下にクローン）

  Windows 側で VS Code を使う場合:
  → VS Code の Remote WSL 拡張で WSL2 内のファイルを開く
  → エクスプローラーで \\wsl$\Ubuntu\home\user\projects\ でアクセス
```

もし `/mnt/d/` に配置する必要がある場合の対策:

```yaml
# docker-compose.yml に追加
services:
  php-fpm:
    volumes:
      - ../app:/var/www/html:cached    # :cached でホスト→コンテナの同期を遅延許容

      # または、パフォーマンスクリティカルなディレクトリだけ
      # 名前付きボリュームで隔離
      - php-vendor:/var/www/html/vendor
      - php-cache:/var/www/html/storage/cache
```

<br>

### 3-5. 開発コマンド一覧

```bash
# ---- 起動 / 停止 ----
docker compose up -d                      # バックグラウンド起動
docker compose up                         # フォアグラウンド起動（ログ表示）
docker compose down                       # 停止 + コンテナ削除
docker compose down -v                    # 停止 + ボリューム削除（DB初期化）

# ---- ツール付き起動 ----
docker compose --profile tools up -d      # phpMyAdmin + MailHog 付き

# ---- ログ ----
docker compose logs -f                    # 全コンテナのログ
docker compose logs -f php-fpm            # PHP-FPM のログのみ
docker compose logs -f nginx              # Nginx のログのみ

# ---- コンテナ内操作 ----
docker compose exec php-fpm sh            # PHP-FPM コンテナに入る
docker compose exec php-fpm composer install  # Composer 実行
docker compose exec php-fpm php -v        # PHP バージョン確認
docker compose exec mysql mysql -u root -prootpassword myapp  # MySQL接続

# ---- ビルド ----
docker compose build                      # 全イメージ再ビルド
docker compose build --no-cache           # キャッシュなし再ビルド
docker compose build php-fpm              # PHP-FPMだけ再ビルド

# ---- テスト ----
docker compose exec php-fpm vendor/bin/phpunit              # テスト実行
docker compose exec php-fpm vendor/bin/phpunit --filter Spot # 特定モジュール

# ---- 再起動 ----
docker compose restart nginx              # Nginx 設定変更後
docker compose restart php-fpm            # PHP 設定変更後
docker compose up -d --force-recreate     # 全コンテナ再作成

# ---- クリーンアップ ----
docker compose down -v --rmi local        # 全削除（ボリューム + イメージ）
docker system prune -f                    # 未使用イメージ・ボリューム削除
```

<br>

### 3-6. アクセスURL一覧（ローカル開発）

| URL | サービス | 用途 |
|---|---|---|
| http://localhost:8080 | Nginx → PHP-FPM | アプリケーション |
| http://localhost:8080/health | Nginx | ヘルスチェック |
| http://localhost:8081 | phpMyAdmin | DB管理（`--profile tools`） |
| http://localhost:8025 | MailHog | メール確認（`--profile tools`） |
| localhost:3306 | MySQL | DB直接接続（MySQL Workbench等） |

<br>

---

<br>

## 4. Cloud Run マルチコンテナの制約・注意点

<br>

### 4-1. マルチコンテナの基本制約

| 制約 | 値 | 備考 |
|---|---|---|
| 最大コンテナ数 | 10（Ingress 1 + Sidecar 9） | 本構成では 2（Nginx + PHP-FPM） |
| Ingress コンテナ | 必ず1つ | 外部トラフィックを受けるコンテナ |
| ポート公開 | Ingress のみ | Sidecar のポートは外部公開不可 |
| コンテナ間通信 | localhost のみ | 同一ネットワーク名前空間を共有 |
| 共有ボリューム | emptyDir のみ | PersistentVolume は不可 |
| emptyDir サイズ | メモリ上限に含まれる | `medium: Memory` の場合 |
| ライフサイクル | 全コンテナ同一 | 1つ落ちると全体が再起動 |

<br>

### 4-2. Ingress コンテナの要件

```
Cloud Run の Ingress コンテナ:
  - PORT 環境変数（デフォルト 8080）でリッスンしなければならない
  - ヘルスチェック（startup / liveness probe）に応答しなければならない
  - Ingress コンテナが落ちると、リビジョン全体が unhealthy になる
  - 外部からのリクエストは必ず Ingress コンテナが最初に受ける

Sidecar コンテナ:
  - ポートのリッスンは任意（TCP/UDP どちらでも）
  - Ingress コンテナからのみアクセス可能（外部からは不可）
  - startup probe が設定可能（readyになるまで Ingress はトラフィックを受けない）
```

<br>

### 4-3. コンテナの起動順序

```yaml
# Cloud Run サービス定義（YAML形式）
spec:
  template:
    spec:
      containers:
        # Ingress コンテナ（Nginx）— 必ず最初に定義
        - name: nginx
          image: .../nginx:v1
          ports:
            - containerPort: 8080
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 3
          # PHP-FPM が ready になるまで Nginx はトラフィックを受けない
          dependsOn:
            - php-fpm

        # Sidecar コンテナ（PHP-FPM）
        - name: php-fpm
          image: .../php-fpm:v1
          startupProbe:
            tcpSocket:
              port: 9000
            initialDelaySeconds: 2
```

```
起動シーケンス:
  1. Cloud Run がリビジョンを作成
  2. php-fpm コンテナが起動
  3. php-fpm の startup probe が通過（TCP :9000 応答）
  4. nginx コンテナが起動（dependsOn で php-fpm の ready を待つ）
  5. nginx の startup probe が通過（HTTP /health :8080 応答）
  6. Cloud Run がトラフィックをルーティング開始

シャットダウン:
  1. Cloud Run が SIGTERM を全コンテナに送信
  2. 猶予期間（terminationGracePeriodSeconds、デフォルト 10s）
  3. 処理中のリクエストを完了
  4. SIGKILL で強制終了
```

<br>

### 4-4. 共有ボリューム（emptyDir）の注意点

```yaml
volumes:
  - name: app-files
    emptyDir:
      medium: Memory    # tmpfs（RAMに保存）
      sizeLimit: 100Mi  # ← コンテナのメモリ上限に含まれる！
```

| 項目 | 値 | 注意 |
|---|---|---|
| 永続性 | なし（リビジョン再作成で消える） | ユーザーアップロードは GCS を使う |
| パフォーマンス | Memory は高速、Disk は標準 | |
| サイズ上限 | コンテナメモリに含まれる | 100Mi の emptyDir を使うと、コンテナが使えるメモリが 100Mi 減る |
| 用途 | コンテナ間のファイル共有のみ | ログ、キャッシュ、一時ファイル |

**本構成での emptyDir の使い方:**

```
問題:
  Nginx は /var/www/html/public の静的ファイルを配信する
  PHP-FPM は /var/www/html のPHPソースを実行する
  → 両コンテナが同じファイルにアクセスする必要がある

解決策（2つ）:

  方式A: initContainer でファイルをコピー（推奨）
    ① php-fpm イメージの /var/www/html/public を emptyDir にコピー
    ② nginx が emptyDir の public/ を配信
    → PHP-FPM イメージに全ソースが入っているため、
       Nginx イメージにはソースを含めなくてよい

  方式B: 両イメージに同じファイルを含める
    ① php-fpm イメージ: app/ 全体を COPY
    ② nginx イメージ: app/public/ だけを COPY
    → emptyDir 不要、ただしイメージサイズが増える
    → デプロイ時に両イメージのバージョンを揃える必要がある
```

**方式A の実装（initContainer パターン）:**

```yaml
# Cloud Run サービス定義
spec:
  template:
    spec:
      # 初期化コンテナ: PHPソースから静的ファイルを emptyDir にコピー
      initContainers:
        - name: copy-static
          image: .../php-fpm:v1
          command: ["cp", "-r", "/var/www/html/public/.", "/mnt/public/"]
          volumeMounts:
            - name: static-files
              mountPath: /mnt/public

      containers:
        - name: nginx
          image: .../nginx:v1
          volumeMounts:
            - name: static-files
              mountPath: /var/www/html/public
              readOnly: true

        - name: php-fpm
          image: .../php-fpm:v1
          # PHP-FPM はイメージ内の /var/www/html をそのまま使用
          # emptyDir のマウント不要

      volumes:
        - name: static-files
          emptyDir:
            medium: Memory
            sizeLimit: 50Mi
```

<br>

### 4-5. リソース配分の設計

```
Cloud Run インスタンス全体のリソース:
  CPU:    合計値が割り当て（コンテナ間で共有）
  Memory: 各コンテナの limits の合計 ≦ インスタンスの上限

  例: インスタンス = 2 vCPU / 1Gi メモリ
    Nginx:   0.5 vCPU / 256Mi
    PHP-FPM: 1.5 vCPU / 700Mi   ← PHP処理に多くリソースを配分
    emptyDir: 50Mi (Memory)       ← メモリに含まれる
    合計:     2 vCPU / 1006Mi     ← 1Gi (1024Mi) 以内
```

| 環境 | インスタンス | Nginx | PHP-FPM | emptyDir | 合計 |
|---|---|---|---|---|---|
| dev | 1 vCPU / 512Mi | 0.25 CPU / 128Mi | 0.75 CPU / 334Mi | 50Mi | 512Mi |
| prod | 2 vCPU / 1Gi | 0.5 CPU / 256Mi | 1.5 CPU / 718Mi | 50Mi | 1024Mi |

> **注意:** Cloud Run の CPU は全コンテナで共有される。`limits` で上限を設定するが、実際の使用量は動的に配分される。

<br>

### 4-6. コールドスタート対策

```
コールドスタートとは:
  Cloud Run がインスタンス 0 → 1 にスケールアップする際の遅延

  通常のリクエスト:  ~50ms
  コールドスタート:  ~2-5秒（コンテナ起動 + アプリ初期化）

  マルチコンテナではさらに遅くなる可能性:
    php-fpm 起動 → startup probe 通過 → nginx 起動 → startup probe 通過
    → トラフィック受付開始
```

**対策一覧:**

| 対策 | 効果 | コスト |
|---|---|---|
| **min_instances = 1**（prod） | コールドスタートなし | 常時課金 |
| **Alpine ベースイメージ** | イメージ pull 高速化 | なし |
| **マルチステージビルド** | イメージサイズ削減 | なし |
| **OPcache preload** | PHP初回コンパイル不要 | メモリ消費増 |
| **startup probe の調整** | 起動判定の高速化 | なし |
| **CPU boost（起動時）** | 起動時にCPUを一時的に増加 | 自動（Cloud Run gen2） |

```yaml
# Cloud Run サービス定義（コールドスタート対策）
spec:
  template:
    metadata:
      annotations:
        # 起動時にCPUをブースト（gen2 で自動有効）
        run.googleapis.com/startup-cpu-boost: "true"
    spec:
      containerConcurrency: 80
      timeoutSeconds: 60

      containers:
        - name: nginx
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 1    # 短くする（Nginx は高速起動）
            periodSeconds: 2
            failureThreshold: 5

        - name: php-fpm
          startupProbe:
            tcpSocket:
              port: 9000
            initialDelaySeconds: 1    # 短くする
            periodSeconds: 2
            failureThreshold: 5
```

<br>

### 4-7. ログ収集の注意点

```
Cloud Run のログ収集:
  各コンテナの stdout/stderr → Cloud Logging に自動転送

  ただし、マルチコンテナではログの出所が混在する:
    Nginx のログ      → container_name: "nginx"
    PHP-FPM のログ    → container_name: "php-fpm"

  Cloud Logging での絞り込み:
    resource.type = "cloud_run_revision"
    resource.labels.service_name = "myapp-dev-app"
    labels."run.googleapis.com/container_name" = "php-fpm"
```

**ログ設計のベストプラクティス:**

| コンテナ | ログ出力先 | フォーマット | 理由 |
|---|---|---|---|
| Nginx access | stdout | JSON | Cloud Logging が構造化パース |
| Nginx error | stderr | テキスト | エラーはテキストで十分 |
| PHP-FPM access | stderr | JSON | FPMのアクセスログ |
| PHP アプリ | stderr | JSON | `severity` フィールドで重要度制御 |

```
重要: Cloud Logging での severity マッピング

  JSON ログに "severity" フィールドを含めると、
  Cloud Logging が自動的にログレベルとして認識する:

  {"severity": "INFO", "message": "..."}    → ℹ️ INFO
  {"severity": "WARNING", "message": "..."} → ⚠️ WARNING
  {"severity": "ERROR", "message": "..."}   → ❌ ERROR

  severity がないと全て DEFAULT レベルになり、フィルタリングが困難
```

<br>

### 4-8. デプロイ時の注意点

```
マルチコンテナのデプロイ:
  1つのリビジョンに複数コンテナが含まれるため、
  「Nginx だけ更新」「PHP-FPM だけ更新」はできない。

  必ずリビジョン全体（全コンテナ）を同時にデプロイする。

  デプロイ方法:
    gcloud run services replace service.yaml
    → service.yaml に全コンテナのイメージタグを指定
    → 新リビジョンが作成され、トラフィックが切り替わる
```

**イメージタグの戦略:**

| 戦略 | 例 | メリット | デメリット |
|---|---|---|---|
| Git SHA | `nginx:abc123`, `php-fpm:abc123` | 同一コミットの整合性保証 | タグが読みにくい |
| セマンティック | `nginx:1.2.3`, `php-fpm:1.2.3` | バージョンが明確 | 手動管理が必要 |
| **Git SHA + latest** | `nginx:abc123` + `nginx:latest` | CI/CDで自動 + 人間が読める | latest は可変（ロールバック注意） |

> **推奨:** Git SHA をプライマリタグにし、CI/CD で自動付与。`latest` は参照用に併用。

<br>

### 4-9. 制約まとめと対策

| 制約 | 影響 | 対策 |
|---|---|---|
| ファイルシステムが揮発性 | ユーザーアップロード消失 | GCS にアップロード |
| セッションが共有不可 | インスタンス間でセッション不一致 | Redis（Memorystore）or DB セッション |
| コンテナにSSH不可 | デバッグが困難 | 構造化ログ + Cloud Logging で調査 |
| コールドスタート | 初回リクエストが遅い | min_instances=1（prod）+ OPcache preload |
| リクエストタイムアウト 60分 | 長時間バッチ処理不可 | Cloud Tasks / Cloud Run Jobs に分離 |
| emptyDir がメモリに含まれる | 使えるメモリが減る | sizeLimit を最小限に |
| 全コンテナ同時デプロイ | 個別更新不可 | CI/CDで全イメージを同時ビルド・タグ付け |
| 最大 10 コンテナ | 本構成では問題なし（2コンテナ） | — |
