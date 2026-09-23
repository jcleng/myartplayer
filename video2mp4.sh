#!/usr/bin/env bash
# sprite.sh <视频文件>

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