#!/usr/bin/env bash
#
# video2mp4.sh —— 把视频文件统一转为兼容性最好的 MP4（H.264 + AAC）
# 参数风格参考原 HLS 加密切片命令（libx264 / aac 128k 2ch 44.1k / aac_low）
#
# 用法:
#   ./video2mp4.sh [选项] <输入文件或目录> [<输入文件或目录> ...]
#
# ============================ 质量档位 ============================
#   --remux      零重编码，仅换容器（流拷贝，画质 100% 无损，秒完成）——源已是 H.264/AAC 时的天花板
#   --lossless   数学无损重编码（crf 0 + veryslow，像素级可还原，体积约为源的 3~10 倍）
#   --hq         视觉无损重编码（crf 17 + veryslow + 沿用源位深 + 音轨 320k）——转码场景的推荐档
#   （不带档位则默认 crf 23 / medium，即原命令的平衡档）
#
# ============================ 手动调参 ============================
#   -q N         CRF 0-51（0=数学无损，17≈视觉无损，23=默认，28+ 明显压缩）；会覆盖档位预设
#   -p PRESET    x264 preset: ultrafast/superfast/veryfast/faster/fast/medium/slow/slower/veryslow/placebo
#   -t TUNE      x264 tune: film|animation|grain|stillimage|fastdecode|zerolatency
#                （真人实拍 film，动画 animation，老片/胶片颗粒 grain）
#   -X PARAMS    透传给 x264 的高级参数，如 "ref=6:aq-mode=3:deblock=-1:-1"
#   -k           保持源位深/像素格式（8bit 源不必加；10bit 源在 --hq/--lossless 下默认开启）
#   --ab RATE    音频码率（默认 128k；--hq 下为 320k）
#
# ============================ 轨道处理 ============================
#   -s MODE      字幕: none(默认,丢弃) | auto(文本字幕转 mov_text,图形字幕丢弃) | mov_text | burn(硬烧录)
#   -a MODE      音轨: first(默认,只留第一条) | all(保留全部) | none(去音轨) | copy(音轨不重编码)
#   -o DIR       输出目录（默认与源文件同目录）
#   -f           已存在则覆盖（默认自动改名，绝不覆盖源文件）
#   -n           dry-run：只打印将要执行的 ffmpeg 命令
#   -v           输出 ffmpeg 详细日志（默认只显示进度条）
#
# ============================ 附加 HLS ============================
#   --hls            在 MP4 之外额外产出加密 HLS（m3u8 + ts + key）
#   --key-info F     key_info 文件（第1行密钥URI / 第2行本地密钥路径 / 第3行可选IV）
#   --hls-time N     分片时长秒数（默认 5）
#
# ============================ 示例 ============================
#   ./video2mp4.sh --remux input.mkv                 # 已是 h264+aac，秒出无损 mp4
#   ./video2mp4.sh --hq -t film input.mkv            # 真人实拍，视觉无损
#   ./video2mp4.sh --hq -t animation -o ./out /media # 动画批量，目录递归
#   ./video2mp4.sh --lossless -p placebo master.mov  # 母版归档，数学无损
#   ./video2mp4.sh -q 18 -p slow -a all -s auto a.mkv
#   ./video2mp4.sh --hls --key-info key_info.txt input.mkv
#
# 环境: WSL2 / Linux / Termux(先 pkg install ffmpeg) 均可；依赖 ffmpeg、ffprobe
#

set -euo pipefail

# ---------------- 默认值 ----------------
QUALITY=lossless            # normal | hq | lossless | remux
CRF=0
PRESET_X=medium           # x264 preset（避免和 preset 变量名混淆）
PIX_FMT=yuv420p
V_CODEC=libx264
TUNE=""
XPARAMS=""
KEEP_DEPTH=0

A_BITRATE=128k
A_CHANNELS=2
A_RATE=44100
A_PROFILE=aac_low

SUB_MODE=none             # none | auto | mov_text | burn
AUDIO_MODE=first          # first | all | none | copy
OUT_DIR=""
FORCE=0
DRY_RUN=0
VERBOSE=0
HLS=0
KEY_INFO=""
HLS_TIME=5

# 记录用户是否显式设置过（避免被档位预设覆盖）
CRF_SET=0; PRESET_SET=0; SUB_SET=0; AUDIO_SET=0; AB_SET=0; TUNE_SET=0

TOTAL=0; OK=0; FAIL=0

# ---------------- 工具函数 ----------------
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] 警告: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
usage(){ sed -n '3,50p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0; }

need_bin() {
    command -v ffmpeg  >/dev/null 2>&1 || die "未找到 ffmpeg（Linux: apt install ffmpeg；Termux: pkg install ffmpeg）"
    command -v ffprobe >/dev/null 2>&1 || die "未找到 ffprobe"
}

# ffprobe 取值（空=取不到）
probe() { # $1=文件 $2=流类型 v|a|s $3=字段
    ffprobe -v error -select_streams "$2" -show_entries "stream=$3" -of csv=p=0 "$1" 2>/dev/null \
        | head -n1 | tr -d '\r'
}
has_stream() { [ -n "$(ffprobe -v error -select_streams "$2" -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | head -n1)" ]; }

# 编码器是否存在（比 -h encoder= 判定可靠：不存在的编码器 ffmpeg -h 也可能返回 0）
encoder_ok() { ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE "^[[:space:]]*V.*[[:space:]]$1[[:space:]]"; }

# 10bit 源优先用 libx264-10bit，否则降级 8bit 并警告
# 输出：V_CODEC（编码器）、PF_OUT（建议像素格式，空=沿用调用方的值）
PF_OUT=""
pick_vcodec() { # $1=源 pix_fmt
    PF_OUT=""
    case "$1" in
        *10le|*10be|*12le|*12be)
            if encoder_ok libx264-10bit; then
                V_CODEC=libx264-10bit
                PF_OUT="$(norm_pixfmt "$1")"
            else
                V_CODEC=libx264
                PF_OUT=yuv420p
                warn "源为高位深 ($1)，但本机 ffmpeg 无 libx264-10bit，将降级为 8bit（建议换装带 10bit 的 ffmpeg）"
            fi ;;
        *) V_CODEC=libx264 ;;
    esac
}

# yuvj420p 之类的 full-range 老格式在 mp4 中已废弃，映射成 yuv420p
norm_pixfmt() { case "$1" in yuvj420p) echo yuv420p;; yuvj422p) echo yuv422p;; yuvj444p) echo yuv444p;; *) echo "$1";; esac; }

# 音轨能否直接拷进 MP4（可拷贝的编码白名单）
audio_copyable() { case "$(probe "$1" a codec_name)" in aac|mp3|ac3|eac3|alac|flac) return 0;; *) return 1;; esac; }

# 字幕是否文本类（MP4 只装得下文本字幕，PGS/DVDSub 等图形字幕必须丢弃或烧录）
sub_is_text() { case "$(probe "$1" s codec_name)" in subrip|ass|ssa|mov_text|webvtt|text) return 0;; *) return 1;; esac; }

# 目标路径：绝不覆盖源文件，默认也不覆盖已有文件
build_output() { # $1=输入文件 $2=扩展名
    local base dir out n=1
    dir="${OUT_DIR:-$(dirname "$1")}"
    base="$(basename "$1")"; base="${base%.*}"
    out="$dir/$base.$2"
    if [ "$(cd "$dir" 2>/dev/null && pwd)" = "$(cd "$(dirname "$1")" && pwd)" ] && [ "$out" = "$1" ]; then
        out="$dir/${base}.converted.$2"
    fi
    while [ -e "$out" ] && [ "$FORCE" -ne 1 ]; do
        out="$dir/${base}($n).$2"; n=$((n+1))
    done
    printf '%s' "$out"
}

esc_filter_path() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/:/\\\\:/g" -e "s/'/\\\\'/g"; }

# ---------------- 核心：转 MP4 ----------------
to_mp4() {
    local in="$1" out srcfmt
    [ -f "$in" ] || { log "跳过（不存在）: $in"; return 0; }

    out="$(build_output "$in" mp4)"
    mkdir -p "$(dirname "$out")"

    local -a args=(-hide_banner -y -i "$in" -map_metadata 0 -map_chapters 0)
    local vc="$V_CODEC" pf="$PIX_FMT"

    srcfmt="$(probe "$in" v pix_fmt)"

    # ---------- 视频 ----------
    if [ "$QUALITY" = remux ]; then
        args+=(-map 0:v:0 -c:v copy)
    else
        if [ "$KEEP_DEPTH" -eq 1 ] && [ -n "$srcfmt" ]; then
            pf="$(norm_pixfmt "$srcfmt")"
            pick_vcodec "$srcfmt"
            vc="$V_CODEC"
            [ -n "$PF_OUT" ] && pf="$PF_OUT"
        else
            vc="$V_CODEC"
        fi
        args+=(-map 0:v:0 -c:v "$vc" -preset "$PRESET_X" -crf "$CRF" -pix_fmt "$pf")
        [ -n "$TUNE" ]    && args+=(-tune "$TUNE")
        [ -n "$XPARAMS" ] && args+=(-x264-params "$XPARAMS")
    fi

    # ---------- 音频 ----------
    local amode="$AUDIO_MODE"
    if [ "$QUALITY" = remux ] && [ "$AUDIO_SET" -eq 0 ]; then amode=all; fi
    case "$amode" in
        none) args+=(-an) ;;
        copy)
            if ! has_stream "$in" a; then
                args+=(-an)
            elif audio_copyable "$in"; then
                args+=(-map 0:a? -c:a copy)
            else
                warn "$in：音轨（$(probe "$in" a codec_name)）不适合直接封装进 MP4，改为 AAC 重编码（要保留多声道请用 -a all）"
                args+=(-map 0:a? -c:a aac -b:a "$A_BITRATE" -ac "$A_CHANNELS" -ar "$A_RATE" -profile:a "$A_PROFILE")
            fi ;;
        all)
            if has_stream "$in" a; then
                if [ "$QUALITY" = remux ] && audio_copyable "$in"; then
                    args+=(-map 0:a? -c:a copy)
                else
                    args+=(-map 0:a? -c:a aac -b:a "$A_BITRATE" -ac "$A_CHANNELS" -ar "$A_RATE" -profile:a "$A_PROFILE")
                fi
            else args+=(-an); fi ;;
        *)
            if has_stream "$in" a; then
                if [ "$QUALITY" = remux ] && audio_copyable "$in"; then
                    args+=(-map 0:a:0? -c:a copy)
                else
                    args+=(-map 0:a:0? -c:a aac -b:a "$A_BITRATE" -ac "$A_CHANNELS" -ar "$A_RATE" -profile:a "$A_PROFILE")
                fi
            else args+=(-an); fi ;;
    esac

    # ---------- 字幕 ----------
    case "$SUB_MODE" in
        none) args+=(-sn) ;;
        burn)
            if has_stream "$in" s; then
                args+=(-vf "subtitles='$(esc_filter_path "$in")'")
            else args+=(-sn); fi ;;
        auto|mov_text)
            if has_stream "$in" s; then
                if sub_is_text "$in"; then
                    args+=(-map 0:s? -c:s mov_text)
                else
                    warn "$in：图形字幕（$(probe "$in" s codec_name)）无法封装进 MP4，已丢弃（需保留请改用 -s burn 烧录）"
                    args+=(-sn)
                fi
            else args+=(-sn); fi ;;
        *) die "未知字幕模式: $SUB_MODE" ;;
    esac

    args+=(-movflags +faststart)
    [ "$VERBOSE" -eq 1 ] && args+=(-loglevel info) || args+=(-loglevel error -stats)
    args+=("$out")

    log "转码[$QUALITY crf=$CRF preset=$PRESET_X]: $(basename "$in") -> $out"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'ffmpeg'; printf ' %q' "${args[@]}"; printf '\n'
    else
        if ffmpeg "${args[@]}"; then
            OK=$((OK+1)); log "完成: $out"
        else
            FAIL=$((FAIL+1)); warn "失败: $in"
        fi
    fi

    [ "$HLS" -eq 1 ] && to_hls "$in"
    return 0
}

# ---------------- 附加：加密 HLS ----------------
to_hls() {
    local in="$1" out base dir
    [ -n "$KEY_INFO" ] || die "--hls 必须用 --key-info 指定 key_info 文件"
    [ -f "$KEY_INFO" ] || die "key_info 文件不存在: $KEY_INFO"

    dir="${OUT_DIR:-$(dirname "$in")}"
    base="$(basename "$in")"; base="${base%.*}"
    out="$dir/$base.m3u8"
    mkdir -p "$dir"

    local -a args=(-hide_banner -y -i "$in"
        -c:v libx264 -preset "$PRESET_X" -crf "$CRF" -pix_fmt yuv420p
        -c:a aac -b:a "$A_BITRATE" -ac "$A_CHANNELS" -ar "$A_RATE" -profile:a "$A_PROFILE"
        -c:s webvtt
        -start_number 0 -hls_time "$HLS_TIME" -hls_list_size 0 -f hls
        -hls_key_info_file "$KEY_INFO"
        -master_pl_name "$base.main.m3u8")

    [ "$VERBOSE" -eq 1 ] && args+=(-loglevel info) || args+=(-loglevel error -stats)
    args+=("$out")

    log "切片: $(basename "$in") -> $out"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'ffmpeg'; printf ' %q' "${args[@]}"; printf '\n'
    else
        ffmpeg "${args[@]}" && log "HLS 完成: $out" || warn "HLS 失败: $in"
    fi
}

# ---------------- 参数解析 ----------------
[ $# -eq 0 ] && usage
INPUTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --remux)    QUALITY=remux; shift ;;
        --hq)       QUALITY=hq; shift ;;
        --lossless) QUALITY=lossless; shift ;;
        -o) OUT_DIR="${2:-}"; shift 2 ;;
        -q) CRF="${2:-}"; CRF_SET=1; shift 2 ;;
        -p) PRESET_X="${2:-}"; PRESET_SET=1; shift 2 ;;
        -t) TUNE="${2:-}"; TUNE_SET=1; shift 2 ;;
        -X) XPARAMS="${2:-}"; shift 2 ;;
        -k) KEEP_DEPTH=1; shift ;;
        --ab) A_BITRATE="${2:-}"; AB_SET=1; shift 2 ;;
        -s) SUB_MODE="${2:-}"; SUB_SET=1; shift 2 ;;
        -a) AUDIO_MODE="${2:-}"; AUDIO_SET=1; shift 2 ;;
        -f) FORCE=1; shift ;;
        -n) DRY_RUN=1; shift ;;
        -v) VERBOSE=1; shift ;;
        --hls) HLS=1; shift ;;
        --key-info) KEY_INFO="${2:-}"; shift 2 ;;
        --hls-time) HLS_TIME="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        --) shift; INPUTS+=("$@"); break ;;
        -*) die "未知选项: $1（用 -h 查看帮助）" ;;
        *) INPUTS+=("$1"); shift ;;
    esac
done

[ ${#INPUTS[@]} -eq 0 ] && die "请至少给出一个输入文件或目录"
need_bin

# ---------------- 应用档位预设 ----------------
case "$QUALITY" in
    hq)
        [ "$CRF_SET"    -eq 0 ] && CRF=17
        [ "$PRESET_SET" -eq 0 ] && PRESET_X=veryslow
        [ "$AB_SET"     -eq 0 ] && A_BITRATE=320k
        [ "$AUDIO_SET"  -eq 0 ] && AUDIO_MODE=all
        [ "$SUB_SET"    -eq 0 ] && SUB_MODE=auto
        KEEP_DEPTH=1 ;;
    lossless)
        [ "$CRF_SET"    -eq 0 ] && CRF=0
        [ "$PRESET_SET" -eq 0 ] && PRESET_X=veryslow
        [ "$TUNE_SET"   -eq 1 ] && warn "无损模式(crf 0)下 tune 会被 x264 忽略，已保留设置"
        [ "$AUDIO_SET"  -eq 0 ] && AUDIO_MODE=copy
        [ "$SUB_SET"    -eq 0 ] && SUB_MODE=auto
        KEEP_DEPTH=1 ;;
    remux)
        [ "$SUB_SET" -eq 0 ] && SUB_MODE=auto ;;
esac

# ---------------- 校验 ----------------
case "$CRF" in ''|*[!0-9]*) die "-q 必须是整数（0-51）" ;; esac
[ "$CRF" -ge 0 ] && [ "$CRF" -le 51 ] || die "-q 必须在 0-51 之间"
case "$PRESET_X" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|placebo) ;; *) die "-p preset 非法: $PRESET_X" ;; esac
case "$TUNE" in ""|film|animation|grain|stillimage|fastdecode|zerolatency|psnr|ssim) ;; *) die "-t tune 非法: $TUNE" ;; esac
case "$SUB_MODE"   in none|auto|mov_text|burn) ;; *) die "-s 只支持 none|auto|mov_text|burn" ;; esac
case "$AUDIO_MODE" in first|all|none|copy)     ;; *) die "-a 只支持 first|all|none|copy"     ;; esac
[ -n "$OUT_DIR" ] && mkdir -p "$OUT_DIR"

# 友好提示：源已是 H.264 时，remux 才是零损失
if [ "$QUALITY" = normal ] && [ "$CRF_SET" -eq 0 ]; then
    for f in "${INPUTS[@]}"; do
        [ -f "$f" ] || continue
        if [ "$(probe "$f" v codec_name)" = h264 ] && [ "$(probe "$f" a codec_name)" = aac ]; then
            log "提示：$(basename "$f") 已是 H.264+AAC，追求保真请加 --remux（零重编码、秒完成、画质无损）"
            break
        fi
    done
fi

# ---------------- 主流程 ----------------
for input in "${INPUTS[@]}"; do
    if [ -d "$input" ]; then
        while IFS= read -r -d '' f; do
            TOTAL=$((TOTAL+1)); to_mp4 "$f"
        done < <(find "$input" -type f \
                 \( -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.flv' \
                    -o -iname '*.wmv' -o -iname '*.webm' -o -iname '*.ts' -o -iname '*.m4v' \
                    -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.3gp' -o -iname '*.rmvb' \
                    -o -iname '*.vob' -o -iname '*.mts' -o -iname '*.m2ts' \) \
                 ! -name '*.converted.*' -print0 | sort -z)
    else
        TOTAL=$((TOTAL+1)); to_mp4 "$input"
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run 结束，共 $TOTAL 个文件待处理"
else
    log "全部结束：共 $TOTAL 个，成功 $OK，失败 $FAIL"
fi
[ "$FAIL" -eq 0 ]
