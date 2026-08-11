#!/usr/bin/env bash
set -Eeuo pipefail

# 校验参数是否存在
if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "❌ 错误：未提供下载地址或 latest！"
  exit 1
fi

rm -rf imm
mkdir -p imm
DOWNLOAD_URL="$1"
SELECTED_RELEASE="manual"

# 支持使用 latest 自动跟踪 Home Assistant OS 官方最新稳定版。
# GitHub 的 /releases/latest 接口不会返回预发布版本，适合用于默认构建。
if [[ "$DOWNLOAD_URL" == "latest" ]]; then
  API_URL="https://api.github.com/repos/home-assistant/operating-system/releases/latest"
  release_json="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$API_URL")" || {
      echo "❌ 获取 Home Assistant OS 最新 Release 失败！" >&2
      exit 1
    }

  SELECTED_RELEASE="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')"
  DOWNLOAD_URL="$(printf '%s' "$release_json" | jq -r '
    [.assets[]?
      | select(.name | test("^haos_generic-x86-64-.*\\.img\\.(gz|xz|zip)$"))
      | .browser_download_url]
    | .[0] // empty')"

  if [[ -z "$SELECTED_RELEASE" || -z "$DOWNLOAD_URL" ]]; then
    echo "❌ 最新 HAOS Release 中没有找到 haos_generic-x86-64 压缩镜像！" >&2
    exit 1
  fi

  echo "上游 Release: $SELECTED_RELEASE"
fi

url_path="${DOWNLOAD_URL%%\?*}"
filename=$(basename "$url_path")
OUTPUT_PATH="imm/$filename"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'HAOS_SELECTED_RELEASE=%s\n' "$SELECTED_RELEASE"
    printf 'HAOS_SELECTED_ASSET=%s\n' "$filename"
  } >> "$GITHUB_ENV"
fi

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
    gunzip -f "$OUTPUT_PATH"
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
mv -f -- "$final_name" imm/haos.img


# 检查最终文件
if [ -f "imm/haos.img" ]; then
  echo "✅ 解压成功"
  ls -lh imm/
  echo "✅ 准备合成 自定义HAOS 安装器"
else
  echo "❌ 错误：最终文件 imm/haos.img 不存在"
  exit 1
fi

mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
    -v "${repo_root}/output:/output" \
    -v "${repo_root}/supportFiles:/supportFiles:ro" \
    -v "${repo_root}/imm/haos.img:/mnt/haos.img:ro" \
        debian:buster \
        /supportFiles/haos/build.sh
