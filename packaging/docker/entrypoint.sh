#!/bin/sh
set -eu

mkdir -p /data/home /data/repos /data/config /data/state /data/cache /data/share

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# Load the full library (-rhive) before the supervisor so constants like
# Hive::ConfigError, referenced transitively while requiring the supervisor,
# are already defined — otherwise boot dies with an uninitialized-constant
# NameError and the container never starts.
exec ruby -rhive -rhive/web/supervisor -e 'Hive::Web::Supervisor.new.run'
