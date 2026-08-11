#!/usr/bin/env bash
set -Eeuo pipefail

DOWNLOAD_URL="${1:-${EZOPWRT_URL:-}}"
if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "Error: 请提供 EzOpWrt .img.gz/.img.xz/.img.zip 直链。" >&2
  echo "sirpdboy/openwrt 当前没有可下载的 GitHub Release，无法安全地自动猜测固件地址。" >&2
  exit 1
fi

rm -rf imm
mkdir -p imm
url_path="${DOWNLOAD_URL%%\?*}"
filename="$(basename "$url_path")"
OUTPUT_PATH="imm/$filename"

echo "下载地址: $DOWNLOAD_URL"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$OUTPUT_PATH" "$DOWNLOAD_URL"
echo "下载ezopwrt成功!"
file "$OUTPUT_PATH"

extension="${filename##*.}"
extension="${extension,,}"
case "$extension" in
  gz)
    gzip_log="$(mktemp)"
    trap 'rm -f "$gzip_log"' EXIT
    if ! gzip -t "$OUTPUT_PATH" 2>"$gzip_log"; then
      if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
        cat "$gzip_log" >&2
        exit 1
      fi
      echo "警告：上游 gzip 包含可忽略的 trailing garbage，继续提取有效镜像。" >&2
    fi
    if ! gzip -dc "$OUTPUT_PATH" > imm/ezopwrt.img 2>"$gzip_log"; then
      if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
        cat "$gzip_log" >&2
        exit 1
      fi
    fi
    ;;
  xz)
    xz -t "$OUTPUT_PATH"
    xz -dc "$OUTPUT_PATH" > imm/ezopwrt.img
    ;;
  zip)
    unzip -j -o "$OUTPUT_PATH" -d imm/
    final_name="$(find imm -maxdepth 1 -type f -name '*.img' -print -quit)"
    [[ -n "$final_name" ]] || { echo "Error: zip 中没有 .img 文件" >&2; exit 1; }
    mv -f -- "$final_name" imm/ezopwrt.img
    ;;
  *)
    echo "Error: 不支持的压缩格式: $extension" >&2
    exit 1
    ;;
esac

test -s imm/ezopwrt.img
file imm/ezopwrt.img
ls -lh imm/
echo "准备合成 EzOpWrt 安装器"

if [[ "${EZOPWRT_SKIP_DOCKER:-0}" == "1" ]]; then
  echo "EZOPWRT_SKIP_DOCKER=1，已完成固件下载、解压和校验。"
  exit 0
fi

mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
  -v "${repo_root}/output:/output" \
  -v "${repo_root}/supportFiles:/supportFiles:ro" \
  -v "${repo_root}/imm/ezopwrt.img:/mnt/ezopwrt.img:ro" \
  debian:buster \
  /supportFiles/ezopwrt/build.sh
