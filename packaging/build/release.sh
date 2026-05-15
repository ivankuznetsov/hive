#!/usr/bin/env bash
set -euo pipefail

target="${1:-}"
if [[ -z "${target}" ]]; then
  echo "usage: packaging/build/release.sh <target>" >&2
  exit 64
fi

case "${target}" in
  darwin-arm64|linux-x86_64-gnu|linux-aarch64-gnu) ;;
  *)
    echo "unsupported release target: ${target}" >&2
    exit 64
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

version="$(ruby -Ilib -e 'require "hive"; print Hive::VERSION')"
release_dir="${repo_root}/tmp/release"
stage="${release_dir}/hive-${version}-${target}"
archive="${release_dir}/hive-${version}-${target}.tar.gz"

rm -rf "${stage}" "${archive}"
mkdir -p "${stage}/bin" "${stage}/share/hive"

if ! command -v tebako >/dev/null 2>&1; then
  echo "tebako is required to build hive ${target} release artifacts" >&2
  echo "install tebako in the release runner, then re-run: rake build:release[${target}]" >&2
  exit 69
fi

tebako press \
  --root "${repo_root}" \
  --entry-point "${repo_root}/bin/hive" \
  --output "${stage}/bin/hive"

chmod 0755 "${stage}/bin/hive"
cp LICENSE README.md "${stage}/"
cp -R templates "${stage}/share/hive/templates"
cp -R examples "${stage}/share/hive/examples"
cp -R wiki "${stage}/share/hive/wiki"

tar -C "${release_dir}" -czf "${archive}" "hive-${version}-${target}"
echo "${archive}"
