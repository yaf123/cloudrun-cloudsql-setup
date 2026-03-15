# Cloud Run + Cloud SQL モジュラーモノリス 堅牢構成 仕様書

<br>

## 1. 全体構成図

```
                        ┌─────────────────────────────────────────────┐
                        │                 Internet                    │
                        └────────────────────┬────────────────────────┘
                                             │
                                   ┌─────────▼─────────┐
                                   │    Cloud Armor     │
                                   │  (WAF / DDoS防御)  │
                                   └─────────┬─────────┘
                                             │
                                   ┌─────────▼─────────┐
                                   │  External App LB   │
                                   │  (HTTPS / L7)      │
                                   │  Anycast Global IP  │
                                   └─────────┬─────────┘
                                             │
                                   Serverless NEG
                                             │
 ┌───────────────────────────────────────────┼──────────────────────────────┐
 │  VPC: {prefix}-vpc                        │                              │
 │                                           │                              │
 │  ┌───────────────────────────────────────┼────────────────────────┐     │
 │  │  Cloud Run Service: {prefix}-app      │                        │     │
 │  │  ┌────────────────────────────────────┼──────────────────┐     │     │
 │  │  │  Cloud Run Revision (Multi-Container / Sidecar)       │     │     │
 │  │  │                                    │                  │     │     │
 │  │  │  ┌─────────────┐    ┌─────────────▼─────────┐        │     │     │
 │  │  │  │  Sidecar     │    │  Ingress Container    │        │     │     │
 │  │  │  │  PHP-FPM     │◀──│  Nginx                │        │     │     │
 │  │  │  │  :9000       │    │  :8080                │        │     │     │
 │  │  │  │              │    │  静的ファイル配信       │        │     │     │
 │  │  │  │  PHPアプリ    │    │  リバースプロキシ       │        │     │     │
 │  │  │  │  モジュラー   │    │  gzip / キャッシュ     │        │     │     │
 │  │  │  │  モノリス     │    │                       │        │     │     │
 │  │  │  └──────┬──────┘    └─────────────────────┘        │     │     │
 │  │  │         │                                           │     │     │
 │  │  └─────────│───────────────────────────────────────────┘     │     │
 │  │            │ Direct VPC Egress                               │     │
 │  │            │                                                 │     │
 │  │  ┌─────────▼─────────┐                                       │     │
 │  │  │  Cloud SQL         │                                       │     │
 │  │  │  MySQL 8.0         │                                       │     │
 │  │  │  {prefix}-db       │                                       │     │
 │  │  │  Private IPのみ    │                                       │     │
 │  │  └───────────────────┘                                       │     │
 │  │                                                              │     │
 │  │  Subnet: {prefix}-subnet                                    │     │
 │  │  asia-northeast1                                             │     │
 │  └──────────────────────────────────────────────────────────────┘     │
 │                                                                       │
 │  ┌────────────────────────────────────────────┐                      │
 │  │  Serverless VPC Access Connector            │                      │
 │  │  or Direct VPC Egress                       │                      │
 │  └────────────────────────────────────────────┘                      │
 └───────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────┐
 │  Artifact Registry               │
 │  Docker イメージ管理              │
 │  nginx / php-fpm                 │
 └──────────────────────────────────┘

 ┌──────────────────────────────────┐
 │  Cloud Build / GitHub Actions    │
 │  CI/CD パイプライン               │
 └──────────────────────────────────┘

 ┌──────────────────────────────────┐
 │  Cloud Logging + Monitoring      │
 │  (Cloud Run統合 / 自動収集)       │
 └──────────────────────────────────┘
```

**{prefix}** は環境ごとに異なる: `myapp-dev` / `myapp-prod`

<br>

---

<br>

## 2. GCE構成との比較

<br>

### 2-1. アーキテクチャ比較

| 観点 | GCE + Cloud SQL（既存） | Cloud Run + Cloud SQL（本構成） |
|---|---|---|
| コンピュート | GCE（VM常時起動） | Cloud Run（サーバーレス） |
| スケーリング | 手動（VM追加 or MIG） | 自動（0〜N、リクエストベース） |
| Webサーバー | Apache（VM内） | Nginx（サイドカーコンテナ） |
| PHP実行 | mod_php（Apache モジュール） | PHP-FPM（独立コンテナ） |
| DB接続 | Cloud SQL Auth Proxy（VM内常駐） | Cloud Run 組み込みコネクタ |
| デプロイ | Ansible（SSH経由push） | Docker イメージ push → Cloud Run デプロイ |
| SSH接続 | IAP経由で可能 | 不可（コンテナは一時的） |
| OS管理 | パッチ適用が必要 | 不要（マネージド） |
| 可用性 | 1台構成 = SPOF | マルチインスタンス自動 |
| コスト | 常時課金（~$60/月） | 従量課金（トラフィック次第） |

<br>

### 2-2. Cloud Run を選ぶ理由

| メリット | 詳細 |
|---|---|
| **OS管理不要** | セキュリティパッチ、カーネル更新が不要 |
| **自動スケーリング** | 0インスタンスまでスケールダウン可能（コスト最適化） |
| **高可用性** | 複数インスタンスが自動的にマルチゾーンで稼働 |
| **デプロイの安全性** | リビジョンベースのデプロイ、トラフィック分割、ロールバックが容易 |
| **Dockerポータビリティ** | ローカル開発環境とプロダクションの差異が少ない |

| デメリット | 詳細 |
|---|---|
| **SSHデバッグ不可** | 実行中コンテナに入れない（ログベースのデバッグが必要） |
| **コールドスタート** | 0→1スケール時にレイテンシが発生（最小インスタンス数で緩和） |
| **リクエストタイムアウト** | 最大60分（長時間バッチ処理には不向き） |
| **ファイルシステム** | 一時的（永続ストレージはGCS等を使用） |
| **学習コスト** | Docker / コンテナの知識が必要 |

<br>

### 2-3. コスト比較

| 項目 | GCE構成（dev） | Cloud Run構成（dev） |
|---|---|---|
| コンピュート | ~$15/月（e2-small常時起動） | ~$5〜15/月（トラフィック次第） |
| Cloud SQL | ~$10/月（db-f1-micro） | ~$10/月（同じ） |
| LB | ~$20/月 | ~$20/月 |
| Cloud NAT | ~$5/月 | $0（不要） |
| Cloud Armor | ~$5/月 | ~$5/月 |
| Artifact Registry | $0 | ~$1/月 |
| VPC Connector | $0 | ~$7/月（Direct VPC Egress なら $0） |
| **合計** | **~$60/月** | **~$45〜55/月** |

> **ポイント:** Cloud Run はトラフィックが少ない場合にコスト優位。最小インスタンス=0 に設定すれば、アクセスがない時間帯は課金ゼロ。

<br>

---

<br>

## 3. Cloud Run マルチコンテナ構成

<br>

### 3-1. サイドカーパターン

Cloud Run のマルチコンテナ（サイドカー）機能を使い、1つのリビジョン内に複数コンテナを配置する。

```
Cloud Run Revision
┌─────────────────────────────────────────────────────┐
│                                                     │
│  ┌───────────────────┐    ┌───────────────────┐     │
│  │  Ingress Container │    │  Sidecar Container │    │
│  │                    │    │                    │     │
│  │  Nginx             │    │  PHP-FPM           │     │
│  │  :8080 (ingress)   │───▶│  :9000 (FastCGI)   │     │
│  │                    │    │                    │     │
│  │  - 静的ファイル配信  │    │  - PHPリクエスト処理 │     │
│  │  - gzip圧縮        │    │  - DB接続           │     │
│  │  - リバースプロキシ  │    │  - セッション管理    │     │
│  │  - アクセスログ     │    │  - ビジネスロジック   │     │
│  │                    │    │                    │     │
│  │  [共有ボリューム]   │    │  [共有ボリューム]   │     │
│  │  /var/www/html ◀───│────│──▶ /var/www/html    │     │
│  └───────────────────┘    └───────────────────┘     │
│                                                     │
│  共有: localhost ネットワーク + emptyDir ボリューム     │
└─────────────────────────────────────────────────────┘
```

<br>

### 3-2. コンテナ間通信

| 項目 | 値 |
|---|---|
| 通信方式 | localhost（同一Pod内） |
| プロトコル | FastCGI（TCP :9000） |
| ファイル共有 | emptyDir ボリューム（`/var/www/html`） |
| Ingress ポート | 8080（Cloud Run のデフォルト） |

**なぜマルチコンテナにするか:**

- Nginx と PHP-FPM を分離することで、それぞれ独立にチューニング・更新可能
- Nginx が静的ファイル（CSS, JS, 画像）を直接配信 → PHP-FPM の負荷軽減
- 本番に近い構成でローカル開発（docker compose）が可能
- 将来的に Nginx を他のリバースプロキシ（Envoy等）に差し替え可能

<br>

### 3-3. 代替案: シングルコンテナ構成

```
Cloud Run Revision（シングルコンテナ）
┌──────────────────────────────┐
│  Apache + mod_php            │
│  :8080                       │
│  - 静的 + 動的を一括処理      │
│  - 構成がシンプル             │
│  - Docker イメージ1つで完結   │
└──────────────────────────────┘
```

| 観点 | マルチコンテナ（採用） | シングルコンテナ |
|---|---|---|
| 構成 | Nginx + PHP-FPM | Apache + mod_php |
| パフォーマンス | 高い（静的配信分離） | 標準 |
| 柔軟性 | 高い（個別更新可） | 低い |
| 複雑度 | やや高い | シンプル |
| ローカル開発 | docker compose で再現 | 単一コンテナで簡単 |
| 推奨場面 | 本番運用・パフォーマンス重視 | プロトタイプ・学習用 |

> **判断:** 堅牢構成を目指すため、マルチコンテナ（Nginx + PHP-FPM）を採用。

<br>

---

<br>

## 4. Docker 構成

<br>

### 4-1. ディレクトリ構成

```
docker/
├── nginx/
│   ├── Dockerfile
│   ├── nginx.conf                 ← メイン設定
│   └── conf.d/
│       └── default.conf           ← サーバーブロック（FastCGI proxy）
│
├── php-fpm/
│   ├── Dockerfile
│   ├── php.ini                    ← PHP設定（本番用）
│   ├── php-fpm.conf               ← FPMグローバル設定
│   └── www.conf                   ← FPMプールワーカー設定
│
├── docker-compose.yml             ← ローカル開発用
├── docker-compose.prod.yml        ← 本番シミュレート用
└── .dockerignore
```

<br>

### 4-2. Nginx Dockerfile

```dockerfile
# docker/nginx/Dockerfile
FROM nginx:1.27-alpine

# タイムゾーン設定
RUN apk add --no-cache tzdata \
    && cp /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && echo "Asia/Tokyo" > /etc/timezone

# Nginx設定
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/

# PHPアプリの静的ファイル（ビルド時にPHP-FPMイメージからコピー）
# → docker-compose ではボリュームマウント、Cloud Run では emptyDir
# COPY --from=php-app /var/www/html/public /var/www/html/public

# ヘルスチェック用
RUN echo "OK" > /usr/share/nginx/html/health

# Cloud Run はポート8080を期待
EXPOSE 8080

# Nginxをフォアグラウンドで実行
CMD ["nginx", "-g", "daemon off;"]
```

<br>

### 4-3. Nginx 設定

```nginx
# docker/nginx/nginx.conf
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Cloud Run はstdout/stderrを Cloud Logging に自動転送
    log_format json escape=json '{'
        '"time":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"request_method":"$request_method",'
        '"request_uri":"$request_uri",'
        '"status":$status,'
        '"body_bytes_sent":$body_bytes_sent,'
        '"request_time":$request_time,'
        '"upstream_response_time":"$upstream_response_time",'
        '"http_user_agent":"$http_user_agent",'
        '"http_x_forwarded_for":"$http_x_forwarded_for"'
    '}';
    access_log /dev/stdout json;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    # gzip圧縮
    gzip on;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript;
    gzip_min_length 1000;

    # セキュリティヘッダ
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # アップロードサイズ上限
    client_max_body_size 20M;

    include /etc/nginx/conf.d/*.conf;
}
```

```nginx
# docker/nginx/conf.d/default.conf
server {
    listen 8080;
    server_name _;

    root /var/www/html/public;
    index index.php index.html;

    # ヘルスチェック（LB / Cloud Run）
    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # 静的ファイル（Nginx直接配信）
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # PHPリクエスト → PHP-FPM（サイドカー）へ転送
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;

        # タイムアウト設定
        fastcgi_connect_timeout 10s;
        fastcgi_send_timeout 60s;
        fastcgi_read_timeout 60s;

        # バッファ設定
        fastcgi_buffer_size 16k;
        fastcgi_buffers 16 16k;
    }

    # .env / .git 等のアクセス拒否
    location ~ /\. {
        deny all;
        return 404;
    }
}
```

<br>

### 4-4. PHP-FPM Dockerfile

```dockerfile
# docker/php-fpm/Dockerfile

# ---- ステージ1: Composer依存解決 ----
FROM composer:2 AS composer-deps
WORKDIR /app
COPY app/composer.json app/composer.lock* ./
RUN composer install --no-dev --optimize-autoloader --no-scripts

# ---- ステージ2: 本番イメージ ----
FROM php:8.2-fpm-alpine

# タイムゾーン設定
RUN apk add --no-cache tzdata \
    && cp /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && echo "Asia/Tokyo" > /etc/timezone

# PHP拡張インストール
RUN apk add --no-cache \
        libpng-dev libjpeg-turbo-dev freetype-dev \
        icu-dev oniguruma-dev libzip-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql mysqli gd intl mbstring zip opcache

# PHP設定
COPY php.ini /usr/local/etc/php/php.ini
COPY php-fpm.conf /usr/local/etc/php-fpm.conf
COPY www.conf /usr/local/etc/php-fpm.d/www.conf

# アプリケーションコード
WORKDIR /var/www/html
COPY app/ ./
COPY --from=composer-deps /app/vendor ./vendor

# パーミッション設定
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html

# PHP-FPM はポート9000で待ち受け
EXPOSE 9000

# PHP-FPM をフォアグラウンドで実行
CMD ["php-fpm", "-F"]
```

<br>

### 4-5. PHP設定（本番用）

```ini
; docker/php-fpm/php.ini
[PHP]
; エラー設定
display_errors = Off
display_startup_errors = Off
log_errors = On
error_log = /dev/stderr
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT

; パフォーマンス
memory_limit = 256M
max_execution_time = 60
max_input_time = 60
upload_max_filesize = 20M
post_max_size = 25M

; タイムゾーン
date.timezone = Asia/Tokyo

; セッション（Cloud Run はステートレスのため外部ストアを推奨）
session.save_handler = files
session.save_path = /tmp

; OPcache（本番では必須）
[opcache]
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.save_comments = 1
opcache.fast_shutdown = 1
```

```ini
; docker/php-fpm/www.conf
[www]
user = www-data
group = www-data

listen = 0.0.0.0:9000

; プロセス管理
pm = dynamic
pm.max_children = 20
pm.start_servers = 5
pm.min_spare_servers = 3
pm.max_spare_servers = 10
pm.max_requests = 500

; ステータス（内部監視用）
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong

; ログ
access.log = /dev/stderr
access.format = '{"time":"%{%Y-%m-%dT%H:%M:%S%z}T","client":"%R","method":"%m","request_uri":"%r","status":"%s","duration":"%dms","memory":"%{mega}MMB"}'

; タイムアウト
request_terminate_timeout = 60s

; Cloud Run のヘルスチェック対応
catch_workers_output = yes
decorate_workers_output = no
```

<br>

### 4-6. docker-compose（ローカル開発用）

```yaml
# docker/docker-compose.yml
services:
  nginx:
    build:
      context: .
      dockerfile: nginx/Dockerfile
    ports:
      - "8080:8080"
    volumes:
      - ../app/public:/var/www/html/public:ro    # 静的ファイル
    depends_on:
      php-fpm:
        condition: service_started

  php-fpm:
    build:
      context: ..
      dockerfile: docker/php-fpm/Dockerfile
    volumes:
      - ../app:/var/www/html                      # PHPソースをマウント
    environment:
      - APP_ENV=local
      - DB_HOST=mysql
      - DB_PORT=3306
      - DB_NAME=myapp
      - DB_USER=myapp-app
      - DB_PASSWORD=localpassword
    depends_on:
      mysql:
        condition: service_healthy

  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: myapp
      MYSQL_USER: myapp-app
      MYSQL_PASSWORD: localpassword
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 10

volumes:
  mysql-data:
```

<br>

---

<br>

## 5. ネットワーク構成

<br>

### 5-1. VPC

| 項目 | 値 |
|---|---|
| 名前 | `{prefix}-vpc` |
| モード | カスタム |
| 備考 | Cloud Run からの VPC 内通信に使用 |

<br>

### 5-2. サブネット

| 項目 | dev | prod |
|---|---|---|
| 名前 | `myapp-dev-subnet` | `myapp-prod-subnet` |
| リージョン | asia-northeast1 | asia-northeast1 |
| CIDR | 10.0.0.0/24 | 10.10.0.0/24 |
| Private Google Access | 有効 | 有効 |

<br>

### 5-3. Cloud Run → Cloud SQL 接続方式

Cloud Run から Cloud SQL へ Private IP で接続する方式は2つある:

| 方式 | VPC Access Connector | Direct VPC Egress（採用） |
|---|---|---|
| 仕組み | 専用VMインスタンス（e2-micro x2〜）でトンネリング | Cloud Run が直接 VPC サブネットにアタッチ |
| コスト | ~$7/月（VM常時起動） | $0（追加コストなし） |
| パフォーマンス | VMのスループットに依存 | ネイティブ、低レイテンシ |
| スケーラビリティ | VM数でスケール（手動設定） | Cloud Run と連動 |
| 設定 | Connector リソース作成が必要 | サブネット指定のみ |
| GA時期 | 初期からGA | 2024年GA |

> **判断:** Direct VPC Egress を採用。コスト$0、パフォーマンス優位、設定がシンプル。

<br>

### 5-4. Private Services Access

| 項目 | dev | prod |
|---|---|---|
| IP範囲名 | `myapp-dev-google-managed-services` | `myapp-prod-google-managed-services` |
| CIDR | 10.1.0.0/24 | 10.11.0.0/24 |
| ピアリング先 | `servicenetworking.googleapis.com` | `servicenetworking.googleapis.com` |

<br>

### 5-5. ファイアウォールルール

Cloud Run 構成では GCE 向けのファイアウォールルールは不要（Cloud Run はマネージド）。
Cloud SQL 向けの Private Services Access 通信は VPC ピアリングで自動ルーティング。

| ルール名 | 方向 | ソース | ターゲット | ポート | 用途 |
|---|---|---|---|---|---|
| `{prefix}-deny-all-ingress` | Ingress | 0.0.0.0/0 | 全て | 全て | デフォルト拒否 |

> **GCE構成との違い:** IAP SSH 用ルール、LBヘルスチェック用ルールが不要になる。

<br>

---

<br>

## 6. Cloud SQL 構成

GCE構成と同一設計。

<br>

### 6-1. インスタンス仕様

| 項目 | dev | prod |
|---|---|---|
| 名前 | `myapp-dev-db` | `myapp-prod-db` |
| データベースエンジン | MySQL 8.0 | MySQL 8.0 |
| マシンタイプ | db-f1-micro (0.6GB) | db-g1-small (1.7GB) |
| 高可用性 | 無効 | 有効（リージョナル） |
| ストレージ | SSD 10GB（自動拡張有効） | SSD 10GB（自動拡張有効） |
| 接続 | Private IP のみ | Private IP のみ |
| 削除保護 | 無効 | 有効 |

<br>

### 6-2. バックアップ

| 項目 | dev | prod |
|---|---|---|
| 自動バックアップ | 有効 | 有効 |
| バックアップ時間 | 03:00 JST | 03:00 JST |
| 保持期間 | 7日間 | 30日間 |
| PITR | 有効 | 有効 |

<br>

### 6-3. Cloud Run からの接続方式

```
Cloud Run コンテナ (PHP-FPM)
  │
  │ Direct VPC Egress
  │ (Cloud Run が直接 VPC に参加)
  │
  ▼ Private IP:3306
Cloud SQL (MySQL 8.0)
```

| 項目 | GCE構成 | Cloud Run構成 |
|---|---|---|
| 接続方式 | Cloud SQL Auth Proxy (localhost:3306) | Direct VPC Egress (Private IP:3306) |
| TLS | Auth Proxy が自動 | Cloud SQL の SSL 強制 or VPC内通信 |
| 認証 | パスワード（Secret Manager） | パスワード（Secret Manager） |
| 設定 | systemd サービス管理が必要 | Cloud Run のアノテーションのみ |

> **Cloud Run の利点:** Cloud SQL Auth Proxy のインストール・管理が不要。Cloud Run のビルトイン接続機能または Direct VPC Egress で Private IP に直接接続。

<br>

### 6-4. Secret Manager（DBパスワード管理）

| 項目 | 値 |
|---|---|
| シークレットID | `{prefix}-db-password` |
| アクセス | Cloud Run サービスアカウントに `roles/secretmanager.secretAccessor` |
| 取得方法 | Cloud Run の環境変数にマウント or アプリ内でSDK取得 |

**Cloud Run での Secret Manager 統合:**

```yaml
# Cloud Run サービス定義（terraform）
env:
  - name: DB_PASSWORD
    value_source:
      secret_key_ref:
        secret: myapp-dev-db-password
        version: latest
```

Cloud Run は Secret Manager のシークレットを**環境変数として直接マウント**できる。
GCE構成のように `gcloud secrets` コマンドで取得する必要がない。

<br>

---

<br>

## 7. Cloud Run サービス構成

<br>

### 7-1. サービス仕様

| 項目 | dev | prod |
|---|---|---|
| サービス名 | `myapp-dev-app` | `myapp-prod-app` |
| リージョン | asia-northeast1 | asia-northeast1 |
| Ingress | Internal + LB（外部直接アクセス不可） | Internal + LB |
| 最小インスタンス | 0 | 1 |
| 最大インスタンス | 5 | 20 |
| 同時リクエスト数/インスタンス | 80 | 80 |
| リクエストタイムアウト | 60s | 60s |
| 実行環境 | 第2世代（gen2） | 第2世代（gen2） |
| VPC Egress | Direct VPC Egress | Direct VPC Egress |

<br>

### 7-2. Ingress コンテナ（Nginx）

| 項目 | 値 |
|---|---|
| イメージ | `{region}-docker.pkg.dev/{project}/{repo}/nginx:{tag}` |
| ポート | 8080（Cloud Run ingress） |
| CPU | 0.5 vCPU |
| メモリ | 256Mi |
| 役割 | 静的ファイル配信、gzip、リバースプロキシ |

<br>

### 7-3. サイドカー コンテナ（PHP-FPM）

| 項目 | 値 |
|---|---|
| イメージ | `{region}-docker.pkg.dev/{project}/{repo}/php-fpm:{tag}` |
| ポート | 9000（FastCGI） |
| CPU | 1 vCPU |
| メモリ | 512Mi |
| 役割 | PHPリクエスト処理、DB接続、ビジネスロジック |

<br>

### 7-4. 共有ボリューム

```yaml
volumes:
  - name: app-files
    emptyDir:
      medium: Memory      # tmpfs（高速、揮発性）
      sizeLimit: 100Mi
```

| 用途 | マウントパス | 説明 |
|---|---|---|
| PHPソースコード | `/var/www/html` | PHP-FPM イメージにビルド済み、Nginx にも共有 |
| 静的ファイル | `/var/www/html/public` | CSS, JS, 画像をNginxが直接配信 |

> **注意:** Cloud Run の emptyDir はリビジョンデプロイ時にリセットされる。永続データは Cloud SQL or GCS に保存すること。

<br>

### 7-5. 起動順序の制御

Cloud Run マルチコンテナでは、コンテナの起動順序を `depends_on` で制御できる。

```
Nginx (ingress) ─── depends_on ──→ PHP-FPM (sidecar)
                                      │
                                      │ startup_probe で待機
                                      ▼
                                   PHP-FPM ready (port 9000)
                                      │
                                   Nginx ready (port 8080)
                                      │
                                   Cloud Run がトラフィックを流す
```

PHP-FPM が先に起動し、Nginx は PHP-FPM の準備完了を待ってからリクエストを受ける。

<br>

### 7-6. ヘルスチェック

| コンテナ | プローブ | パス/ポート | 設定 |
|---|---|---|---|
| PHP-FPM | Startup Probe | TCP :9000 | initialDelay=2s, period=5s |
| Nginx | Startup Probe | HTTP /health :8080 | initialDelay=3s, period=5s |
| Nginx | Liveness Probe | HTTP /health :8080 | period=10s |

<br>

### 7-7. 環境変数

| 変数 | 設定方法 | 値 |
|---|---|---|
| `APP_ENV` | 直接 | `dev` / `prod` |
| `DB_HOST` | 直接 | Cloud SQL Private IP |
| `DB_PORT` | 直接 | `3306` |
| `DB_NAME` | 直接 | `myapp` |
| `DB_USER` | 直接 | `myapp-app` |
| `DB_PASSWORD` | Secret Manager マウント | `{prefix}-db-password:latest` |

<br>

---

<br>

## 8. ロードバランサー + Cloud Armor

<br>

### 8-1. 構成要素

```
Global Anycast IP
  │
  ▼
Forwarding Rule (HTTPS:443)
  │
  ▼
Target HTTPS Proxy
  │  ├─ SSL証明書（Googleマネージド）
  │
  ▼
URL Map
  │  ├─ デフォルト: Serverless NEG
  │
  ▼
Backend Service ←── Cloud Armor Policy
  │
  ▼
Serverless NEG (Cloud Run サービス)
  │
  ▼
Cloud Run Service ({prefix}-app)
```

<br>

### 8-2. Serverless NEG

| 項目 | 値 |
|---|---|
| 名前 | `{prefix}-neg` |
| タイプ | Serverless |
| Cloud Run サービス | `{prefix}-app` |
| リージョン | asia-northeast1 |

> **GCE構成との違い:** Unmanaged Instance Group の代わりに Serverless NEG を使用。GCE再作成時のIG脱落問題（`replace_triggered_by` 対策）が不要。

<br>

### 8-3. Cloud Armor（GCE構成と同一）

| 優先度 | 条件 | アクション | dev | prod |
|---|---|---|---|---|
| 1000 | SQLインジェクション | deny(403) | 同じ | 同じ |
| 1001 | XSS | deny(403) | 同じ | 同じ |
| 1002 | レート制限 | throttle→deny(429) | 100 req/min | 200 req/min |
| 2147483647 | デフォルト | allow | 同じ | 同じ |

<br>

### 8-4. Cloud Run Ingress 設定

| 項目 | 値 | 理由 |
|---|---|---|
| Ingress | `internal-and-cloud-load-balancing` | LB経由のみアクセス可能、直接URLアクセスを拒否 |

Cloud Run のデフォルトURL（`xxx.run.app`）への直接アクセスを禁止し、必ずLB（+ Cloud Armor）経由にする。

<br>

---

<br>

## 9. CI/CD パイプライン

<br>

### 9-1. パイプライン全体図

```
Developer
  │
  │  git push
  ▼
GitHub Repository
  │
  │  トリガー（push to main / tag）
  ▼
Cloud Build
  │
  ├─ Step 1: PHP テスト実行
  │
  ├─ Step 2: Docker イメージビルド
  │    ├─ nginx イメージ
  │    └─ php-fpm イメージ
  │
  ├─ Step 3: Artifact Registry に push
  │    ├─ {region}-docker.pkg.dev/{project}/{repo}/nginx:{tag}
  │    └─ {region}-docker.pkg.dev/{project}/{repo}/php-fpm:{tag}
  │
  └─ Step 4: Cloud Run デプロイ
       └─ gcloud run services replace service.yaml
```

<br>

### 9-2. Artifact Registry

| 項目 | 値 |
|---|---|
| リポジトリ名 | `{prefix}-docker` |
| 形式 | Docker |
| リージョン | asia-northeast1 |
| クリーンアップポリシー | 最新10バージョン保持 |

<br>

### 9-3. Cloud Build 構成

```yaml
# cloudbuild.yaml
steps:
  # PHPテスト
  - name: 'composer:2'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        cd app
        composer install
        vendor/bin/phpunit

  # Nginx イメージビルド
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-t'
      - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/nginx:${SHORT_SHA}'
      - '-f'
      - 'docker/nginx/Dockerfile'
      - 'docker/nginx'

  # PHP-FPM イメージビルド
  - name: 'gcr.io/cloud-builders/docker'
    args:
      - 'build'
      - '-t'
      - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/php-fpm:${SHORT_SHA}'
      - '-f'
      - 'docker/php-fpm/Dockerfile'
      - '.'

  # イメージ push
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '--all-tags', '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/nginx']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', '--all-tags', '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/php-fpm']

  # Cloud Run デプロイ
  - name: 'gcr.io/google.com/cloudsdktool/cloud-sdk'
    entrypoint: 'gcloud'
    args:
      - 'run'
      - 'services'
      - 'replace'
      - 'cloud-run-service.yaml'
      - '--region=${_REGION}'

substitutions:
  _REGION: asia-northeast1
  _REPO: myapp-dev-docker

images:
  - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/nginx:${SHORT_SHA}'
  - '${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_REPO}/php-fpm:${SHORT_SHA}'
```

<br>

### 9-4. デプロイ戦略

| 戦略 | 説明 | 設定 |
|---|---|---|
| **ローリングデプロイ（デフォルト）** | 新リビジョンにトラフィックを100%切り替え | `--no-traffic` なし |
| カナリアデプロイ | 新リビジョンに一部（例: 10%）のトラフィックを流す | `--tag canary --no-traffic` → 手動でトラフィック分割 |
| ロールバック | 前のリビジョンにトラフィックを戻す | `gcloud run services update-traffic --to-revisions=PREV=100` |

<br>

---

<br>

## 10. モジュラーモノリス設計

<br>

### 10-1. モジュラーモノリスとは

```
┌─────────────────────────────────────────────────────┐
│  単一デプロイ単位（1つの Docker イメージ）              │
│                                                     │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐       │
│  │  Module A  │  │  Module B  │  │  Module C  │      │
│  │  店舗管理   │  │  口コミ    │  │  ユーザー   │      │
│  │           │  │           │  │           │       │
│  │  Service  │  │  Service  │  │  Service  │       │
│  │  Repo     │  │  Repo     │  │  Repo     │       │
│  │  Model    │  │  Model    │  │  Model    │       │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘       │
│        │              │              │              │
│  ──────┴──────────────┴──────────────┴───────       │
│                  共有DB (Cloud SQL)                   │
│                  共有インフラ（ルーティング、認証）        │
└─────────────────────────────────────────────────────┘
```

| 観点 | モノリス | モジュラーモノリス | マイクロサービス |
|---|---|---|---|
| デプロイ単位 | 1つ | 1つ | 複数（サービスごと） |
| コード構成 | 区分なし | モジュール分離 | 独立リポジトリ |
| DB | 共有 | 共有（スキーマ分離推奨） | 個別DB |
| 通信 | 関数呼び出し | インターフェース経由 | API / メッセージ |
| 複雑度 | 低い | 中程度 | 高い |
| 適用規模 | 小規模 | **中規模（今回）** | 大規模 |

> **判断:** 現在の myapp プロジェクトの規模（PHPアプリ、チーム少人数）では、マイクロサービスは過剰。モジュラーモノリスで**将来の分離を見据えた境界**を設けつつ、運用はシンプルに保つ。

<br>

### 10-2. PHPアプリのディレクトリ構成

```
app/
├── public/                          ← Nginx のドキュメントルート
│   ├── index.php                    ← エントリーポイント（フロントコントローラー）
│   └── assets/                      ← 静的ファイル（CSS, JS, 画像）
│
├── src/                             ← アプリケーションコード
│   ├── Kernel.php                   ← アプリケーションカーネル（ルーティング、DI）
│   │
│   ├── Shared/                      ← 共有モジュール（横断的関心事）
│   │   ├── Database/                ←   DB接続管理
│   │   │   └── Connection.php
│   │   ├── Http/                    ←   リクエスト/レスポンス
│   │   │   ├── Request.php
│   │   │   └── Response.php
│   │   ├── Auth/                    ←   認証・認可
│   │   └── Config/                  ←   設定管理
│   │       └── Config.php
│   │
│   ├── Spot/                        ← 店舗モジュール
│   │   ├── SpotController.php       ←   コントローラー
│   │   ├── SpotService.php          ←   ビジネスロジック
│   │   ├── SpotRepository.php       ←   DBアクセス
│   │   ├── Spot.php                 ←   エンティティ
│   │   └── routes.php               ←   モジュール内ルーティング
│   │
│   ├── Review/                      ← 口コミモジュール
│   │   ├── ReviewController.php
│   │   ├── ReviewService.php
│   │   ├── ReviewRepository.php
│   │   ├── Review.php
│   │   └── routes.php
│   │
│   └── Admin/                       ← 管理モジュール
│       ├── AdminController.php
│       ├── AdminService.php
│       └── routes.php
│
├── config/                          ← 設定ファイル
│   ├── app.php
│   ├── database.php
│   └── routes.php                   ← 全モジュールのルーティングを集約
│
├── tests/                           ← テスト
│   ├── Spot/
│   ├── Review/
│   └── Admin/
│
├── vendor/                          ← Composer依存（gitignore）
├── composer.json
└── composer.lock
```

<br>

### 10-3. モジュール間ルール

| ルール | 説明 |
|---|---|
| **モジュール内は自由** | Controller → Service → Repository の呼び出しは自由 |
| **モジュール間はService経由** | 他モジュールの Repository を直接呼ばない。Service のパブリックメソッドのみ |
| **共有モジュールは誰でも使える** | `Shared/` 配下は全モジュールから利用可能 |
| **DBテーブルのオーナーシップ** | 各テーブルはどれか1つのモジュールが「所有」する。他モジュールはJOINではなくService経由で取得 |
| **将来の分離ポイント** | Service のインターフェースがそのままAPI境界になる |

```php
// OK: Review モジュールから Spot モジュールの Service を呼ぶ
class ReviewService {
    public function __construct(
        private ReviewRepository $reviewRepo,
        private \App\Spot\SpotService $spotService  // Service経由
    ) {}

    public function getReviewsWithSpot(int $spotId): array {
        $spot = $this->spotService->getById($spotId);  // OK
        $reviews = $this->reviewRepo->findBySpotId($spotId);
        return ['spot' => $spot, 'reviews' => $reviews];
    }
}

// NG: Review モジュールから Spot モジュールの Repository を直接呼ぶ
// $spotRepo = new \App\Spot\SpotRepository();  // NG: モジュール境界違反
```

<br>

### 10-4. DB設計（テーブルオーナーシップ）

| モジュール | 所有テーブル | 備考 |
|---|---|---|
| Spot | `spots`, `spot_photos`, `spot_categories` | 店舗の基本情報 |
| Review | `reviews`, `review_photos` | 口コミデータ |
| Admin | `admin_users`, `admin_logs` | 管理画面用 |
| Shared | `migrations` | DBマイグレーション管理 |

> **既存テーブルの扱い:** 既存の myapp DB テーブルは段階的にモジュールに割り当てる。初期は全テーブルを `Shared` 扱いとし、機能単位でモジュールに移行する。

<br>

---

<br>

## 11. 監視・ログ

<br>

### 11-1. Cloud Run の自動ログ収集

Cloud Run は以下を**設定不要で自動収集**する（GCE の Ops Agent 相当が不要）:

| ログ種別 | 収集方法 | Cloud Logging での確認 |
|---|---|---|
| リクエストログ | Cloud Run 自動 | リソース: `Cloud Run Revision` |
| Nginx アクセスログ | stdout (JSON) | `jsonPayload` で構造化検索 |
| Nginx エラーログ | stderr | ログレベルで絞り込み |
| PHP エラーログ | stderr | ログレベルで絞り込み |
| PHP アプリログ | stderr (JSON推奨) | `jsonPayload` で構造化検索 |
| Cloud SQL ログ | 自動（マネージドサービス） | リソース: `Cloud SQL Database` |

> **GCE構成との違い:** Ops Agent のインストール・設定が不要。コンテナの stdout/stderr が自動的に Cloud Logging に転送される。

<br>

### 11-2. 構造化ログ（推奨）

Cloud Run では、stdout に JSON を出力すると Cloud Logging が自動的に構造化ログとして解析する。

```php
// PHP アプリでの構造化ログ出力
function app_log(string $level, string $message, array $context = []): void {
    $entry = [
        'severity' => strtoupper($level),   // Cloud Logging の severity にマッピング
        'message'  => $message,
        'context'  => $context,
        'timestamp' => date('c'),
    ];
    fwrite(STDERR, json_encode($entry) . "\n");
}

// 使用例
app_log('INFO', 'Spot updated', ['spot_id' => 123, 'module' => 'Spot']);
app_log('ERROR', 'DB connection failed', ['host' => $dbHost]);
```

<br>

### 11-3. メトリクス

| メトリクス | 収集方法 | 確認先 |
|---|---|---|
| リクエスト数 | Cloud Run 自動 | Monitoring → Cloud Run |
| レイテンシ | Cloud Run 自動 | Monitoring → Cloud Run |
| インスタンス数 | Cloud Run 自動 | Monitoring → Cloud Run |
| CPU / メモリ使用率 | Cloud Run 自動 | Monitoring → Cloud Run |
| コンテナ起動時間 | Cloud Run 自動 | Monitoring → Cloud Run |
| Cloud SQL メトリクス | 自動（マネージド） | Monitoring → Cloud SQL |

<br>

### 11-4. アラート推奨設定

| アラート | 条件 | 重要度 |
|---|---|---|
| エラー率 | 5xx レスポンス > 5%（5分間） | Critical |
| レイテンシ | p99 > 5秒（5分間） | Warning |
| インスタンス数 | 最大インスタンス数の80%到達 | Warning |
| Cloud SQL CPU | > 80%（5分間） | Warning |
| Cloud SQL 接続数 | > 最大接続数の80% | Warning |

<br>

---

<br>

## 12. セキュリティ

<br>

### 12-1. GCE構成との比較

| 対策 | GCE構成 | Cloud Run構成 |
|---|---|---|
| OS パッチ | 手動 or 自動アップデート設定 | **不要**（マネージド） |
| SSH | IAP経由 | **不可**（コンテナは一時的） |
| ファイアウォール | VPC ルール管理 | Cloud Run Ingress 設定 |
| WAF | Cloud Armor（LB経由） | Cloud Armor（LB経由）同じ |
| Secret管理 | Secret Manager + gcloud | Secret Manager + 環境変数マウント |
| サービスアカウント | GCE用SA | Cloud Run用SA |
| ネットワーク分離 | VPC + Private IP | VPC + Direct VPC Egress + Private IP |

<br>

### 12-2. Cloud Run サービスアカウント

| 項目 | 値 |
|---|---|
| 名前 | `{prefix}-run-sa` |
| 付与ロール | `roles/cloudsql.client`（Cloud SQL接続用） |
| 付与ロール | `roles/secretmanager.secretAccessor`（Secret Manager読み取り用） |
| 付与ロール | `roles/logging.logWriter`（ログ書き込み用） |
| 付与ロール | `roles/monitoring.metricWriter`（メトリクス書き込み用） |
| 付与ロール | `roles/artifactregistry.reader`（イメージ pull 用） |

<br>

### 12-3. Docker イメージセキュリティ

| 対策 | 実装 |
|---|---|
| ベースイメージ | Alpine ベース（最小攻撃面） |
| マルチステージビルド | ビルドツールを本番イメージに含めない |
| 非rootユーザー | `www-data` で実行 |
| 脆弱性スキャン | Artifact Registry の自動スキャン有効化 |
| `.dockerignore` | `.env`, `.git`, `tests/` 等を除外 |

<br>

---

<br>

## 13. 環境分離設計

<br>

### 13-1. 環境別スペック一覧

| 設定 | dev | prod |
|---|---|---|
| リソース名プレフィックス | `myapp-dev-*` | `myapp-prod-*` |
| サブネットCIDR | 10.0.0.0/24 | 10.10.0.0/24 |
| Cloud Run 最小インスタンス | 0 | 1 |
| Cloud Run 最大インスタンス | 5 | 20 |
| Cloud Run CPU | 1 vCPU | 2 vCPU |
| Cloud Run メモリ | 512Mi | 1Gi |
| Cloud SQL マシンタイプ | db-f1-micro | db-g1-small |
| Cloud SQL HA | 無効 | 有効 |
| Cloud SQL 削除保護 | 無効 | 有効 |
| バックアップ保持 | 7日 | 30日 |
| レート制限 | 100 req/min | 200 req/min |

<br>

### 13-2. 月額コスト比較

| リソース | dev | prod |
|---|---|---|
| Cloud Run | ~$5 (最小0, 低トラフィック) | ~$30 (最小1, 中トラフィック) |
| Cloud SQL | ~$10 (micro, HA無) | ~$50 (small, HA有) |
| External LB | ~$20 | ~$20 |
| Cloud Armor | ~$5 | ~$5 |
| Artifact Registry | ~$1 | ~$1 |
| ストレージ | ~$1 | ~$5 |
| **合計** | **~$42/月** | **~$111/月** |

<br>

---

<br>

## 14. Terraform 構成

<br>

### 14-1. ディレクトリ構成

```
terraform/
├── bootstrap/                        # tfstate用GCSバケット（初回のみ）
│
├── modules/
│   ├── network/                      # VPC, サブネット, Private Services Access
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── database/                     # Cloud SQL, Secret Manager
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── registry/                     # Artifact Registry
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── application/                  # Cloud Run サービス（マルチコンテナ）
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── loadbalancer/                 # External ALB + Serverless NEG
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── security/                     # Cloud Armor
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
│
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   └── outputs.tf
│   └── prod/
│       ├── main.tf
│       ├── variables.tf
│       ├── terraform.tfvars
│       └── outputs.tf
│
├── docker/                            # Docker 構成
│   ├── nginx/
│   │   ├── Dockerfile
│   │   ├── nginx.conf
│   │   └── conf.d/default.conf
│   ├── php-fpm/
│   │   ├── Dockerfile
│   │   ├── php.ini
│   │   └── www.conf
│   ├── docker-compose.yml
│   └── .dockerignore
│
├── app/                               # PHPアプリケーション
│   ├── public/
│   │   └── index.php
│   ├── src/
│   │   ├── Kernel.php
│   │   ├── Shared/
│   │   ├── Spot/
│   │   ├── Review/
│   │   └── Admin/
│   ├── config/
│   ├── tests/
│   ├── composer.json
│   └── composer.lock
│
├── cloudbuild.yaml                    # CI/CDパイプライン
├── scripts/
│   └── setup.sh                       # 統合セットアップスクリプト
├── .env.example
└── README.md
```

<br>

### 14-2. GCE構成との差分

| GCE構成 | Cloud Run構成 | 変更理由 |
|---|---|---|
| `modules/application/`（GCE + LB + IG） | `modules/application/`（Cloud Run）+ `modules/loadbalancer/`（ALB + NEG） | Cloud Run とLBの責務を分離 |
| — | `modules/registry/` 追加 | Artifact Registry が必要 |
| `ansible/` ディレクトリ | 削除 | Docker で構成管理（Ansible不要） |
| — | `docker/` ディレクトリ追加 | Docker ビルド構成 |
| — | `app/` ディレクトリ追加 | PHPアプリ（モジュラーモノリス） |
| — | `cloudbuild.yaml` 追加 | CI/CDパイプライン |

<br>

### 14-3. 主要 Terraform リソース

#### modules/application（Cloud Run）

| リソース | 説明 |
|---|---|
| `google_service_account` | Cloud Run 用サービスアカウント |
| `google_project_iam_member` | SA へのロール付与 |
| `google_cloud_run_v2_service` | Cloud Run サービス（マルチコンテナ定義） |

#### modules/loadbalancer（ALB + Serverless NEG）

| リソース | 説明 |
|---|---|
| `google_compute_global_address` | LB用外部IP |
| `google_compute_region_network_endpoint_group` | Serverless NEG（Cloud Run） |
| `google_compute_backend_service` | バックエンドサービス（Serverless NEG紐付け） |
| `google_compute_url_map` | URLルーティング |
| `google_compute_target_https_proxy` | HTTPS Proxy |
| `google_compute_global_forwarding_rule` | フォワーディングルール |
| `google_compute_managed_ssl_certificate` | SSL証明書（ドメインあり時） |

#### modules/registry（Artifact Registry）

| リソース | 説明 |
|---|---|
| `google_artifact_registry_repository` | Docker イメージリポジトリ |

<br>

### 14-4. Cloud Run Terraform定義（イメージ）

```hcl
resource "google_cloud_run_v2_service" "app" {
  name     = "${var.prefix}-app"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.run_sa.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      network_interfaces {
        network    = var.vpc_id
        subnetwork = var.subnet_id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    volumes {
      name = "app-files"
      empty_dir {
        medium     = "MEMORY"
        size_limit = "100Mi"
      }
    }

    # Ingress コンテナ（Nginx）
    containers {
      name  = "nginx"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo}/nginx:${var.image_tag}"

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "0.5"
          memory = "256Mi"
        }
      }

      volume_mounts {
        name       = "app-files"
        mount_path = "/var/www/html/public"
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 3
        period_seconds        = 5
      }

      depends_on = ["php-fpm"]
    }

    # サイドカー コンテナ（PHP-FPM）
    containers {
      name  = "php-fpm"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo}/php-fpm:${var.image_tag}"

      resources {
        limits = {
          cpu    = var.php_cpu
          memory = var.php_memory
        }
      }

      env {
        name  = "APP_ENV"
        value = var.env
      }

      env {
        name  = "DB_HOST"
        value = var.db_private_ip
      }

      env {
        name  = "DB_PORT"
        value = "3306"
      }

      env {
        name  = "DB_NAME"
        value = var.db_name
      }

      env {
        name  = "DB_USER"
        value = var.db_user
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = var.db_secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "app-files"
        mount_path = "/var/www/html/public"
      }

      startup_probe {
        tcp_socket {
          port = 9000
        }
        initial_delay_seconds = 2
        period_seconds        = 5
      }
    }
  }
}
```

<br>

---

<br>

## 15. 有効化するGCP API

| API | 用途 |
|---|---|
| `run.googleapis.com` | Cloud Run |
| `artifactregistry.googleapis.com` | Artifact Registry |
| `cloudbuild.googleapis.com` | Cloud Build |
| `sqladmin.googleapis.com` | Cloud SQL Admin |
| `servicenetworking.googleapis.com` | Service Networking |
| `secretmanager.googleapis.com` | Secret Manager |
| `compute.googleapis.com` | Compute Engine（VPC, LB用） |
| `vpcaccess.googleapis.com` | Serverless VPC Access（使用時） |
| `logging.googleapis.com` | Cloud Logging |
| `monitoring.googleapis.com` | Cloud Monitoring |

<br>

---

<br>

## 16. 構築の流れ

```
[Step 1] ローカル開発環境セットアップ
    │    docker compose up → Nginx + PHP-FPM + MySQL
    │    http://localhost:8080 で動作確認
    │
    ▼
[Step 2] GCSバックエンド作成（初回のみ）
    │    cd terraform/bootstrap
    │    terraform init && terraform apply
    │
    ▼
[Step 3] dev環境インフラ構築
    │    cd terraform/environments/dev
    │    terraform init && terraform plan && terraform apply
    │    ⏱ ~10分（Cloud SQL作成が遅い）
    │
    ▼
[Step 4] Docker イメージビルド & push
    │    docker build → Artifact Registry に push
    │    （または Cloud Build トリガーで自動）
    │
    ▼
[Step 5] Cloud Run デプロイ
    │    gcloud run services replace service.yaml
    │    （Terraform で初回作成後、CI/CDで更新）
    │
    ▼
[Step 6] 動作確認
    │    ├─ LBのIPでブラウザアクセス
    │    ├─ Cloud Logging でログ確認
    │    └─ Cloud Monitoring でメトリクス確認
    │
    ▼
[Step 7] CI/CD設定
    │    Cloud Build トリガー設定 → git push でデプロイ自動化
    │
    ▼
[Step 8] prod環境にも適用
         terraform apply (prod) → イメージ push → デプロイ
```

<br>

---

<br>

## 17. 命名規則

| リソース種別 | 命名パターン | dev例 | prod例 |
|---|---|---|---|
| VPC | `{prefix}-vpc` | `myapp-dev-vpc` | `myapp-prod-vpc` |
| サブネット | `{prefix}-subnet` | `myapp-dev-subnet` | `myapp-prod-subnet` |
| Cloud SQL | `{prefix}-db` | `myapp-dev-db` | `myapp-prod-db` |
| Cloud Run | `{prefix}-app` | `myapp-dev-app` | `myapp-prod-app` |
| Serverless NEG | `{prefix}-neg` | `myapp-dev-neg` | `myapp-prod-neg` |
| LB IP | `{prefix}-lb-ip` | `myapp-dev-lb-ip` | `myapp-prod-lb-ip` |
| Cloud Armor | `{prefix}-armor-policy` | `myapp-dev-armor-policy` | `myapp-prod-armor-policy` |
| Artifact Registry | `{prefix}-docker` | `myapp-dev-docker` | `myapp-prod-docker` |
| サービスアカウント | `{prefix}-run-sa` | `myapp-dev-run-sa` | `myapp-prod-run-sa` |
| Secret Manager | `{prefix}-db-password` | `myapp-dev-db-password` | `myapp-prod-db-password` |
| Docker イメージ | `{region}-docker.pkg.dev/{project}/{repo}/{name}:{tag}` | — | — |

<br>

---

<br>

## 18. GCE構成からの移行ポイント

既存のGCE構成からCloud Run構成に移行する場合の主な作業:

| 項目 | 作業内容 |
|---|---|
| **Dockerfile作成** | Nginx / PHP-FPM の Docker化 |
| **PHPアプリの調整** | ファイルアップロード → GCS、セッション → Redis or DB |
| **DB接続変更** | Auth Proxy → Direct VPC Egress (Private IP直接) |
| **Secret Manager** | gcloud コマンド取得 → 環境変数マウントに変更 |
| **ログ出力** | ファイル出力 → stdout/stderr (JSON推奨) |
| **Ansible廃止** | Docker + CI/CD に置き換え |
| **Terraform変更** | GCEモジュール → Cloud Run モジュール |
| **CI/CD構築** | Cloud Build or GitHub Actions |
| **DNS切り替え** | LB IP変更 → DNS更新 |

> **推奨移行順序:** ローカル Docker 化 → dev 環境 Cloud Run → 動作確認 → prod 移行 → GCE 廃止
