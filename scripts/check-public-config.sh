#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
PROJECT_FILE="${PROJECT_DIRECTORY}/AgenBoard.xcodeproj/project.pbxproj"
PUBLIC_CONFIG="${PROJECT_DIRECTORY}/Config/Shared.xcconfig"
LOCAL_CONFIG_EXAMPLE="${PROJECT_DIRECTORY}/Config/Local.xcconfig.example"
GITIGNORE="${PROJECT_DIRECTORY}/.gitignore"
KEYBOARD_SCHEME="${PROJECT_DIRECTORY}/AgenBoard.xcodeproj/xcshareddata/xcschemes/AgenBoardKeyboard.xcscheme"

fail() {
  printf '公开配置检查失败：%s\n' "$1" >&2
  exit 1
}

if git -C "${PROJECT_DIRECTORY}" show \
  ':AgenBoard.xcodeproj/project.pbxproj' | \
  grep -Eq 'DEVELOPMENT_TEAM[[:space:]]*='; then
  fail 'Git 暂存区中的 project.pbxproj 包含 target 级 Team。默认 Team 只能集中定义在 Shared.xcconfig。'
fi

unexpected_bundle_settings="$({
  grep 'PRODUCT_BUNDLE_IDENTIFIER' "${PROJECT_FILE}" || true
} | grep -Ev '\$\(AGENBOARD_(APP|KEYBOARD)_BUNDLE_IDENTIFIER\)' || true)"
if [[ -n "${unexpected_bundle_settings}" ]]; then
  fail 'project.pbxproj 中的 Bundle ID 必须引用公共配置变量。'
fi

if ! grep -Fqx 'AGENBOARD_IDENTIFIER_SUFFIX = $(DEVELOPMENT_TEAM)' \
  "${PUBLIC_CONFIG}"; then
  fail '真机标识符必须由最终生效的 DEVELOPMENT_TEAM 自动派生。'
fi

default_team_count="$(
  grep -Ec '^DEVELOPMENT_TEAM = [A-Z0-9]{10}$' "${PUBLIC_CONFIG}" || true
)"
all_team_count="$(
  grep -Ec '^DEVELOPMENT_TEAM[[:space:]]*=' "${PUBLIC_CONFIG}" || true
)"
if [[ "${default_team_count}" != "1" || "${all_team_count}" != "1" ]]; then
  fail 'Shared.xcconfig 必须且只能包含一个 10 位公开默认 Team。'
fi

if ! grep -Fqx '#include? "Local.xcconfig"' "${PUBLIC_CONFIG}"; then
  fail 'Shared.xcconfig 必须可选加载 Local.xcconfig。'
fi

default_team_line="$(
  grep -n -m 1 '^DEVELOPMENT_TEAM[[:space:]]*=' "${PUBLIC_CONFIG}" | cut -d: -f1
)"
local_include_line="$(
  grep -n -m 1 -F '#include? "Local.xcconfig"' "${PUBLIC_CONFIG}" | cut -d: -f1
)"
if (( local_include_line <= default_team_line )); then
  fail 'Local.xcconfig 必须在公开默认 Team 之后加载，确保本地设置可以覆盖默认值。'
fi

if ! grep -Fqx '/Config/Local.xcconfig' "${GITIGNORE}"; then
  fail 'Config/Local.xcconfig 必须被 Git 忽略。'
fi

if git -C "${PROJECT_DIRECTORY}" ls-files --error-unmatch \
  'Config/Local.xcconfig' >/dev/null 2>&1; then
  fail 'Config/Local.xcconfig 是本地文件，不得加入版本控制。'
fi

if ! grep -Fqx 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' \
  "${LOCAL_CONFIG_EXAMPLE}"; then
  fail 'Local.xcconfig.example 必须保留 Team ID 占位符。'
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
