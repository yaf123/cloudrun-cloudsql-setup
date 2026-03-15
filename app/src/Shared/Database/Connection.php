<?php

declare(strict_types=1);

namespace App\Shared\Database;

use App\Shared\Config\Config;
use PDO;
use PDOException;

/**
 * PDO ベースの DB接続管理
 *
 * シングルトンで接続を再利用（PHP-FPM の1リクエスト内）
 */
class Connection
{
    private static ?PDO $pdo = null;

    public static function get(): PDO
    {
        if (self::$pdo === null) {
            $config = Config::get();
            $dsn = sprintf(
                'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
                $config->dbHost,
                $config->dbPort,
                $config->dbName
            );

            self::$pdo = new PDO($dsn, $config->dbUser, $config->dbPassword, [
                PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES   => false,
            ]);
        }

        return self::$pdo;
    }

    /**
     * DB接続テスト（ヘルスチェック用）
     */
    public static function check(): array
    {
        try {
            $pdo = self::get();
            $version = $pdo->query('SELECT VERSION()')->fetchColumn();
            return ['ok' => true, 'version' => $version];
        } catch (PDOException $e) {
            return ['ok' => false, 'error' => $e->getMessage()];
        }
    }

    /**
     * リクエスト終了時に接続を解放（必要に応じて呼ぶ）
     */
    public static function close(): void
    {
        self::$pdo = null;
    }
}
