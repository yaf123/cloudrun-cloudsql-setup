SET NAMES utf8mb4;
SET CHARACTER SET utf8mb4;

-- デモ用テーブル
CREATE TABLE IF NOT EXISTS notes (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    content    TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- サンプルデータ
INSERT INTO notes (content) VALUES
    ('Cloud Run + Cloud SQL デモアプリです'),
    ('Nginx + PHP-FPM マルチコンテナ構成'),
    ('ローカルと本番で同じ Dockerfile を使用');
