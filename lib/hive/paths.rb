module Hive
  module Paths
    module_function

    def config_home
      hive_home_override || File.join(base_home("XDG_CONFIG_HOME", ".config"), "hive")
    end

    def data_home
      hive_home_override || File.join(base_home("XDG_DATA_HOME", ".local/share"), "hive")
    end

    def state_home
      hive_home_override || File.join(base_home("XDG_STATE_HOME", ".local/state"), "hive")
    end

    def runtime_control_plane_path(root = state_home)
      File.join(root, "runtime-control-plane.sqlite3")
    end

    def runtime_payload_root(root = state_home)
      File.join(root, "runtime-payloads")
    end

    def cache_home
      hive_home_override || File.join(base_home("XDG_CACHE_HOME", ".cache"), "hive")
    end

    def workflow_publish_root
      File.join(state_home, "workflow-publish", "v1")
    end

    def workflow_publish_receipts_root
      File.join(workflow_publish_root, "receipts")
    end

    def workflow_publish_objects_root
      File.join(workflow_publish_root, "objects")
    end

    # Host-global daily activity projection. The version lives in the path so
    # future readers never have to infer a record schema from mutable config.
    def daily_digest_root
      File.join(state_home, "daily-digest", "v1")
    end

    def daily_digest_delivery_root
      File.join(daily_digest_root, "deliveries")
    end

    def bin_home
      # bin_home intentionally ignores HIVE_HOME — install.sh places
      # the `hive`/`hv` symlinks under XDG_BIN_HOME (or ~/.local/bin),
      # regardless of how config/data/state/cache are collapsed via the
      # test override.
      File.expand_path(env_or_blank("XDG_BIN_HOME") || File.join(home, ".local/bin"))
    end

    def web_app_home
      File.join(data_home, "web")
    end

    # True when HIVE_HOME collapses every XDG directory onto one path:
    # state_home == config_home == data_home == cache_home. Uninstall uses
    # this to refuse deletes like `rm_rf(config_home)`, which would also
    # wipe state and accumulated work.
    def hive_home_collapsed?
      !hive_home_override.nil?
    end

    def base_home(env_key, fallback)
      File.expand_path(env_or_blank(env_key) || File.join(home, fallback))
    end

    def home
      ENV.fetch("HOME") { Dir.home }
    end

    # Per the XDG Base Directory spec, an exported but empty XDG_* var
    # must be treated as unset — otherwise `XDG_CONFIG_HOME=` would
    # resolve to `File.expand_path("")` → cwd-relative `<cwd>/hive`.
    def env_or_blank(key)
      value = ENV[key]
      return nil if value.nil? || value.empty?

      value
    end

    def hive_home_override
      value = ENV["HIVE_HOME"]
      return nil if value.nil? || value.empty?

      File.expand_path(value)
    end
  end
end
