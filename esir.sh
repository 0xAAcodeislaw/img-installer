#!/usr/bin/env bash
set -Eeuo pipefail

REPO="wkccd/esirOpenWrt"
api_base="https://api.github.com/repos/$REPO"
TAG=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$api_base/releases/latest" | jq -r '.tag_name // empty')
if [[ -z "$TAG" ]]; then
  TAG=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$api_base/tags" | jq -r '.[0].name // empty')
fi
[ -n "$TAG" ] || { echo "Error: no release or tag found for $REPO" >&2; exit 1; }
echo "最新TAG: $TAG"
# 获取该 Tag 下所有以 .img.gz 结尾的文件
DOWNLOAD_URLS=$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$api_base/releases/tags/$TAG" \
  | jq -r '.assets[] | select(.name | endswith("img.gz")) | .browser_download_url')
# 保存位置
mkdir -p imm
OUTPUT_PATH="imm/esiropenwrt.img.gz"

if [ -z "$DOWNLOAD_URLS" ]; then
  echo "Error: No .img.gz files found under tag $TAG"
  exit 1
fi

FIRST_DOWNLOAD_URL=$(printf '%s\n' "$DOWNLOAD_URLS" | head -n1)
echo "下载地址: $FIRST_DOWNLOAD_URL"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$OUTPUT_PATH" "$FIRST_DOWNLOAD_URL"
echo "下载esiropenwrt成功!"
file imm/esiropenwrt.img.gz
echo "正在解压为:esiropenwrt.img"
gzip_log="$(mktemp)"
trap 'rm -f "$gzip_log"' EXIT
if ! gzip -t imm/esiropenwrt.img.gz 2>"$gzip_log"; then
  if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
    cat "$gzip_log" >&2
    exit 1
  fi
  echo "警告：上游 gzip 包含可忽略的 trailing garbage，继续提取有效镜像。" >&2
fi
if ! gzip -dc imm/esiropenwrt.img.gz > imm/esiropenwrt.img 2>"$gzip_log"; then
  if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
    cat "$gzip_log" >&2
    exit 1
  fi
fi
test -s imm/esiropenwrt.img
ls -lh imm/
echo "准备合成 eSirOpenWrt 安装器"

mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
        -v "${repo_root}/output:/output" \
        -v "${repo_root}/supportFiles:/supportFiles:ro" \
        -v "${repo_root}/imm/esiropenwrt.img:/mnt/esiropenwrt.img:ro" \
        debian:buster \
        /supportFiles/esirplayground/build.sh
