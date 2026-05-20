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

[[ -s "${stage}/bin/hive" ]] || { echo "tebako produced an empty binary at ${stage}/bin/hive" >&2; exit 70; }
chmod 0755 "${stage}/bin/hive"

size_bytes="$(wc -c < "${stage}/bin/hive" | tr -d '[:space:]')"
[[ "${size_bytes}" -ge 1048576 ]] || {
  echo "tebako produced an unexpectedly small binary (${size_bytes} bytes) at ${stage}/bin/hive" >&2
  exit 70
}

file_info="$(file -b "${stage}/bin/hive")"
case "${target}" in
  darwin-arm64)
    [[ "${file_info}" == *"Mach-O"* && "${file_info}" == *"arm64"* ]] || {
      echo "tebako output has wrong file signature for ${target}: ${file_info}" >&2
      exit 70
    }
    ;;
  linux-x86_64-gnu)
    [[ "${file_info}" == *"ELF"* && ( "${file_info}" == *"x86-64"* || "${file_info}" == *"x86_64"* ) ]] || {
      echo "tebako output has wrong file signature for ${target}: ${file_info}" >&2
      exit 70
    }
    ;;
  linux-aarch64-gnu)
    [[ "${file_info}" == *"ELF"* && ( "${file_info}" == *"aarch64"* || "${file_info}" == *"ARM aarch64"* ) ]] || {
      echo "tebako output has wrong file signature for ${target}: ${file_info}" >&2
      exit 70
    }
    ;;
esac

# Smoke check: only run native-target binaries; cross-compiled
# linux-aarch64-gnu on linux-x86_64-gnu (and vice versa) can't be
# executed here, so skip the runtime check in that case.
host_arch="$(uname -m)"
host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${target}" in
  darwin-arm64)        runnable=$([[ "${host_os}" == "darwin" && "${host_arch}" == "arm64" ]] && echo 1 || echo 0) ;;
  linux-x86_64-gnu)    runnable=$([[ "${host_os}" == "linux"  && ( "${host_arch}" == "x86_64" || "${host_arch}" == "amd64" ) ]] && echo 1 || echo 0) ;;
  linux-aarch64-gnu)   runnable=$([[ "${host_os}" == "linux"  && ( "${host_arch}" == "aarch64" || "${host_arch}" == "arm64" ) ]] && echo 1 || echo 0) ;;
  *)                   runnable=0 ;;
esac

if [[ "${runnable}" == "1" ]]; then
  "${stage}/bin/hive" --version >/dev/null || { echo "smoke check failed: ${stage}/bin/hive --version did not exit 0" >&2; exit 70; }
else
  echo "skipping smoke check: ${target} not executable on ${host_os}/${host_arch}" >&2
fi
cp LICENSE README.md "${stage}/"
cp -R templates "${stage}/share/hive/templates"
cp -R examples "${stage}/share/hive/examples"
cp -R wiki "${stage}/share/hive/wiki"

tar -C "${release_dir}" -czf "${archive}" "hive-${version}-${target}"
echo "${archive}"
