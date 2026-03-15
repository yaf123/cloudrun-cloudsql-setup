<?php

declare(strict_types=1);

namespace App\Shared\Config;

/**
 * 環境変数ベースの設定管理
 *
 * ローカル: docker-compose.yml の environment で注入
 * Cloud Run: Cloud Run の環境変数 + Secret Manager で注入
 */
class Config
{
    private static ?self $instance = null;

    public readonly string $appEnv;
    public readonly string $dbHost;
    public readonly int    $dbPort;
    public readonly string $dbName;
    public readonly string $dbUser;
    public readonly string $dbPassword;

    private function __construct()
    {
        $this->appEnv     = $this->env('APP_ENV', 'local');
        $this->dbHost     = $this->env('DB_HOST', '127.0.0.1');
        $this->dbPort     = (int) $this->env('DB_PORT', '3306');
        $this->dbName     = $this->env('DB_NAME', 'myapp');
        $this->dbUser     = $this->env('DB_USER', 'myapp-user');
        $this->dbPassword = $this->env('DB_PASSWORD', '');
    }

    public static function get(): self
    {
        if (self::$instance === null) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    public function isLocal(): bool
    {
        return $this->appEnv === 'local';
    }

    public function isProduction(): bool
    {
        return $this->appEnv === 'prod';
    }

    private function env(string $key, string $default = ''): string
    {
        $value = getenv($key);
        return $value !== false ? $value : $default;
    }
}
