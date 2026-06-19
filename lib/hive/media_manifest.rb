module Hive
  # Shared vocabulary for the `media/manifest.json` contract that the
  # 7-artifacts stage writes and hivebox reads. The schema int lives here, in
  # one gem module both tiers reference, so a version bump can't leave the
  # stage (lib/hive/stages/artifacts.rb) and the web reader
  # (web/app/controllers/tasks_controller.rb) silently disagreeing — one
  # reading a v2 file as v1.
  module MediaManifest
    # The only media-manifest schema version the gem stage and the web reader
    # understand. A future manifest with a higher version reshapes items[], so
    # both tiers gate on this exact int and skip an unknown version rather than
    # misread it as v1.
    SCHEMA = 1
  end
end
