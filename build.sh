#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p armbian

# The upstream repository publishes the x86 images as release assets.  Keep the
# profile names stable for the workflow while resolving the actual asset from
# the newest release that contains a matching image.
VERSION_TYPE="${VERSION_TYPE:-standard}"
ARMBIAN_RELEASE="${ARMBIAN_RELEASE:-latest}"
ARMBIAN_REPO="${ARMBIAN_REPO:-wukongdaily/img-installer}"
OUTPUT_PATH="armbian/armbian.img.xz"

case "$VERSION_TYPE" in
  standard)
    PROFILE_DESCRIPTION="standard x86 UEFI"
    PROFILE_REGEX='_Uefi-x86_[^_]+_current_[^_]+\.img\.xz$'
    ;;
  debian12_minimal)
    PROFILE_DESCRIPTION="Debian 12 minimal x86 UEFI"
    PROFILE_REGEX='_Uefi-x86_bookworm_current_[0-9][0-9.]*_minimal\.img\.xz$'
    ;;
  ubuntu24_minimal)
    PROFILE_DESCRIPTION="Ubuntu 24 minimal x86 UEFI"
    PROFILE_REGEX='_Uefi-x86_noble_current_.*_minimal\.img\.xz$'
    ;;
  homeassistant_debian12_minimal)
    PROFILE_DESCRIPTION="Home Assistant Debian 12 minimal x86 UEFI"
    PROFILE_REGEX='_Uefi-x86_bookworm_current_.*homeassistant_minimal\.img\.xz$'
    ;;
  *)
    echo "错误：不支持的 VERSION_TYPE: $VERSION_TYPE" >&2
    exit 1
    ;;
esac

API_BASE="https://api.github.com/repos/${ARMBIAN_REPO}"

api_get() {
  local url="$1"
  local -a headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
  fi

  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "${headers[@]}" "$url"
}

asset_from_release() {
  jq -r --arg pattern "$PROFILE_REGEX" \
    '[.assets[]? | select(.name | test($pattern; "i")) | [.name, .browser_download_url]] | .[0] // empty | @tsv'
}

asset_from_release_list() {
  jq -r --arg pattern "$PROFILE_REGEX" \
    '[.[] | .assets[]? | select(.name | test($pattern; "i")) | [.name, .browser_download_url]] | .[0] // empty | @tsv'
}

selected_asset=""
selected_release="$ARMBIAN_RELEASE"

if [[ "$ARMBIAN_RELEASE" == "latest" ]]; then
  # GitHub returns releases newest-first.  Paginate so this keeps working even
  # after the upstream project has more than 100 releases.
  for page in $(seq 1 10); do
    release_list="$(api_get "${API_BASE}/releases?per_page=100&page=${page}")"
    selected_asset="$(printf '%s' "$release_list" | asset_from_release_list)"
    if [[ -n "$selected_asset" ]]; then
      selected_release="$(printf '%s' "$release_list" | jq -r --arg pattern "$PROFILE_REGEX" \
        '[.[] | select([.assets[]?.name | test($pattern; "i")] | any) | .tag_name] | .[0] // empty')"
      break
    fi
    [[ "$(printf '%s' "$release_list" | jq 'length')" -lt 100 ]] && break
  done
else
  encoded_release="$(jq -rn --arg value "$ARMBIAN_RELEASE" '$value | @uri')"
  release_json="$(api_get "${API_BASE}/releases/tags/${encoded_release}")"
  selected_asset="$(printf '%s' "$release_json" | asset_from_release)"
fi

if [[ -z "$selected_asset" ]]; then
  echo "错误：上游 ${ARMBIAN_REPO} 没有找到匹配 ${PROFILE_DESCRIPTION} 的 .img.xz 固件" >&2
  echo "VERSION_TYPE=$VERSION_TYPE, ARMBIAN_RELEASE=$ARMBIAN_RELEASE" >&2
  exit 1
fi

IFS=$'\t' read -r file_name download_url <<< "$selected_asset"
if [[ -z "$file_name" || -z "$download_url" ]]; then
  echo "错误：上游返回的固件资产信息不完整" >&2
  exit 1
fi

echo "上游仓库: ${ARMBIAN_REPO}"
echo "上游 Release: ${selected_release}"
echo "固件类型: ${PROFILE_DESCRIPTION}"
echo "固件文件: ${file_name}"
echo "下载地址: ${download_url}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'ARMBIAN_SELECTED_RELEASE=%s\n' "$selected_release" >> "$GITHUB_ENV"
  printf 'ARMBIAN_SELECTED_ASSET=%s\n' "$file_name" >> "$GITHUB_ENV"
fi

if [[ "${ARMBIAN_RESOLVE_ONLY:-0}" == "1" ]]; then
  echo "ARMBIAN_RESOLVE_ONLY=1，跳过下载和 ISO 构建。"
  exit 0
fi

rm -f armbian/armbian.img armbian/armbian.img.xz
curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$OUTPUT_PATH" "$download_url"
xz -t "$OUTPUT_PATH"
xz -d -f "$OUTPUT_PATH"
test -s armbian/armbian.img
file armbian/armbian.img

if [[ "${ARMBIAN_SKIP_DOCKER:-0}" == "1" ]]; then
  echo "ARMBIAN_SKIP_DOCKER=1，已完成固件解析、下载和校验。"
  exit 0
fi

echo "准备合成 Armbian 安装器"
mkdir -p output
repo_root="$(pwd -P)"
docker run --privileged --rm \
  -v "${repo_root}/output:/output" \
  -v "${repo_root}/supportFiles:/supportFiles:ro" \
  -v "${repo_root}/armbian/armbian.img:/mnt/armbian.img:ro" \
  debian:buster \
  /supportFiles/build.sh
