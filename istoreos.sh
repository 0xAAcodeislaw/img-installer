#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p openwrt

REPO="${ISTOREOS_REPO:-wukongdaily/img-installer}"
UPSTREAM_RELEASE="${ISTOREOS_RELEASE:-latest}"
API_BASE="https://api.github.com/repos/${REPO}"
OUTPUT_PATH="openwrt/istoreos.img.gz"
PROFILE_REGEX='^istoreos-.*-x86-64-squashfs-combined-efi\.img\.gz$'

api_get() {
  local url="$1"
  local -a headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  [[ -n "${GITHUB_TOKEN:-}" ]] && headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "${headers[@]}" "$url"
}

selected_asset=""
selected_release="$UPSTREAM_RELEASE"
if [[ "$UPSTREAM_RELEASE" == "latest" ]]; then
  for page in $(seq 1 10); do
    release_list="$(api_get "${API_BASE}/releases?per_page=100&page=${page}")"
    selected_name="$(printf '%s' "$release_list" | jq -r --arg pattern "$PROFILE_REGEX" \
      '.[] | .assets[]? | select(.name | test($pattern; "i")) | .name' | LC_ALL=C sort -V | tail -n 1)"
    if [[ -n "$selected_name" ]]; then
      selected_release="$(printf '%s' "$release_list" | jq -r --arg pattern "$PROFILE_REGEX" '
        [.[] | select([.assets[]?.name | test($pattern; "i")] | any) | .tag_name]
        | .[0] // empty')"
      selected_asset="$(printf '%s' "$release_list" | jq -r --arg name "$selected_name" \
        '.[] | .assets[]? | select(.name == $name) | [.name, .browser_download_url] | @tsv' | head -n 1)"
      break
    fi
    [[ "$(printf '%s' "$release_list" | jq 'length')" -lt 100 ]] && break
  done
else
  encoded_release="$(jq -rn --arg value "$UPSTREAM_RELEASE" '$value | @uri')"
  release_json="$(api_get "${API_BASE}/releases/tags/${encoded_release}")"
  selected_name="$(printf '%s' "$release_json" | jq -r --arg pattern "$PROFILE_REGEX" \
    '.assets[]? | select(.name | test($pattern; "i")) | .name' | LC_ALL=C sort -V | tail -n 1)"
  if [[ -n "$selected_name" ]]; then
    selected_asset="$(printf '%s' "$release_json" | jq -r --arg name "$selected_name" \
      '.assets[]? | select(.name == $name) | [.name, .browser_download_url] | @tsv')"
  fi
fi

if [[ -z "$selected_asset" ]]; then
  echo "错误：上游 ${REPO} 没有找到 iStoreOS x86-64 EFI 固件" >&2
  echo "ISTOREOS_RELEASE=${UPSTREAM_RELEASE}" >&2
  exit 1
fi

IFS=$'\t' read -r file_name download_url <<< "$selected_asset"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'ISTOREOS_SELECTED_RELEASE=%s\n' "$selected_release"
    printf 'ISTOREOS_SELECTED_ASSET=%s\n' "$file_name"
  } >> "$GITHUB_ENV"
fi
echo "上游仓库: ${REPO}"
echo "上游 Release: ${selected_release}"
echo "固件文件: ${file_name}"
echo "下载地址: ${download_url}"

rm -f openwrt/istoreos.img openwrt/istoreos.img.gz
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
if ! gzip -dc "$OUTPUT_PATH" > openwrt/istoreos.img 2>"$gzip_log"; then
  if ! grep -qi 'trailing garbage ignored' "$gzip_log"; then
    cat "$gzip_log" >&2
    exit 1
  fi
fi
test -s openwrt/istoreos.img
file openwrt/istoreos.img

if [[ "${ISTOREOS_SKIP_DOCKER:-0}" == "1" ]]; then
  echo "ISTOREOS_SKIP_DOCKER=1，已完成固件解析、下载和校验。"
  exit 0
fi

echo "准备合成 iStoreOS 安装器"
mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
  -v "${repo_root}/output:/output" \
  -v "${repo_root}/supportFiles:/supportFiles:ro" \
  -v "${repo_root}/openwrt/istoreos.img:/mnt/istoreos.img:ro" \
  debian:buster \
  /supportFiles/istoreos/build.sh
