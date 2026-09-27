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
# Initialize a fresh data volume through setup's current-format contract.
# Existing incompatible storage is rejected rather than converted.
exec ruby -rhive -rhive/runtime_control_plane/installation \
  -rhive/runtime_control_plane/lifecycle_repository -rhive/web/supervisor \
  -e 'Hive::RuntimeControlPlane::Installation.setup; db = Hive::RuntimeControlPlane.database(path: Hive::Paths.runtime_control_plane_path).open!; lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: db); Hive::Web::Supervisor.new(persistent_admission: -> { lifecycle.current.admission_open? }).run'
