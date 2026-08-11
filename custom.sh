#!/usr/bin/env bash
set -Eeuo pipefail

# 校验参数是否存在
if [ -z "$1" ]; then
  echo "❌ 错误：未提供下载地址！"
  exit 1
fi

rm -rf imm
mkdir -p imm
DOWNLOAD_URL="$1"
url_path="${DOWNLOAD_URL%%\?*}"
filename=$(basename "$url_path")
OUTPUT_PATH="imm/$filename"

echo "下载地址: $DOWNLOAD_URL"
echo "保存路径: $OUTPUT_PATH"

# 下载文件
if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$OUTPUT_PATH" "$DOWNLOAD_URL"; then
  echo "❌ 下载失败！"
  exit 1
fi

echo "✅ 下载成功!"
file "$OUTPUT_PATH"

# 根据扩展名解压
extension="${filename##*.}"
extension="${extension,,}"
case "$extension" in
  gz)
    echo "gz正在解压$OUTPUT_PATH"
    gzip_log="$(mktemp)"
    trap 'rm -f "$gzip_log"' EXIT
    if ! gzip -t "$OUTPUT_PATH" 2>"$gzip_log"; then
      if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
        cat "$gzip_log" >&2
        exit 1
      fi
      echo "⚠️ 上游 gzip 包含可忽略的 trailing garbage，继续提取有效镜像。" >&2
    fi
    if ! gzip -dc "$OUTPUT_PATH" > imm/custom.img 2>"$gzip_log"; then
      if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
        cat "$gzip_log" >&2
        exit 1
      fi
    fi
    ;;
  zip)
    echo "zip正在解压$OUTPUT_PATH"
    unzip -j -o "$OUTPUT_PATH" -d imm/
    ;;
  xz)
    echo "xz正在解压$OUTPUT_PATH"
    xz -d -f "$OUTPUT_PATH"
    ;;
  *)
    echo "❌ 不支持的压缩格式: $extension"
    exit 1
    ;;
esac

final_name=$(find imm -maxdepth 1 -type f -name '*.img' -print -quit)
if [[ -z "$final_name" ]]; then
  echo "❌ 错误：压缩包中没有找到 .img 文件"
  exit 1
fi
if [[ "$final_name" != "imm/custom.img" ]]; then
  mv -f -- "$final_name" imm/custom.img
fi


# 检查最终文件
if [ -f "imm/custom.img" ]; then
  echo "✅ 解压成功"
  ls -lh imm/
  echo "✅ 准备合成 自定义OpenWrt 安装器"
else
  echo "❌ 错误：最终文件 imm/custom.img 不存在"
  exit 1
fi

mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
    -v "${repo_root}/output:/output" \
    -v "${repo_root}/supportFiles:/supportFiles:ro" \
    -v "${repo_root}/imm/custom.img:/mnt/custom.img:ro" \
    debian:buster \
    /supportFiles/custom/build.sh
