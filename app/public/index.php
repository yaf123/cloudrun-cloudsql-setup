<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

use App\Shared\Config\Config;
use App\Shared\Database\Connection;

$config = Config::get();
$dbStatus = Connection::check();

// メモ帳デモ: 追加・削除処理
$flashMessage = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    try {
        $pdo = Connection::get();
        $action = $_POST['action'] ?? '';

        if ($action === 'add' && !empty($_POST['content'])) {
            $stmt = $pdo->prepare('INSERT INTO notes (content) VALUES (?)');
            $stmt->execute([$_POST['content']]);
            $flashMessage = 'メモを追加しました';
        } elseif ($action === 'delete' && !empty($_POST['id'])) {
            $stmt = $pdo->prepare('DELETE FROM notes WHERE id = ?');
            $stmt->execute([(int)$_POST['id']]);
            $flashMessage = 'メモを削除しました';
        }
    } catch (Throwable $e) {
        $flashMessage = 'エラー: ' . htmlspecialchars($e->getMessage());
    }

    // PRG パターン（POST後リダイレクトでリロード時の再送信を防止）
    header('Location: /?msg=' . urlencode($flashMessage));
    exit;
}

$flashMessage = $_GET['msg'] ?? '';

// メモ一覧取得
$notes = [];
if ($dbStatus['ok']) {
    try {
        $pdo = Connection::get();
        $notes = $pdo->query('SELECT * FROM notes ORDER BY created_at DESC LIMIT 50')->fetchAll();
    } catch (Throwable $e) {
        // notes テーブルが未作成の場合は空
    }
}

?>
<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MyApp - Cloud Run Demo</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f5; color: #333; padding: 2rem; max-width: 800px; margin: 0 auto; }
        h1 { margin-bottom: 1.5rem; color: #1a73e8; }
        h2 { margin: 1.5rem 0 1rem; color: #555; font-size: 1.1rem; }
        .card { background: #fff; border-radius: 8px; padding: 1.5rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; }
        th, td { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 1px solid #eee; }
        th { color: #888; font-weight: 500; font-size: 0.85rem; }
        .ok { color: #34a853; font-weight: bold; }
        .ng { color: #ea4335; font-weight: bold; }
        .flash { background: #e8f5e9; border: 1px solid #a5d6a7; border-radius: 4px; padding: 0.75rem; margin-bottom: 1rem; }
        .flash.error { background: #fce4ec; border-color: #ef9a9a; }
        form.add-form { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
        form.add-form input[type="text"] { flex: 1; padding: 0.5rem; border: 1px solid #ddd; border-radius: 4px; font-size: 1rem; }
        button { padding: 0.5rem 1rem; border: none; border-radius: 4px; cursor: pointer; font-size: 0.9rem; }
        button.primary { background: #1a73e8; color: #fff; }
        button.danger { background: #ea4335; color: #fff; font-size: 0.8rem; padding: 0.3rem 0.6rem; }
        .note-item { display: flex; justify-content: space-between; align-items: center; padding: 0.5rem 0; border-bottom: 1px solid #eee; }
        .note-item:last-child { border-bottom: none; }
        .note-time { color: #999; font-size: 0.8rem; }
    </style>
</head>
<body>
    <h1>MyApp - Cloud Run Demo</h1>

    <!-- サーバー情報 -->
    <div class="card">
        <h2>Server Info</h2>
        <table>
            <tr><th>Environment</th><td><?= htmlspecialchars($config->appEnv) ?></td></tr>
            <tr><th>PHP Version</th><td><?= phpversion() ?></td></tr>
            <tr><th>Server</th><td><?= htmlspecialchars($_SERVER['SERVER_SOFTWARE'] ?? 'N/A') ?></td></tr>
            <tr><th>Hostname</th><td><?= htmlspecialchars(gethostname() ?: 'N/A') ?></td></tr>
            <tr><th>OPcache</th><td><?= function_exists('opcache_get_status') && opcache_get_status() ? '<span class="ok">Enabled</span>' : 'Disabled' ?></td></tr>
        </table>
    </div>

    <!-- DB接続ステータス -->
    <div class="card">
        <h2>Database</h2>
        <table>
            <tr><th>Status</th><td><?= $dbStatus['ok'] ? '<span class="ok">Connected</span>' : '<span class="ng">Disconnected</span>' ?></td></tr>
            <tr><th>Host</th><td><?= htmlspecialchars($config->dbHost) ?>:<?= $config->dbPort ?></td></tr>
            <tr><th>Database</th><td><?= htmlspecialchars($config->dbName) ?></td></tr>
            <?php if ($dbStatus['ok']): ?>
            <tr><th>MySQL Version</th><td><?= htmlspecialchars($dbStatus['version']) ?></td></tr>
            <?php else: ?>
            <tr><th>Error</th><td class="ng"><?= htmlspecialchars($dbStatus['error'] ?? 'Unknown') ?></td></tr>
            <?php endif; ?>
        </table>
    </div>

    <!-- メモ帳（CRUD デモ） -->
    <div class="card">
        <h2>Notes (CRUD Demo)</h2>

        <?php if ($flashMessage): ?>
            <div class="flash <?= str_starts_with($flashMessage, 'エラー') ? 'error' : '' ?>">
                <?= htmlspecialchars($flashMessage) ?>
            </div>
        <?php endif; ?>

        <?php if ($dbStatus['ok']): ?>
            <form method="POST" class="add-form">
                <input type="hidden" name="action" value="add">
                <input type="text" name="content" placeholder="メモを入力..." required>
                <button type="submit" class="primary">追加</button>
            </form>

            <?php if (empty($notes)): ?>
                <p style="color: #999; padding: 1rem 0;">メモはまだありません</p>
            <?php else: ?>
                <?php foreach ($notes as $note): ?>
                    <div class="note-item">
                        <div>
                            <?= htmlspecialchars($note['content']) ?>
                            <div class="note-time"><?= htmlspecialchars($note['created_at']) ?></div>
                        </div>
                        <form method="POST" style="display:inline" onsubmit="return confirm('削除しますか？')">
                            <input type="hidden" name="action" value="delete">
                            <input type="hidden" name="id" value="<?= (int)$note['id'] ?>">
                            <button type="submit" class="danger">削除</button>
                        </form>
                    </div>
                <?php endforeach; ?>
            <?php endif; ?>
        <?php else: ?>
            <p class="ng">DB未接続のためメモ機能は利用できません</p>
        <?php endif; ?>
    </div>
</body>
</html>
