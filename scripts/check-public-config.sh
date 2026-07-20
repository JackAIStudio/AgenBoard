#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
PROJECT_FILE="${PROJECT_DIRECTORY}/AgenBoard.xcodeproj/project.pbxproj"
PUBLIC_CONFIG="${PROJECT_DIRECTORY}/Config/Shared.xcconfig"
KEYBOARD_SCHEME="${PROJECT_DIRECTORY}/AgenBoard.xcodeproj/xcshareddata/xcschemes/AgenBoardKeyboard.xcscheme"

fail() {
  printf '公开配置检查失败：%s\n' "$1" >&2
  exit 1
}

if git -C "${PROJECT_DIRECTORY}" show \
  ':AgenBoard.xcodeproj/project.pbxproj' | \
  grep -Eq 'DEVELOPMENT_TEAM[[:space:]]*='; then
  fail 'Git 暂存区中的 project.pbxproj 包含个人 Team。请取消暂存该签名改动。'
fi

unexpected_bundle_settings="$({
  grep 'PRODUCT_BUNDLE_IDENTIFIER' "${PROJECT_FILE}" || true
} | grep -Ev '\$\(AGENBOARD_(APP|KEYBOARD)_BUNDLE_IDENTIFIER\)' || true)"
if [[ -n "${unexpected_bundle_settings}" ]]; then
  fail 'project.pbxproj 中的 Bundle ID 必须引用公共配置变量。'
fi

if ! grep -Fqx 'AGENBOARD_IDENTIFIER_SUFFIX = $(DEVELOPMENT_TEAM)' \
  "${PUBLIC_CONFIG}"; then
  fail '真机标识符必须由 Xcode 中选择的 DEVELOPMENT_TEAM 自动派生。'
fi

if grep -Eq 'Local\.xcconfig|#include\?' "${PUBLIC_CONFIG}"; then
  fail '公共配置不应依赖额外的本地配置文件。'
fi

for expected_setting in \
  'AGENBOARD_APP_BUNDLE_IDENTIFIER = dev.agenboard.$(AGENBOARD_IDENTIFIER_SUFFIX)' \
  'AGENBOARD_KEYBOARD_BUNDLE_IDENTIFIER = dev.agenboard.$(AGENBOARD_IDENTIFIER_SUFFIX).keyboard' \
  'AGENBOARD_APP_GROUP_IDENTIFIER = group.dev.agenboard.$(AGENBOARD_IDENTIFIER_SUFFIX)'; do
  if ! grep -Fqx "${expected_setting}" "${PUBLIC_CONFIG}"; then
    fail 'Bundle ID 与 App Group 必须由统一的 Team 后缀派生。'
  fi
done

for entitlement in \
  "${PROJECT_DIRECTORY}/AgenBoard/AgenBoard.entitlements" \
  "${PROJECT_DIRECTORY}/AgenBoardKeyboard/AgenBoardKeyboard.entitlements"; do
  if ! grep -Fq '$(AGENBOARD_APP_GROUP_IDENTIFIER)' "${entitlement}"; then
    fail "$(basename "${entitlement}") 必须引用 App Group 配置变量。"
  fi
done

if grep -Fq 'BundleIdentifier = "dev.local.agenboard"' "${KEYBOARD_SCHEME}"; then
  fail '键盘调试 Scheme 仍引用旧的主 App Bundle ID。'
fi

if ! grep -Fq 'BundleIdentifier = "com.apple.mobilesafari"' \
  "${KEYBOARD_SCHEME}"; then
  fail '键盘调试 Scheme 必须使用稳定的系统宿主 App。'
fi

printf '公开签名配置检查通过。\n'
