<?php
declare(strict_types=1);

$videoDir = rtrim((string)(getenv('VIDEO_DIR') ?: '/home/jcleng/Downloads/mv/upnp/'), '/');
$favDataDir = rtrim((string)(getenv('FAV_DATA_DIR') ?: __DIR__ . '/data'), '/'); // 收藏持久化(SleekDB 数据目录)

require __DIR__ . '/vendor/autoload.php';

$videoExts = [
    'mp4', 'm4v', 'webm', 'mkv', 'avi', 'mov', 'flv', 'wmv',
    'mpg', 'mpeg', 'ts', 'm2ts', 'ogv', '3gp', 'm3u8',
];
$subExts = ['srt', 'vtt', 'ass', 'ssa'];
$thumbExts = ['jpg', 'jpeg']; // 同名的精灵图, Artplayer progress preview
$thumbNumber = 54;  // 6 * 9 = tile 行*列
$thumbColumn = 6;   // tile 的第一维(列数)
$thumbScale = 0.85;

function thumbConfig(string $thumbRel, int $number, int $column, float $scale): array
{
    return [
        'url' => playUrl($thumbRel),
        'number' => $number,
        'column' => $column,
        'scale' => $scale,
    ];
}

header('Access-Control-Allow-Origin: *');
header('Access-Control-Expose-Headers: Accept-Ranges, Content-Range, Content-Length');
header('Cache-Control: no-cache, no-store, must-revalidate');

if (isset($_GET['play'])) {
    streamVideo($videoDir, (string)$_GET['play'], $videoExts, $subExts, $thumbExts);
    exit;
}

if (isset($_GET['fav'])) {
    handleFavorites();
    exit;
}

if (isset($_GET['delete'])) {
    handleDelete($videoDir, $videoExts);
    exit;
}

listVideos($videoDir, $videoExts, $subExts, $thumbExts);
exit;

function favStore(): \SleekDB\Store
{
    // timeout=>false: 否则 SleekDB 默认 timeout 会触发 Deprecated 通知污染 JSON 输出
    return new \SleekDB\Store('favorites', $GLOBALS['favDataDir'], ['timeout' => false]);
}

/**
 * 收藏接口 (SleekDB 持久化):
 *   GET  ?fav          -> 返回收藏的视频文件列表 (按收藏时间倒序)
 *   POST ?fav  JSON    -> body: {file: string, fav?: bool}
 *                          fav 省略时按当前状态取反 (toggle);
 *                          fav=true 收藏, fav=false 取消收藏
 */
function handleFavorites(): void
{
    header('Content-Type: application/json; charset=utf-8');

    $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
    if ($method === 'OPTIONS') {
        http_response_code(204);
        return;
    }

    try {
        $store = favStore();
    } catch (Throwable $e) {
        http_response_code(500);
        echo json_encode(['ok' => false, 'error' => '收藏存储初始化失败: ' . $e->getMessage()], JSON_UNESCAPED_UNICODE);
        return;
    }

    if ($method === 'GET') {
        try {
            $docs = $store->findAll(['added_at' => 'desc']);
        } catch (Throwable $e) {
            http_response_code(500);
            echo json_encode(['ok' => false, 'error' => '读取收藏失败: ' . $e->getMessage()], JSON_UNESCAPED_UNICODE);
            return;
        }
        $files = [];
        foreach ($docs as $doc) {
            if (isset($doc['file']) && is_string($doc['file'])) {
                $files[] = $doc['file'];
            }
            if (count($files) >= 500) break; // 防异常数据撑爆
        }
        echo json_encode([
            'ok' => true,
            'count' => count($files),
            'files' => $files,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        return;
    }

    if ($method !== 'POST') {
        http_response_code(405);
        echo json_encode(['ok' => false, 'error' => '方法不支持'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $raw = file_get_contents('php://input');
    $body = json_decode($raw === false ? '' : $raw, true);
    if (!is_array($body)) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '无效的 JSON 请求体'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $file = isset($body['file']) && is_string($body['file']) ? trim($body['file']) : '';
    if ($file === '' || str_contains($file, "\0") || str_starts_with($file, '/') || str_contains($file, '..')) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '无效的 file 字段'], JSON_UNESCAPED_UNICODE);
        return;
    }

    try {
        $existing = $store->findOneBy([['file', '=', $file]]);
        $fav = array_key_exists('fav', $body) ? (bool)$body['fav'] : ($existing === null);
        if ($fav && $existing === null) {
            $store->insert(['file' => $file, 'added_at' => time()]);
        } elseif (!$fav && $existing !== null) {
            $store->deleteBy([['file', '=', $file]]);
        }
        echo json_encode(['ok' => true, 'file' => $file, 'fav' => $fav], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    } catch (Throwable $e) {
        http_response_code(500);
        echo json_encode(['ok' => false, 'error' => '收藏操作失败: ' . $e->getMessage()], JSON_UNESCAPED_UNICODE);
    }
}

/**
 * 删除视频接口 (?delete):
 *   POST  JSON -> body: {file: string}  (相对 VIDEO_DIR 的视频文件路径)
 *   同时删除视频文件本体及其精灵图 (<base>.<COLS>x<ROWS>.jpg / 旧版 <base>.jpg),
 *   并顺手清理收藏记录。
 */
function handleDelete(string $dir, array $videoExts): void
{
    header('Content-Type: application/json; charset=utf-8');

    $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
    if ($method === 'OPTIONS') {
        http_response_code(204);
        return;
    }
    if ($method !== 'POST') {
        http_response_code(405);
        echo json_encode(['ok' => false, 'error' => '仅支持 POST'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $raw = file_get_contents('php://input');
    $body = json_decode($raw === false ? '' : $raw, true);
    if (!is_array($body)) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '无效的 JSON 请求体'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $file = isset($body['file']) && is_string($body['file']) ? trim($body['file']) : '';
    if ($file === '' || str_contains($file, "\0") || str_starts_with($file, '/') || str_contains($file, '..')) {
        http_response_code(400);
        echo json_encode(['ok' => false, 'error' => '无效的 file 字段'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $root = realpath($dir);
    if ($root === false || !is_dir($root)) {
        http_response_code(500);
        echo json_encode(['ok' => false, 'error' => 'VIDEO_DIR not found: ' . $dir], JSON_UNESCAPED_UNICODE);
        return;
    }

    $full = realpath($root . DIRECTORY_SEPARATOR . $file);
    if ($full === false || !str_starts_with($full, $root . DIRECTORY_SEPARATOR) || !is_file($full)) {
        http_response_code(404);
        echo json_encode(['ok' => false, 'error' => '文件不存在'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $ext = strtolower(pathinfo($full, PATHINFO_EXTENSION));
    if (!in_array($ext, $videoExts, true)) {
        http_response_code(403);
        echo json_encode(['ok' => false, 'error' => '只能删除视频文件'], JSON_UNESCAPED_UNICODE);
        return;
    }

    $dirName = dirname($full);
    $base = pathinfo($full, PATHINFO_FILENAME);
    $deleted = [];
    $errors = [];

    // 视频本体
    if (@unlink($full)) {
        $deleted[] = $file;
    } else {
        $errors[] = $file;
    }

    // 精灵图: 网格命名 <base>.<COLS>x<ROWS>.jpg|jpeg, 以及旧版 <base>.jpg|jpeg
    $thumbPrefix = preg_quote($base . '.', '/');
    foreach (glob($dirName . DIRECTORY_SEPARATOR . $base . '.*') as $cand) {
        $bn = pathinfo($cand, PATHINFO_BASENAME);
        if (!preg_match('/^' . $thumbPrefix . '(\d+)x(\d+)\.(?:jpg|jpeg)$/i', $bn)
            && !preg_match('/^' . $thumbPrefix . '(?:jpg|jpeg)$/i', $bn)) {
            continue;
        }
        if (@unlink($cand)) {
            $deleted[] = $bn;
        } else {
            $errors[] = $bn;
        }
    }

    // 清理收藏记录
    try {
        $store = favStore();
        $store->deleteBy([['file', '=', $file]]);
    } catch (Throwable $e) {
        // 收藏清理失败不阻塞删除
    }

    $fileDeleted = in_array($file, $deleted, true);
    if ($fileDeleted && empty($errors)) {
        echo json_encode(['ok' => true, 'deleted' => $deleted, 'count' => count($deleted)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        return;
    }

    http_response_code(500);
    echo json_encode([
        'ok' => false,
        'error' => $fileDeleted ? '部分关联文件删除失败' : '视频文件删除失败',
        'deleted' => $deleted,
        'errors' => $errors,
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function listVideos(string $dir, array $videoExts, array $subExts, array $thumbExts): void
{
    header('Content-Type: application/json; charset=utf-8');

    $root = realpath($dir);
    if ($root === false || !is_dir($root)) {
        http_response_code(500);
        echo json_encode(['ok' => false, 'error' => 'VIDEO_DIR not found: ' . $dir], JSON_UNESCAPED_UNICODE);
        return;
    }

    $videos = [];
    if (is_readable($root)) {
        $it = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS)
        );
        foreach ($it as $file) {
            if (!$file->isFile()) continue;
            $ext = strtolower($file->getExtension());
            if (!in_array($ext, $videoExts, true)) continue;

            $full = $file->getPathname();
            $rel = ltrim(str_replace('\\', '/', substr($full, strlen($root))), '/');
            $base = pathinfo($full, PATHINFO_FILENAME);

            $subs = [];
            foreach ($subExts as $se) {
                $candidate = $file->getPath() . DIRECTORY_SEPARATOR . $base . '.' . $se;
                if (is_file($candidate) && is_readable($candidate)) {
                    $subRel = ltrim(str_replace('\\', '/', substr($candidate, strlen($root))), '/');
                    $subs[] = [
                        'title' => strtoupper($se),
                        'url' => playUrl($subRel),
                    ];
                }
            }

            $thumbnails = null;
            $thumbDir = $file->getPath();
            $thumbPrefix = preg_quote($base . '.', '/');
            $bestCells = 0;
            foreach (['*.jpg', '*.jpeg'] as $thumbTail) {
                foreach (glob($thumbDir . DIRECTORY_SEPARATOR . $base . '.' . $thumbTail) as $cand) {
                    if (!preg_match('/^' . $thumbPrefix . '(\d+)x(\d+)\.(?:jpg|jpeg)$/i', pathinfo($cand, PATHINFO_BASENAME), $m)) continue;
                    $cols = (int)$m[1];
                    $rows = (int)$m[2];
                    if ($cols < 1 || $rows < 1) continue;
                    $cells = $cols * $rows;
                    if ($cells <= $bestCells) continue;
                    $bestCells = $cells;
                    $thumbRel = ltrim(str_replace('\\', '/', substr($cand, strlen($root))), '/');
                    $thumbnails = thumbConfig($thumbRel, $rows * $cols, $cols, $GLOBALS['thumbScale']);
                }
            }
            // 兼容旧格式 <base>.jpg (无网格信息, 使用默认 54/6)
            if ($thumbnails === null) {
                foreach ($thumbExts as $te) {
                    $candidate = $thumbDir . DIRECTORY_SEPARATOR . $base . '.' . $te;
                    if (is_file($candidate) && is_readable($candidate)) {
                        $thumbRel = ltrim(str_replace('\\', '/', substr($candidate, strlen($root))), '/');
                        $thumbnails = thumbConfig($thumbRel, $GLOBALS['thumbNumber'], $GLOBALS['thumbColumn'], $GLOBALS['thumbScale']);
                        break;
                    }
                }
            }

            $poster = null;
            $posterCandidate = $file->getPath() . DIRECTORY_SEPARATOR . $base . '.jpg';
            if (is_file($posterCandidate) && is_readable($posterCandidate)) {
                $posterRel = ltrim(str_replace('\\', '/', substr($posterCandidate, strlen($root))), '/');
                $poster = playUrl($posterRel);
            }

            $videos[] = [
                'title' => $base,
                'file' => $rel,
                'url' => playUrl($rel),
                'ext' => $ext,
                'size' => $file->getSize(),
                'mtime' => $file->getMTime(),
                'subtitle' => $subs ?: null,
                'thumbnails' => $thumbnails,
                'poster' => $poster ?? ($thumbnails['url'] ?? null),
            ];
        }
    }

    usort($videos, static fn(array $a, array $b) => $b['mtime'] <=> $a['mtime']);

    echo json_encode([
        'ok' => true,
        'dir' => $root,
        'count' => count($videos),
        'videos' => $videos,
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function playUrl(string $rel): string
{
    $self = basename($_SERVER['SCRIPT_NAME'] ?? 'palayer.php');
    return '/file/' . encodeRel($rel); // ! 配合Caddyfile
    return $self . '?play=' . encodeRel($rel);
}

function encodeRel(string $rel): string
{
    return str_replace('%2F', '/', rawurlencode($rel));
}

function streamVideo(string $dir, string $rel, array $videoExts, array $subExts, array $thumbExts): void
{
    $root = realpath($dir);
    $rel = str_replace("\0", '', $rel);

    if ($root === false || $rel === '' || str_starts_with($rel, '/') || str_contains($rel, '..')) {
        http_response_code(400);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'Bad Request';
        return;
    }

    $full = realpath($root . DIRECTORY_SEPARATOR . $rel);
    if ($full === false || !str_starts_with($full, $root . DIRECTORY_SEPARATOR) || !is_file($full) || !is_readable($full)) {
        http_response_code(404);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'Not Found';
        return;
    }

    $ext = strtolower(pathinfo($full, PATHINFO_EXTENSION));
    if (!in_array($ext, array_merge($videoExts, $subExts, $thumbExts), true)) {
        http_response_code(403);
        header('Content-Type: text/plain; charset=utf-8');
        echo 'Forbidden';
        return;
    }

    $size = (int)filesize($full);
    $mime = mimeByExt($ext);
    $start = 0;
    $end = $size > 0 ? $size - 1 : 0;
    $status = 200;

    $range = $_SERVER['HTTP_RANGE'] ?? '';
    if ($range !== '' && preg_match('/^\s*bytes=(\d*)-(\d*)\s*$/', $range, $m) && $size > 0) {
        if ($m[1] === '') {
            $suffix = (int)$m[2];
            if ($suffix > 0) {
                $start = max(0, $size - $suffix);
            }
        } else {
            $start = (int)$m[1];
            if ($m[2] !== '') {
                $end = min((int)$m[2], $size - 1);
            }
        }
        if ($start > $end || $start >= $size) {
            http_response_code(416);
            header("Content-Range: bytes */{$size}");
            return;
        }
        $status = 206;
    }

    $length = $end - $start + 1;

    // 媒体流允许浏览器缓存, 避免 no-store 导致每次 seek/重试都回源
    header_remove('Cache-Control');
    header('Cache-Control: private, max-age=3600');
    header('Last-Modified: ' . gmdate('D, d M Y H:i:s', (int)filemtime($full)) . ' GMT');

    http_response_code($status);
    header('Content-Type: ' . $mime);
    header('Accept-Ranges: bytes');
    header("Content-Length: {$length}");
    header('Content-Disposition: inline; filename="' . rawurlencode(pathinfo($full, PATHINFO_BASENAME)) . '"');
    if ($status === 206) {
        header("Content-Range: bytes {$start}-{$end}/{$size}");
    }

    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'HEAD') {
        return;
    }

    $fp = fopen($full, 'rb');
    if ($fp === false) {
        http_response_code(500);
        return;
    }

    fseek($fp, $start);
    $remaining = $length;
    while ($remaining > 0 && !feof($fp) && !connection_aborted()) {
        $chunk = fread($fp, min(1024 * 256, $remaining));
        if ($chunk === false) break;
        echo $chunk;
        $remaining -= strlen($chunk);
        flush();
    }
    fclose($fp);
}

function mimeByExt(string $ext): string
{
    return match ($ext) {
        'mp4', 'm4v' => 'video/mp4',
        'webm' => 'video/webm',
        'mkv' => 'video/x-matroska',
        'avi' => 'video/x-msvideo',
        'mov' => 'video/quicktime',
        'flv' => 'video/x-flv',
        'wmv' => 'video/x-ms-wmv',
        'mpg', 'mpeg' => 'video/mpeg',
        'ts', 'm2ts' => 'video/mp2t',
        'ogv' => 'video/ogg',
        '3gp' => 'video/3gpp',
        'm3u8' => 'application/vnd.apple.mpegurl',
        'srt' => 'application/x-subrip',
        'ass', 'ssa' => 'text/plain; charset=utf-8',
        'vtt' => 'text/vtt; charset=utf-8',
        'jpg', 'jpeg' => 'image/jpeg',
        default => 'application/octet-stream',
    };
}
