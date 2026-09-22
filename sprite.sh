#!/bin/sh
# sprite.sh <视频文件>
# 在视频所在目录生成精灵图 (xx.mp4 -> xx_列x行.jpg, 如 a_16x18.jpg),
# 网格信息记录在文件名中, 供后端解析; 也供 Artplayer 进度条预览

set -u

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 <video file>"; exit 1; }
[ -f "$SRC" ] || { echo "file not found: $SRC"; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 1; }

DIR=$(dirname "$SRC")
BASE=$(basename "$SRC")
NAME="${BASE%.*}"

LOG="$DIR/$NAME.log"
PROG="$DIR/$NAME.prog"
TMP="$DIR/.$NAME.sprite.tmp.jpg"

rm -f "$LOG" "$PROG" "$TMP"
touch "$LOG"

# 1. 探测时长
if command -v ffprobe >/dev/null 2>&1; then
    DUR=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$SRC" 2>>"$LOG" | head -1)
else
    DUR=$(ffmpeg -nostdin -i "$SRC" 2>&1 | grep -o 'Duration: [0-9][0-9]:[0-9][0-9]:[0-9][0-9.]*' | head -1 | cut -d' ' -f2)
    [ -n "$DUR" ] && DUR=$(echo "$DUR" | awk -F: '{ printf "%.3f", $1*3600+$2*60+$3 }')
fi

# 2. 按时长选网格 (列x行): 保证每帧间隔 <= 30s, 最长视频最多 16x18=288 帧
COLS=6
ROWS=9
INTERVAL=10
if [ -n "$DUR" ] && [ "$DUR" != "0" ] && [ "$DUR" != "0.000" ]; then
    GRID=$(awk -v d="$DUR" 'BEGIN{
        n = split("6 9 54;10 10 100;12 14 168;16 18 288", g, ";");
        c = 6; r = 9; cnt = 54;
        for (i = 1; i <= n; i++) {
            split(g[i], a, " ");
            c = a[1]; r = a[2]; cnt = a[3];
            if (d / cnt <= 30) break;
        }
        iv = (d / cnt) * 0.97;
        if (iv < 0.05) iv = 0.05;
        printf "%d %d %.3f", c, r, iv;
    }')
    COLS=${GRID%% *}
    REST=${GRID#* }
    ROWS=${REST%% *}
    INTERVAL=${REST#* }
fi
NUMBER=$((COLS * ROWS))
SPRITE="$DIR/$NAME.${COLS}x${ROWS}.jpg"

# 3. 生成精灵图到临时文件, 成功后再原子替换, 避免半成品
if ! ffmpeg -nostdin -y -i "$SRC" -vf "fps=1/${INTERVAL},scale=160:-2,tile=${COLS}x${ROWS}" -frames:v 1 -q:v 3 -an "$TMP" >>"$LOG" 2>&1; then
    rm -f "$TMP" "$PROG"
    echo "FAILED: $SRC" >>"$LOG"
    exit 1
fi
mv -f "$TMP" "$SPRITE"
rm -f "$PROG"
echo "OK: $SPRITE (dur=${DUR}s, grid=${COLS}x${ROWS}, interval=${INTERVAL}s)" >>"$LOG"
rm -f "$LOG"
exit 0