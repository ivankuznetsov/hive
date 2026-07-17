require "fileutils"

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

    def cache_home
      hive_home_override || File.join(base_home("XDG_CACHE_HOME", ".cache"), "hive")
    end

    def task_counter_path
      File.join(state_home, "task-counter.yml")
    end

    def task_counter_lock_path
      File.join(state_home, ".task-counter.lock")
    end

    # Owner-private, versioned durable task-attempt state. Keeping the
    # version in the directory name lets a future on-disk migration inspect
    # old records without teaching older binaries to rewrite them.
    def attempts_root
      File.join(state_home, "attempts", "v1")
    end

    def attempt_records_root
      File.join(attempts_root, "records")
    end

    def attempt_logs_root
      File.join(attempts_root, "logs")
    end

    def attempt_outputs_root
      File.join(attempts_root, "outputs")
    end

    def attempt_generation_locks_root
      File.join(attempts_root, "generation-locks")
    end

    def babysitter_root(project_root)
      File.join(File.expand_path(project_root), ".hive-state", "babysitter")
    end

    def babysitter_jobs_root(project_root)
      File.join(babysitter_root(project_root), "jobs")
    end

    def babysitter_job_locks_root(project_root)
      File.join(babysitter_root(project_root), "locks", "jobs")
    end

    def babysitter_current_root(project_root)
      File.join(babysitter_root(project_root), "current")
    end

    def babysitter_current_locks_root(project_root)
      File.join(babysitter_root(project_root), "locks", "current")
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

    def ensure_migrated!
      return if hive_home_override
      return if File.exist?(File.join(config_home, "config.yml"))

      legacy = legacy_registry_path
      return unless legacy

      FileUtils.mkdir_p(config_home)
      FileUtils.mv(legacy, File.join(config_home, "config.yml"))
      File.write(
        File.join(config_home, ".migrated-from"),
        "#{legacy}\n"
      )
      remove_empty_legacy_dir(File.dirname(legacy))
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

    def remove_empty_legacy_dir(path)
      Dir.rmdir(path)
    rescue SystemCallError => e
      warn "hive: could not remove empty legacy dir #{path}: #{e.message}"
      nil
    end

    # Legacy registry candidates probed by `ensure_migrated!`. Order
    # matters: the older `~/Dev/hive/config.yml` is migrated only when
    # there is no `~/.hive-state/registry.yml`.
    def legacy_registry_path
      [
        File.expand_path("~/.hive-state/registry.yml"),
        File.expand_path("~/Dev/hive/config.yml")
      ].find { |p| File.exist?(p) }
    end
  end
end
