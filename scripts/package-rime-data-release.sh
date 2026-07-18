#!/usr/bin/env bash

set -euo pipefail

RIME_DATA_RELEASE="rime-data-v1"
RIME_ICE_REVISION="07eca7256d0bae6948dcf3838e14910dbe3b00be"

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
RIME_DATA_DIRECTORY="${PROJECT_DIRECTORY}/AgenBoardKeyboard/RimeData"
PREBUILT_DIRECTORY="${RIME_DATA_DIRECTORY}/Prebuilt"
OUTPUT_DIRECTORY="${1:-${PROJECT_DIRECTORY}/build/rime-release}"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/agenboard-rime-package.XXXXXX")"
BINARY_ROOT="${WORK_DIRECTORY}/binary"
SOURCE_ROOT="${WORK_DIRECTORY}/source"

cleanup() {
  rm -rf "${WORK_DIRECTORY}"
}
trap cleanup EXIT

mkdir -p \
  "${BINARY_ROOT}/Prebuilt" \
  "${BINARY_ROOT}/LICENSES" \
  "${SOURCE_ROOT}/agenboard" \
  "${SOURCE_ROOT}/scripts" \
  "${SOURCE_ROOT}/upstream" \
  "${SOURCE_ROOT}/LICENSES" \
  "${OUTPUT_DIRECTORY}"

for artifact in \
  agenboard_pinyin.prism.bin \
  agenboard_pinyin.schema.yaml \
  default.yaml \
  rime_ice.reverse.bin \
  rime_ice.table.bin; do
  test -f "${PREBUILT_DIRECTORY}/${artifact}"
  cp -p \
    "${PREBUILT_DIRECTORY}/${artifact}" \
    "${BINARY_ROOT}/Prebuilt/${artifact}"
done

cp -p \
  "${RIME_DATA_DIRECTORY}/README.md" \
  "${RIME_DATA_DIRECTORY}/default.yaml" \
  "${RIME_DATA_DIRECTORY}/agenboard_pinyin.schema.yaml" \
  "${SOURCE_ROOT}/agenboard/"
cp -p \
  "${SCRIPT_DIRECTORY}/build-rime-data.sh" \
  "${SCRIPT_DIRECTORY}/fetch-rime-data.sh" \
  "${SCRIPT_DIRECTORY}/package-rime-data-release.sh" \
  "${SCRIPT_DIRECTORY}/rime-smoke-test.cc" \
  "${SOURCE_ROOT}/scripts/"

curl --fail --location --silent --show-error \
  "https://raw.githubusercontent.com/iDvel/rime-ice/${RIME_ICE_REVISION}/LICENSE" \
  --output "${BINARY_ROOT}/LICENSES/Rime-Ice-GPL-3.0.txt"
cp -p \
  "${BINARY_ROOT}/LICENSES/Rime-Ice-GPL-3.0.txt" \
  "${SOURCE_ROOT}/LICENSES/Rime-Ice-GPL-3.0.txt"
curl --fail --location --silent --show-error \
  "https://github.com/iDvel/rime-ice/archive/${RIME_ICE_REVISION}.tar.gz" \
  --output "${SOURCE_ROOT}/upstream/rime-ice-${RIME_ICE_REVISION}.tar.gz"

find "${BINARY_ROOT}" "${SOURCE_ROOT}" -type f -exec touch -t 202601010000 {} +

BINARY_ARCHIVE="${WORK_DIRECTORY}/agenboard-rime-data-v1.zip"
SOURCE_ARCHIVE="${WORK_DIRECTORY}/agenboard-rime-data-v1-source.zip"
(
  cd "${BINARY_ROOT}"
  find . -type f -print | LC_ALL=C sort | \
    /usr/bin/zip -X -q -9 "${BINARY_ARCHIVE}" -@
)
(
  cd "${SOURCE_ROOT}"
  find . -type f -print | LC_ALL=C sort | \
    /usr/bin/zip -X -q -9 "${SOURCE_ARCHIVE}" -@
)

install -m 0644 \
  "${BINARY_ARCHIVE}" \
  "${OUTPUT_DIRECTORY}/agenboard-rime-data-v1.zip"
install -m 0644 \
  "${SOURCE_ARCHIVE}" \
  "${OUTPUT_DIRECTORY}/agenboard-rime-data-v1-source.zip"

shasum -a 256 \
  "${OUTPUT_DIRECTORY}/agenboard-rime-data-v1.zip" \
  "${OUTPUT_DIRECTORY}/agenboard-rime-data-v1-source.zip"
printf 'Release 资源已生成：%s（%s）\n' \
  "${OUTPUT_DIRECTORY}" \
  "${RIME_DATA_RELEASE}"
