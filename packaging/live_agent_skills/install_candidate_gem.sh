#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "usage: install_candidate_gem.sh GEM_FILE ABSOLUTE_INSTALL_ROOT" >&2
  exit 64
fi

gem_file=$1
install_root=$2

[[ -f "$gem_file" && -s "$gem_file" ]] || {
  echo "candidate gem is missing or empty: $gem_file" >&2
  exit 66
}
[[ "$install_root" == /* ]] || {
  echo "candidate gem install root must be absolute: $install_root" >&2
  exit 64
}

rubygems_bin="$install_root/rubygems-bin"
public_bin="$install_root/bin"
mkdir -p "$rubygems_bin" "$public_bin"

gem install "$gem_file" \
  --install-dir "$install_root" \
  --bindir "$rubygems_bin" \
  --no-document

ruby_realpath="$(ruby -rrbconfig -e 'print File.realpath(RbConfig.ruby)')"
printf -v quoted_install_root '%q' "$install_root"
printf -v quoted_ruby '%q' "$ruby_realpath"
printf -v quoted_inner_hive '%q' "$rubygems_bin/hive"
{
  printf '%s\n' '#!/usr/bin/bash' 'set -euo pipefail'
  printf '%s\n' \
    'unset RUBYOPT RUBYLIB BUNDLER_SETUP BUNDLE_GEMFILE BUNDLE_BIN_PATH RUBYGEMS_GEMDEPS'
  printf 'export GEM_HOME=%s\n' "$quoted_install_root"
  printf '%s\n' 'export GEM_PATH="$GEM_HOME"'
  printf 'exec %s %s "$@"\n' "$quoted_ruby" "$quoted_inner_hive"
} > "$public_bin/hive"
chmod 0755 "$public_bin/hive"
