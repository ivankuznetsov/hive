#!/bin/sh
set -eu

mkdir -p /data/home /data/repos /data/config /data/state /data/cache /data/share

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

exec ruby -rhive/web/supervisor -e 'Hive::Web::Supervisor.new.run'
