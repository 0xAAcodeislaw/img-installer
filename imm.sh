#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p imm

REPO="${IMMORTALWRT_REPO:-wukongdaily/AutoBuildImmortalWrt}"
RELEASE_TAG="${IMMORTALWRT_RELEASE:-Autobuild-x86-64}"
VERSION="${IMMORTALWRT_VERSION:-latest}"
API_BASE="https://api.github.com/repos/${REPO}"
OUTPUT_PATH="imm/immortalwrt.img.gz"

api_get() {
  local url="$1"
  local -a headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "${headers[@]}" "$url"
}

encoded_release="$(jq -rn --arg value "$RELEASE_TAG" '$value | @uri')"
release_json="$(api_get "${API_BASE}/releases/tags/${encoded_release}")"

if [[ "$VERSION" == "latest" ]]; then
  file_name="$(printf '%s' "$release_json" | jq -r '
    .assets[]?.name | select(test("^immortalwrt-[0-9][0-9A-Za-z.+~-]*-x86-64-generic-squashfs-combined-efi\\.img\\.gz$"))' | sort -V | tail -n 1)"
else
  file_name="immortalwrt-${VERSION}-x86-64-generic-squashfs-combined-efi.img.gz"
  if ! printf '%s' "$release_json" | jq -e --arg name "$file_name" '.assets[]? | select(.name == $name)' >/dev/null; then
    file_name=""
  fi
fi

if [[ -z "$file_name" ]]; then
  echo "错误：Release ${RELEASE_TAG} 中没有找到 ImmortalWrt x86-64 EFI 固件（版本：${VERSION}）" >&2
  exit 1
fi

download_url="$(printf '%s' "$release_json" | jq -r --arg name "$file_name" '.assets[] | select(.name == $name) | .browser_download_url')"
echo "上游仓库: ${REPO}"
echo "上游 Release: ${RELEASE_TAG}"
echo "固件文件: ${file_name}"
echo "下载地址: ${download_url}"

rm -f imm/immortalwrt.img imm/immortalwrt.img.gz
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$OUTPUT_PATH" "$download_url"
gzip_log="$(mktemp)"
trap 'rm -f "$gzip_log"' EXIT
if ! gzip -t "$OUTPUT_PATH" 2>"$gzip_log"; then
  if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
    cat "$gzip_log" >&2
    exit 1
  fi
  echo "警告：上游 gzip 包含可忽略的 trailing garbage，继续提取有效镜像。" >&2
fi
if ! gzip -dc "$OUTPUT_PATH" > imm/immortalwrt.img 2>"$gzip_log"; then
  if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
    cat "$gzip_log" >&2
    exit 1
  fi
fi
test -s imm/immortalwrt.img
file imm/immortalwrt.img

if [[ "${IMMORTALWRT_SKIP_DOCKER:-0}" == "1" ]]; then
  echo "IMMORTALWRT_SKIP_DOCKER=1，已完成固件解析、下载和校验。"
  exit 0
fi

echo "准备合成 ImmortalWrt 安装器"
mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
  -v "${repo_root}/output:/output" \
  -v "${repo_root}/supportFiles:/supportFiles:ro" \
  -v "${repo_root}/imm/immortalwrt.img:/mnt/immortalwrt.img:ro" \
  debian:buster \
  /supportFiles/immortalwrt/build.sh
