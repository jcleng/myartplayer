<?php
declare(strict_types=1);

$videoDir = rtrim((string)(getenv('VIDEO_DIR') ?: '/home/jcleng/Downloads/mv/upnp/'), '/');

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

listVideos($videoDir, $videoExts, $subExts, $thumbExts);
exit;

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
            foreach ($thumbExts as $te) {
                $candidate = $file->getPath() . DIRECTORY_SEPARATOR . $base . '.' . $te;
                if (is_file($candidate) && is_readable($candidate)) {
                    $thumbRel = ltrim(str_replace('\\', '/', substr($candidate, strlen($root))), '/');
                    $thumbnails = thumbConfig($thumbRel, $GLOBALS['thumbNumber'], $GLOBALS['thumbColumn'], $GLOBALS['thumbScale']);
                    break;
                }
            }

            $poster = null;
            $posterCandidate = $file->getPath() . DIRECTORY_SEPARATOR . $base . '.thumbnail.jpg';
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
                'poster' => $poster,
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
