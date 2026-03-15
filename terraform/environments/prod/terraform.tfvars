# 環境固有の設定（共通値は .env → TF_VAR_ で注入）
env = "prod"

# prod環境: HAあり、スケール拡大
db_tier          = "db-g1-small"
ha_enabled       = true
min_instances    = 1
max_instances    = 20
rate_limit_count = 200
