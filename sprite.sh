#!/bin/sh
# sprite.sh <视频文件>
# 在视频所在目录生成同名精灵图 (xx.mp4 -> xx.jpg), 供 Artplayer 进度条预览

set -u

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 <video file>"; exit 1; }
[ -f "$SRC" ] || { echo "file not found: $SRC"; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 1; }

DIR=$(dirname "$SRC")
BASE=$(basename "$SRC")
NAME="${BASE%.*}"

SPRITE="$DIR/$NAME.jpg"
LOG="$DIR/$NAME.log"
SEC="$DIR/$NAME.sec"
PROG="$DIR/$NAME.prog"
TMP="$DIR/.$NAME.sprite.tmp.jpg"

rm -f "$LOG" "$SEC" "$PROG" "$TMP"
touch "$LOG"

# 1. 探测时长
if command -v ffprobe >/dev/null 2>&1; then
    DUR=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$SRC" 2>>"$LOG" | head -1)
else
    DUR=$(ffmpeg -nostdin -i "$SRC" 2>&1 | grep -o 'Duration: [0-9][0-9]:[0-9][0-9]:[0-9][0-9.]*' | head -1 | cut -d' ' -f2)
    [ -n "$DUR" ] && DUR=$(echo "$DUR" | awk -F: '{ printf "%.3f", $1*3600+$2*60+$3 }')
fi

# 2. 计算采样间隔: 全片取 ~54 帧 (6x9 格)
case "$DUR" in
    ""|0|0.000) INTERVAL=10 ;;
    *) INTERVAL=$(awk -v d="$DUR" 'BEGIN{ i=(d/54)*0.97; if (i<0.05) i=0.05; printf "%.3f", i }') ;;
esac

# 3. 生成精灵图到临时文件, 成功后再原子替换, 避免半成品
if ! ffmpeg -nostdin -y -i "$SRC" -vf "fps=1/$INTERVAL,scale=160:-2,tile=6x9" -frames:v 1 -q:v 3 -an "$TMP" >>"$LOG" 2>&1; then
    rm -f "$TMP" "$PROG"
    echo "FAILED: $SRC" >>"$LOG"
    exit 1
fi
mv -f "$TMP" "$SPRITE"
rm -f "$PROG"
echo "OK: $SPRITE (dur=${DUR}s, interval=${INTERVAL}s)" >>"$LOG"
exit 0