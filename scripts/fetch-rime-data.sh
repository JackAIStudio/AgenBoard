#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
RIME_DATA_DIRECTORY="${PROJECT_DIRECTORY}/AgenBoardKeyboard/RimeData"
PREBUILT_DIRECTORY="${RIME_DATA_DIRECTORY}/Prebuilt"
LOCK_FILE="${PROJECT_DIRECTORY}/rime-data.lock.plist"
CHECKSUM_FILE="${PROJECT_DIRECTORY}/rime-data.sha256"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/agenboard-rime-fetch.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIRECTORY}"
}
trap cleanup EXIT

read_lock_value() {
  /usr/bin/plutil -extract "$1" raw -o - "${LOCK_FILE}"
}

REPOSITORY="$(read_lock_value repository)"
RELEASE_TAG="$(read_lock_value release_tag)"
ASSET_NAME="$(read_lock_value asset_name)"
EXPECTED_ARCHIVE_SHA256="$(read_lock_value archive_sha256)"
ARCHIVE_PATH="${WORK_DIRECTORY}/${ASSET_NAME}"

downloaded_with_gh=false
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh release download "${RELEASE_TAG}" \
    --repo "${REPOSITORY}" \
    --pattern "${ASSET_NAME}" \
    --dir "${WORK_DIRECTORY}"; then
    downloaded_with_gh=true
  fi
fi

if [[ "${downloaded_with_gh}" != true ]]; then
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ASSET_NAME}" \
    --output "${ARCHIVE_PATH}"
fi

ACTUAL_ARCHIVE_SHA256="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
if [[ "${ACTUAL_ARCHIVE_SHA256}" != "${EXPECTED_ARCHIVE_SHA256}" ]]; then
  printf 'Rime 数据包 SHA-256 不匹配。\n' >&2
  exit 1
fi

EXTRACTION_DIRECTORY="${WORK_DIRECTORY}/extracted"
mkdir -p "${EXTRACTION_DIRECTORY}"
/usr/bin/unzip -q "${ARCHIVE_PATH}" -d "${EXTRACTION_DIRECTORY}"

(
  cd "${EXTRACTION_DIRECTORY}"
  shasum -a 256 -c "${CHECKSUM_FILE}"
)

mkdir -p "${PREBUILT_DIRECTORY}"
for artifact in \
  agenboard_pinyin.prism.bin \
  agenboard_pinyin.schema.yaml \
  default.yaml \
  rime_ice.reverse.bin \
  rime_ice.table.bin; do
  install -m 0644 \
    "${EXTRACTION_DIRECTORY}/Prebuilt/${artifact}" \
    "${PREBUILT_DIRECTORY}/${artifact}"
done

printf 'Rime 数据已安装：%s\n' "${PREBUILT_DIRECTORY}"
