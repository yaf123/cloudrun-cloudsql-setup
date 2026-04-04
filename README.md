# Cloud Run + Cloud SQL 堅牢構成

GCP 上に **Cloud Run（マルチコンテナ）+ Cloud SQL（MySQL 8.0）** の堅牢な Web 環境を構築するための Terraform + Docker 構成です。

## 構成図

```
                          Internet
                             │
                    ┌────────▼────────┐
                    │   Cloud Armor   │
                    │  (WAF / DDoS)   │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  External ALB   │
                    │  (HTTPS / L7)   │
                    └────────┬────────┘
                             │
                      Serverless NEG
                             │
 ┌───────────────────────────┼────────────────────────────┐
 │  VPC                      │                             │
 │       ┌───────────────────▼──────────────────────┐      │
 │       │  Cloud Run (Multi-Container / Sidecar)    │      │
 │       │  ┌──────────────┐  ┌──────────────┐      │      │
 │       │  │  Nginx       │  │  PHP-FPM     │      │      │
 │       │  │  :8080       │─▶│  :9000       │      │      │
 │       │  │  静的配信     │  │  PHPアプリ    │      │      │
 │       │  └──────────────┘  └──────┬───────┘      │      │
 │       └───────────────────────────│──────────────┘      │
 │                                   │ Direct VPC Egress   │
 │                          ┌────────▼────────┐            │
 │                          │  Cloud SQL      │            │
 │                          │  MySQL 8.0      │            │
 │                          │  Private IPのみ  │            │
 │                          └─────────────────┘            │
 └─────────────────────────────────────────────────────────┘
```

## 特徴

- **マルチコンテナ**: Nginx（静的配信）+ PHP-FPM（アプリ処理）をサイドカー構成
- **同一 Dockerfile**: ローカル開発と Cloud Run で同じ Dockerfile を使用
- **無停止デプロイ**: Cloud Run のローリングデプロイで自動的にダウンタイムゼロ
- **自動スケーリング**: 0〜N インスタンスまでリクエストベースで自動スケール
- **OS 管理不要**: サーバーレスのため、セキュリティパッチ等のメンテナンス不要
- **Secret Manager**: DB パスワードをコードに含めず、環境変数として自動マウント
- **Cloud Armor**: SQLi / XSS / レート制限による WAF 保護
- **環境分離**: dev / prod を同一コードで管理（変数で切り替え）
- **CI/CD**: GitHub Actions で git push → 自動デプロイ（Workload Identity Federation 認証）

## ディレクトリ構成

```
.
├── README.md
├── .github/
│   └── workflows/
│       └── deploy-cloudrun.yml        ← CI/CD パイプライン（GitHub Actions）
│
├── app/                               ← PHP アプリケーション
│   ├── composer.json
│   ├── public/
│   │   └── index.php                  ←   デモアプリ（サーバー情報 + DB接続 + メモ帳CRUD）
│   └── src/Shared/
│       ├── Config/Config.php          ←   環境変数ベースの設定管理
│       └── Database/Connection.php    ←   PDO 接続管理
│
├── docker/                            ← Docker 構成
│   ├── .dockerignore
│   ├── .env.example                   ←   ローカル開発用環境変数テンプレート
│   ├── docker-compose.yml             ←   ローカル開発用（MySQL + phpMyAdmin 付き）
│   ├── nginx/
│   │   ├── Dockerfile                 ←   ローカル / Cloud Run 共用
│   │   ├── nginx.conf
│   │   └── conf.d/
│   │       └── default.conf.template  ←   envsubst で PHP_FPM_HOST を展開
│   └── php-fpm/
│       ├── Dockerfile                 ←   ローカル / Cloud Run 共用（3ステージビルド）
│       ├── php.ini                    ←   本番設定
│       ├── php.local.ini              ←   ローカル用オーバーライド（ホットリロード有効化）
│       └── www.conf                   ←   FPM ワーカー設定
│
├── db/                                ← DB 初期化
│   ├── init/
│   │   └── 001_create_tables.sql      ←   テーブル作成 + サンプルデータ
│   └── my.cnf                         ←   MySQL 文字コード設定
│
└── terraform/                         ← インフラ（Terraform）
    ├── .env.example                   ←   Terraform + Docker 共通の環境変数テンプレート
    ├── bootstrap/                     ←   tfstate 用 GCS バケット（初回のみ）
    ├── modules/
    │   ├── network/                   ←   VPC, サブネット, Private Services Access
    │   ├── database/                  ←   Cloud SQL, Secret Manager
    │   ├── registry/                  ←   Artifact Registry
    │   ├── application/               ←   Cloud Run サービス（マルチコンテナ定義）
    │   ├── loadbalancer/              ←   External ALB + Serverless NEG
    │   ├── security/                  ←   Cloud Armor
    │   └── cicd/                      ←   GitHub Actions 用 Workload Identity Federation
    ├── environments/
    │   ├── dev/                       ←   開発環境（min=0, micro, HA無）
    │   └── prod/                      ←   本番環境（min=1, small, HA有）
    └── scripts/
        └── setup.sh                   ←   Terraform + Docker 統合スクリプト
```

## 前提条件

- GCP プロジェクト（Owner 権限）
- ローカル環境に以下がインストール済み:
  - [Docker Engine](https://docs.docker.com/engine/install/) + Docker Compose
  - [gcloud CLI](https://cloud.google.com/sdk/docs/install)
  - [Terraform](https://developer.hashicorp.com/terraform/install)

## クイックスタート

### 1. ローカル開発環境

Docker さえあれば、GCP プロジェクトなしですぐに動かせます。

```bash
# 環境変数の設定
cd docker/
cp .env.example .env
vi .env                  # DB パスワード等を記入

# 起動
sudo docker compose up -d

# アクセス
#   http://localhost:8080       → デモアプリ
#   http://localhost:13306      → MySQL（外部ツールから接続）

# phpMyAdmin 付きで起動
sudo docker compose --profile tools up -d
#   http://localhost:8081       → phpMyAdmin

# ログ確認
sudo docker compose logs -f

# 停止
sudo docker compose down

# 停止 + データ初期化
sudo docker compose down -v
```

#### ホットリロード

PHP ファイルを保存 → ブラウザリロードで即反映されます。

```
ホストで app/public/index.php を編集
  ↓ bind mount（自動同期）
PHP-FPM コンテナ内で即反映
  ↓ OPcache validate_timestamps=1（ローカル用設定）
ブラウザリロードで確認
```

### 2. GCP 環境構築

#### 2-1. 認証

```bash
gcloud auth login
gcloud auth application-default login
```

#### 2-2. 環境変数の設定

```bash
cd terraform/
cp .env.example .env
vi .env                  # GCP プロジェクト ID、DB パスワード等を記入
```

`.env` に記入する主な値:

| 変数 | 説明 | 例 |
|---|---|---|
| `GCP_PROJECT_ID` | GCP プロジェクト ID | `my-project-123456` |
| `PROJECT_NAME` | リソース名プレフィックス | `myapp` |
| `DB_PASSWORD` | DB パスワード | （強力なパスワード） |
| `DOMAIN` | ドメイン（空なら HTTP のみ） | `example.com` |

#### 2-3. インフラ構築

```bash
# 設定値を確認
./scripts/setup.sh info

# GCS バケット作成（チーム開発時、初回のみ）
./scripts/setup.sh bootstrap

# dev 環境のインフラ構築
./scripts/setup.sh plan dev          # 実行計画確認
./scripts/setup.sh apply dev         # 確認プロンプトで yes を入力
# ⏱ 約 10〜15 分（Cloud SQL 作成に時間がかかる）
```

#### 2-4. Docker イメージのビルド & デプロイ

```bash
# ビルド → Artifact Registry に push → Cloud Run 更新
./scripts/setup.sh deploy dev
```

#### 2-5. 動作確認

```bash
# LB の外部 IP を確認
cd terraform/environments/dev && terraform output

# ブラウザで http://<LB の IP> にアクセス
```

#### 2-6. リソース削除

```bash
./scripts/setup.sh destroy dev
```

## 同一 Dockerfile 戦略

ローカル開発と Cloud Run で **同じ Dockerfile** を使用し、`docker-compose.yml` がローカル固有のオーバーライドを担当します。

```
                    Dockerfile（1つ）
                    ├── nginx/Dockerfile
                    └── php-fpm/Dockerfile
                          │
          ┌───────────────┼───────────────┐
          │                               │
    ローカル開発                      Cloud Run
    docker-compose.yml              gcloud run deploy
          │                               │
    オーバーライド:                    そのまま使用:
    ├ bind mount (ホットリロード)      ├ イメージ内コード
    ├ php.local.ini (OPcache=1)       ├ OPcache validate=0
    ├ MySQL コンテナ                  ├ Cloud SQL
    ├ PHP_FPM_HOST=php-fpm           └ PHP_FPM_HOST=127.0.0.1
    └ 環境変数 (ローカル値)
```

環境差は **3 箇所だけ**:

| 差分 | ローカル | Cloud Run |
|---|---|---|
| PHP-FPM 接続先 | `PHP_FPM_HOST=php-fpm` | `PHP_FPM_HOST=127.0.0.1` |
| DB 接続先 | `DB_HOST=mysql`（コンテナ） | `DB_HOST=10.x.x.x`（Cloud SQL） |
| PHP ソース | bind mount（ホットリロード） | イメージ内（不変） |

## CI/CD パイプライン

### 自動デプロイ（GitHub Actions + Workload Identity Federation）

```
git push (main)
  │
  ▼
GitHub Actions（自動実行）
  ├─ GCP認証（Workload Identity Federation、SAキー不要）
  ├─ Docker イメージビルド（nginx + php-fpm 並列）
  ├─ Artifact Registry に push
  └─ Cloud Run デプロイ（replace 方式）
       └─ describe → Python(YAML加工) → replace
          ※ ボリューム定義は Python で除去（Terraform 管理のため）
```

### 手動デプロイ

```bash
# ビルド → push → Cloud Run 更新を一括実行
./scripts/setup.sh deploy dev

# 個別実行
./scripts/setup.sh docker-build         # ビルドのみ
./scripts/setup.sh docker-push dev      # push のみ
```

### GitHub Actions セットアップ

1. `terraform/.env` に以下を設定:
   ```
   GITHUB_OWNER=your-github-username
   GITHUB_REPO_NAME=your-repo-name
   ```
2. `./scripts/setup.sh apply dev` で Workload Identity Federation が自動作成される
3. GitHub リポジトリの Settings → Secrets and variables → Actions に以下を設定:

   | Secret 名 | 値 | 説明 |
   |---|---|---|
   | `GCP_PROJECT_ID` | GCP プロジェクト ID | |
   | `WIF_PROVIDER` | WIF Provider フルパス | `terraform output` で確認 |
   | `WIF_SERVICE_ACCOUNT` | デプロイ用 SA メール | `terraform output` で確認 |

### ローリングデプロイ（無停止）

Cloud Run は新リビジョンの準備完了を確認してからトラフィックを切り替えるため、**デプロイ中のダウンタイムはゼロ**です。

```
1. 新リビジョン作成（裏で起動）
2. startup probe 通過を確認
3. トラフィックを新リビジョンに切り替え
4. 旧リビジョンは処理中のリクエスト完了後に終了
```

ロールバックもワンコマンドで即時:

```bash
gcloud run services update-traffic myapp-dev-app \
  --to-revisions=PREVIOUS_REVISION=100 \
  --region=asia-northeast1
```

## 環境別スペック

| 設定 | dev | prod |
|---|---|---|
| Cloud Run 最小インスタンス | 0 | 1 |
| Cloud Run 最大インスタンス | 5 | 20 |
| Cloud SQL マシンタイプ | db-f1-micro | db-g1-small |
| Cloud SQL HA | 無効 | 有効 |
| バックアップ保持 | 7 日 | 30 日 |
| レート制限 | 100 req/min | 200 req/min |

## 月額コスト目安

| リソース | dev | prod |
|---|---|---|
| Cloud Run | ~$5 | ~$30 |
| Cloud SQL | ~$10 | ~$50 |
| External LB | ~$20 | ~$20 |
| Cloud Armor | ~$5 | ~$5 |
| Artifact Registry | ~$1 | ~$1 |
| **合計** | **~$42/月** | **~$111/月** |

## setup.sh コマンド一覧

```bash
./scripts/setup.sh info                # 設定値を確認
./scripts/setup.sh bootstrap           # GCS バケット作成（初回のみ）
./scripts/setup.sh plan dev            # Terraform plan
./scripts/setup.sh apply dev           # Terraform apply
./scripts/setup.sh destroy dev         # Terraform destroy
./scripts/setup.sh docker-build        # Docker イメージビルド
./scripts/setup.sh docker-push dev     # Artifact Registry に push
./scripts/setup.sh deploy dev          # ビルド → push → Cloud Run 更新
```

## WSL2 環境の注意事項

| 問題 | 対策 |
|---|---|
| ポート 3306 が使用中 | docker-compose.yml で `13306:3306` に変更済み |
| `my.cnf` マウントが無視される | MySQL `command` オプションで文字コード設定 |
| bind mount パフォーマンス | Linux FS 側にソース配置を推奨 |
| OPcache でホットリロードが効かない | `php.local.ini` を docker-compose でマウントオーバーライド |
