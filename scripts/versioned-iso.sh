#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $# -lt 2 ]]; then
  echo "用法: $0 <iso-path> <upstream-version-or-asset>" >&2
  exit 2
fi

SOURCE_ISO="$1"
VERSION_SOURCE="$2"

if [[ ! -s "$SOURCE_ISO" ]]; then
  echo "错误：ISO 不存在或为空：$SOURCE_ISO" >&2
  exit 1
fi

# Release 标签或固件资产名通常包含 vX.Y.Z、X.Y.Z 或日期版本。
raw_source="${VERSION_SOURCE%%\?*}"
raw_source="$(basename "$raw_source")"
version="$(printf '%s' "$raw_source" | grep -oE 'v?[0-9]+([._-][0-9]+){1,}' | head -n 1 || true)"

if [[ -z "$version" ]]; then
  # 手工直链没有规范版本号时，保留其文件名作为标识；再无信息则使用 UTC 构建日期。
  version="${raw_source%.img.gz}"
  version="${version%.img.xz}"
  version="${version%.img.zip}"
  version="${version%.gz}"
  version="${version%.xz}"
  version="${version%.zip}"
fi

version="$(printf '%s' "$version" | sed -E 's/[^[:alnum:]_.-]+/-/g; s/-+/-/g; s/^[._-]+//; s/[._-]+$//')"
if [[ -z "$version" || "$version" == "latest" || "$version" == "manual" ]]; then
  version="manual-$(date -u +%Y%m%d)"
fi

target="${SOURCE_ISO%.iso}-${version}.iso"
mv -f -- "$SOURCE_ISO" "$target"
echo "已生成带版本号的 ISO：$target"
printf 'VERSIONED_ISO=%s\n' "$target" >> "${GITHUB_ENV:-/dev/null}"
