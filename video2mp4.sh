#!/usr/bin/env bash
# video2mp4.sh <视频文件>
# 对视频文件进行重新无损编码

SRC="${1:-}"
DIR=$(dirname "$SRC")
BASE=$(basename "$SRC")
NAME="${BASE%.*}"
FILENAME="$DIR/$NAME.converted.mp4"

ffmpeg -i "$SRC" \
  -c:v libx264 \
  -c:a aac -b:a 128k -ac 2 -ar 44100 -profile:a aac_low \
  -c:s webvtt \
  "$FILENAME"

# ! 生成缩略图
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SPRITE="$SCRIPT_DIR/sprite.sh"
sh "$SPRITE" "$FILENAME"