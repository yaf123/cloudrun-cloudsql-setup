#!/bin/bash
set -e

# =============================================================================
# Cloud Run + Cloud SQL セットアップスクリプト
# .env を読み込んで Terraform / Docker を実行する
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$ROOT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

# .env チェック
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env ファイルが見つかりません"
  echo "  cp .env.example .env"
  echo "  vi .env"
  exit 1
fi

# .env 読み込み
set -a
source "$ENV_FILE"
set +a

# Terraform 用の TF_VAR_ 環境変数をエクスポート
export TF_VAR_project_id="$GCP_PROJECT_ID"
export TF_VAR_project_name="$PROJECT_NAME"
export TF_VAR_region="$GCP_REGION"
export TF_VAR_domain="${DOMAIN:-}"
export TF_VAR_bucket_name="$TFSTATE_BUCKET"
export TF_VAR_db_name="$DB_NAME"
export TF_VAR_db_user="$DB_USER"
export TF_VAR_db_password="${DB_PASSWORD:-}"
export TF_VAR_image_tag="${IMAGE_TAG:-latest}"
export TF_VAR_github_owner="${GITHUB_OWNER:-}"
export TF_VAR_github_repo_name="${GITHUB_REPO_NAME:-}"

# Artifact Registry URL
REPO_URL="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${PROJECT_NAME}"

# 使用方法
usage() {
  echo "Usage: $0 <command> [environment]"
  echo ""
  echo "Commands:"
  echo "  info                  現在の設定値を表示"
  echo "  bootstrap             GCSバケット作成（初回のみ）"
  echo "  plan    <dev|prod>    Terraform plan"
  echo "  apply   <dev|prod>    Terraform apply"
  echo "  destroy <dev|prod>    Terraform destroy"
  echo "  docker-build          Dockerイメージをビルド"
  echo "  docker-push <dev|prod> イメージをArtifact Registryにpush"
  echo "  deploy  <dev|prod>    docker-build + docker-push + Cloud Run更新"
  echo ""
  echo "Examples:"
  echo "  $0 info                # 設定確認"
  echo "  $0 bootstrap           # GCSバケット作成"
  echo "  $0 plan dev            # dev環境の実行計画"
  echo "  $0 apply dev           # dev環境にインフラ構築"
  echo "  $0 docker-build        # Dockerイメージビルド"
  echo "  $0 docker-push dev     # dev環境のRegistryにpush"
  echo "  $0 deploy dev          # ビルド→push→Cloud Run更新"
}

# 設定値表示
cmd_info() {
  echo "=== 現在の設定値 ==="
  echo "GCP_PROJECT_ID : $GCP_PROJECT_ID"
  echo "PROJECT_NAME   : $PROJECT_NAME"
  echo "GCP_REGION     : $GCP_REGION"
  echo "DOMAIN         : ${DOMAIN:-(未設定)}"
  echo "TFSTATE_BUCKET : $TFSTATE_BUCKET"
  echo "DB_NAME        : $DB_NAME"
  echo "DB_USER        : $DB_USER"
  echo "DB_PASSWORD    : ${DB_PASSWORD:+(設定済み)}"
  echo "IMAGE_TAG      : ${IMAGE_TAG:-latest}"
}

# bootstrap
cmd_bootstrap() {
  echo "=== GCSバケット作成 ==="
  cd "$ROOT_DIR/environments/../bootstrap" 2>/dev/null || cd "$ROOT_DIR/bootstrap"
  terraform init
  terraform apply
}

# Terraform plan/apply/destroy
cmd_terraform() {
  local action=$1
  local env=$2

  if [ -z "$env" ]; then
    echo "ERROR: 環境を指定してください (dev|prod)"
    exit 1
  fi

  cd "$ROOT_DIR/environments/$env"
  terraform init
  terraform "$action"
}

# Dockerイメージビルド
cmd_docker_build() {
  local tag="${IMAGE_TAG:-latest}"
  echo "=== Dockerイメージビルド (tag: $tag) ==="
  cd "$PROJECT_ROOT"

  docker build -t "nginx:${tag}" -f docker/nginx/Dockerfile .
  docker build -t "php-fpm:${tag}" -f docker/php-fpm/Dockerfile .

  echo ""
  echo "ビルド完了:"
  echo "  nginx:${tag}"
  echo "  php-fpm:${tag}"
}

# Artifact Registry に push
cmd_docker_push() {
  local env=$1
  local tag="${IMAGE_TAG:-latest}"
  local repo_url="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${PROJECT_NAME}-${env}-docker"

  if [ -z "$env" ]; then
    echo "ERROR: 環境を指定してください (dev|prod)"
    exit 1
  fi

  echo "=== Docker push (env: $env, tag: $tag) ==="

  # gcloud 認証
  gcloud auth configure-docker "${GCP_REGION}-docker.pkg.dev" --quiet

  # タグ付け & push
  docker tag "nginx:${tag}" "${repo_url}/nginx:${tag}"
  docker tag "php-fpm:${tag}" "${repo_url}/php-fpm:${tag}"
  docker push "${repo_url}/nginx:${tag}"
  docker push "${repo_url}/php-fpm:${tag}"

  echo ""
  echo "Push完了:"
  echo "  ${repo_url}/nginx:${tag}"
  echo "  ${repo_url}/php-fpm:${tag}"
}

# デプロイ（ビルド → push → Cloud Run更新）
cmd_deploy() {
  local env=$1

  if [ -z "$env" ]; then
    echo "ERROR: 環境を指定してください (dev|prod)"
    exit 1
  fi

  cmd_docker_build
  echo ""
  cmd_docker_push "$env"
  echo ""

  local service_name="${PROJECT_NAME}-${env}-app"
  echo "=== Cloud Run 更新 ==="
  gcloud run services update "$service_name" \
    --region="$GCP_REGION" \
    --image="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${PROJECT_NAME}-${env}-docker/nginx:${IMAGE_TAG:-latest}"

  echo ""
  echo "デプロイ完了: $service_name"
}

# メイン
case "${1:-}" in
  info)
    cmd_info
    ;;
  bootstrap)
    cmd_info
    echo ""
    cmd_bootstrap
    ;;
  plan)
    cmd_terraform plan "$2"
    ;;
  apply)
    cmd_terraform apply "$2"
    ;;
  destroy)
    cmd_terraform destroy "$2"
    ;;
  docker-build)
    cmd_docker_build
    ;;
  docker-push)
    cmd_docker_push "$2"
    ;;
  deploy)
    cmd_deploy "$2"
    ;;
  *)
    usage
    ;;
esac
