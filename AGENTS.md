# AGENTS.md

本地视频墙：`palayer.php`（列表+流媒体，无框架）、`index.html`(ArtPlayer 前端，无构建)、`sprite.sh`（ffmpeg 精灵图生成）。无 package.json/composer/CI/测试框架。代码注释和 UI 用中文。

## 运行与验证

- 启动：`PHP_CLI_SERVER_WORKERS=20 php -S 0.0.0.0:12345`（视频目录用环境变量 `VIDEO_DIR` 覆盖，默认 `/home/jcleng/Downloads/mv/upnp/`）。
- 无自动化测试。手动验证：`php -l palayer.php`、`sh -n sprite.sh`、对 `index.html` 内联 `<script>` 抽出来跑 `node --check`；再起服务 + 临时 `VIDEO_DIR` 里放假的 mp4/jpg，用 curl 打 `palayer.php` 与 `?play=`。
- 该环境的 PHP 没启用 `GLOB_BRACE`，别用，用 `['*.jpg','*.jpeg']` 两次 glob。

## 结构要点

- `palayer.php` 二合一：无 `play` 参数 → 递归列出所有视频的 JSON；`?play=<rel>` → 支持 Range 的流（视频/字幕/精灵图都走这里）。文件名是拼错的 `palayer.php`（不是 player），`index.html` 按字面请求它，别改名。
- 列表接口 `Cache-Control: no-cache`；但 `streamVideo`（`?play=`）会用 `header_remove` 改成 `private, max-age=3600` + `Last-Modified`。不要动——这是靠缓存减少 seek/重试回源的关键。
- 大目录/多视频时，卡片只用 `<img>` 封面（`index.html createCard`）；**不要再引入每个卡片建 `<video>` 取帧**——这样会打爆并发（20 worker 排队超时 → 浏览器反复重试同一 `?play=` 请求）。

## 精灵图（进度条缩略图）约定

- `sprite.sh <video>` 生成 `<name>.<COLS>x<ROWS>.jpg`（例 `abc.16x18.jpg`），网格信息编码在**文件名**里；名字和网格之间是**点**（`.16x18`），不是下划线——`palayer.php` 用 `glob(dir/base.*.jpg)` + 正则 `^base\.(\d+)x(\d+)\.jpg$` 解析，两边不一致会导致缩略图静默失效（曾踩过）。
- 网格按时长选，保证每帧 ≤30s、上限 16x18=288：`6x9 / 10x10 / 12x14 / 16x18`。ffmpeg `tile=<cols>x<rows>`（列在前）。
- `palayer.php` 返回 `number=cols*rows`、`column=cols`（ArtPlayer 语义：number=总格数、column=每行列数）。一旦与精灵图实际网格不一致，进度条预览会错乱。多张网格图共存时自动取格数最多的。旧版无网格命名的 `base.jpg` 回退默认 54/6。
- 封面取 `base.jpg`，否则回退用精灵图 URL（`palayer.php:104-120`）。
- `readme.md` 已过时（还说精灵图是 `xx.jpg`），以代码为准。

## 前端配置陷阱

- `openPlayer` 里 `autoSize: false` 不能改回 true：竖屏视频会被缩成窄竖条、控件看不见；进度条精灵图也会错位。
- `.player-wrap video` 用 `object-fit: contain` 保证竖屏视频等比居中、控制条可见。
- `static/artplayer.js` 是压缩过的 ArtPlayer v5.4.0（CSS 内嵌在 JS 里，别按源码格式搜样式）。