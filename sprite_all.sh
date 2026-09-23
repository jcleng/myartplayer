#!/bin/sh
# sprite_all.sh [目录]
# 遍历目录及子目录的 mp4 文件, 逐个调用 sprite.sh 生成精灵图
# 已存在精灵图 (<名字>.<列>x<行>.jpg) 的视频自动跳过

set -u

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "not a directory: $DIR"; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SPRITE="$SCRIPT_DIR/sprite.sh"
[ -f "$SPRITE" ] || { echo "sprite.sh not found: $SPRITE"; exit 1; }
chmod +x "$SPRITE" 2>/dev/null || true

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

# 用 find 而非 glob, 正确处理文件名中的空格
find "$DIR" -type f -name '*.mp4' > "$LIST"

TOTAL=0
OK=0
SKIP=0
FAIL=0

# 重定向到文件, 避免管道子 shell 丢失计数
while IFS= read -r VIDEO; do
    TOTAL=$((TOTAL + 1))

    # 已有精灵图则跳过 (匹配 name.*x*.jpg)
    DIRNAME=$(dirname "$VIDEO")
    BASENAME=$(basename "$VIDEO")
    NAME=${BASENAME%.*}
    EXISTING=$(find "$DIRNAME" -maxdepth 1 -type f -name "$NAME.*x*.jpg" | head -1)
    if [ -n "$EXISTING" ]; then
        echo "SKIP: $VIDEO (已有 $EXISTING)"
        SKIP=$((SKIP + 1))
        continue
    fi

    echo "处理 ($TOTAL): $VIDEO"
    if sh "$SPRITE" "$VIDEO"; then
        OK=$((OK + 1))
    else
        echo "FAIL: $VIDEO"
        FAIL=$((FAIL + 1))
    fi
done < "$LIST"

echo "完成: 共 $TOTAL, 新生成 $OK, 跳过 $SKIP, 失败 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
