# 環境固有の設定（共通値は .env → TF_VAR_ で注入）
env = "dev"

# dev環境: 最小スペック、HA無効、スケール抑制
db_tier       = "db-f1-micro"
ha_enabled    = false
min_instances = 0
max_instances = 5
