#!/usr/bin/env bash
set -Eeuo pipefail

REPO="sirpdboy/openwrt"
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
OUTPUT_PATH="imm/ezopwrt.img.gz"

if [ -z "$DOWNLOAD_URLS" ]; then
  echo "Error: No .img.gz files found under tag $TAG"
  exit 1
fi

FIRST_DOWNLOAD_URL=$(printf '%s\n' "$DOWNLOAD_URLS" | head -n1)
echo "下载地址: $FIRST_DOWNLOAD_URL"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$OUTPUT_PATH" "$FIRST_DOWNLOAD_URL"
echo "下载ezopwrt成功!"
file imm/ezopwrt.img.gz
echo "正在解压为:ezopwrt.img"
gzip -t imm/ezopwrt.img.gz
gzip -d -f imm/ezopwrt.img.gz
test -s imm/ezopwrt.img
ls -lh imm/
echo "准备合成 EzOpWrt 安装器"

mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
        -v "${repo_root}/output:/output" \
        -v "${repo_root}/supportFiles:/supportFiles:ro" \
        -v "${repo_root}/imm/ezopwrt.img:/mnt/ezopwrt.img:ro" \
        debian:buster \
        /supportFiles/ezopwrt/build.sh
