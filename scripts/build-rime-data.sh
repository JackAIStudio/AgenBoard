#!/usr/bin/env bash

set -euo pipefail

RIME_VERSION="1.16.1"
RIME_ARCHIVE="rime-de4700e-macOS-universal.tar.bz2"
RIME_ARCHIVE_SHA256="147dc220d20bcf2650889c98f943f1792b3c675dbef91f42f9151a216ad2c372"
RIME_ICE_REVISION="07eca7256d0bae6948dcf3838e14910dbe3b00be"

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd "${SCRIPT_DIRECTORY}/.." && pwd)"
RIME_DATA_DIRECTORY="${PROJECT_DIRECTORY}/AgenBoardKeyboard/RimeData"
WORK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/agenboard-rime-data.XXXXXX")"
SOURCE_DIRECTORY="${WORK_DIRECTORY}/source"
USER_DIRECTORY="${WORK_DIRECTORY}/user"
BUILD_DIRECTORY="${WORK_DIRECTORY}/build"
RIME_DIRECTORY="${WORK_DIRECTORY}/rime"
RIME_ICE_DIRECTORY="${WORK_DIRECTORY}/rime-ice"

mkdir -p \
  "${SOURCE_DIRECTORY}/cn_dicts" \
  "${USER_DIRECTORY}" \
  "${BUILD_DIRECTORY}" \
  "${RIME_DIRECTORY}"

curl --fail --location --silent --show-error \
  "https://github.com/rime/librime/releases/download/${RIME_VERSION}/${RIME_ARCHIVE}" \
  --output "${WORK_DIRECTORY}/${RIME_ARCHIVE}"
ACTUAL_RIME_ARCHIVE_SHA256="$(
  shasum -a 256 "${WORK_DIRECTORY}/${RIME_ARCHIVE}" | awk '{print $1}'
)"
if [[ "${ACTUAL_RIME_ARCHIVE_SHA256}" != "${RIME_ARCHIVE_SHA256}" ]]; then
  printf 'librime 下载文件 SHA-256 不匹配。\n' >&2
  exit 1
fi
tar -xjf "${WORK_DIRECTORY}/${RIME_ARCHIVE}" -C "${RIME_DIRECTORY}"

git clone --quiet https://github.com/iDvel/rime-ice.git "${RIME_ICE_DIRECTORY}"
git -C "${RIME_ICE_DIRECTORY}" checkout --quiet "${RIME_ICE_REVISION}"

cp "${RIME_DATA_DIRECTORY}/default.yaml" "${SOURCE_DIRECTORY}/default.yaml"
cp \
  "${RIME_DATA_DIRECTORY}/agenboard_pinyin.schema.yaml" \
  "${SOURCE_DIRECTORY}/agenboard_pinyin.schema.yaml"
cp \
  "${RIME_ICE_DIRECTORY}/rime_ice.dict.yaml" \
  "${SOURCE_DIRECTORY}/rime_ice.dict.yaml"

for dictionary in 8105 base ext tencent others; do
  cp \
    "${RIME_ICE_DIRECTORY}/cn_dicts/${dictionary}.dict.yaml" \
    "${SOURCE_DIRECTORY}/cn_dicts/${dictionary}.dict.yaml"
done

DYLD_LIBRARY_PATH="${RIME_DIRECTORY}/dist/lib" \
  "${RIME_DIRECTORY}/dist/bin/rime_deployer" \
  --build "${USER_DIRECTORY}" "${SOURCE_DIRECTORY}" "${BUILD_DIRECTORY}"

mkdir -p "${RIME_DATA_DIRECTORY}/Prebuilt"
for artifact in \
  agenboard_pinyin.prism.bin \
  agenboard_pinyin.schema.yaml \
  default.yaml \
  rime_ice.reverse.bin \
  rime_ice.table.bin; do
  install -m 0644 \
    "${BUILD_DIRECTORY}/${artifact}" \
    "${RIME_DATA_DIRECTORY}/Prebuilt/${artifact}"
done

clang++ -std=c++17 \
  "${SCRIPT_DIRECTORY}/rime-smoke-test.cc" \
  -I"${RIME_DIRECTORY}/dist/include" \
  -L"${RIME_DIRECTORY}/dist/lib" \
  -lrime \
  -o "${WORK_DIRECTORY}/rime-smoke-test"

SMOKE_USER_DIRECTORY="${WORK_DIRECTORY}/smoke-user"
mkdir -p "${SMOKE_USER_DIRECTORY}"
DYLD_LIBRARY_PATH="${RIME_DIRECTORY}/dist/lib" \
  "${WORK_DIRECTORY}/rime-smoke-test" \
  "${SOURCE_DIRECTORY}" \
  "${SMOKE_USER_DIRECTORY}" \
  "${RIME_DATA_DIRECTORY}/Prebuilt"

printf 'Rime 数据已生成：%s\n' "${RIME_DATA_DIRECTORY}/Prebuilt"
printf '临时构建目录保留在：%s\n' "${WORK_DIRECTORY}"
