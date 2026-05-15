require "fileutils"

module Hive
  module Paths
    module_function

    def config_home
      legacy_override || File.join(base_home("XDG_CONFIG_HOME", ".config"), "hive")
    end

    def data_home
      legacy_override || File.join(base_home("XDG_DATA_HOME", ".local/share"), "hive")
    end

    def state_home
      legacy_override || File.join(base_home("XDG_STATE_HOME", ".local/state"), "hive")
    end

    def cache_home
      legacy_override || File.join(base_home("XDG_CACHE_HOME", ".cache"), "hive")
    end

    def bin_home
      File.expand_path(ENV["XDG_BIN_HOME"] || File.join(home, ".local/bin"))
    end

    def ensure_migrated!
      return if legacy_override
      return if File.exist?(File.join(config_home, "config.yml"))

      legacy = File.expand_path("~/.hive-state/registry.yml")
      return unless File.exist?(legacy)

      FileUtils.mkdir_p(config_home)
      FileUtils.mv(legacy, File.join(config_home, "config.yml"))
      remove_empty_legacy_dir(File.dirname(legacy))
    end

    def base_home(env_key, fallback)
      File.expand_path(ENV[env_key] || File.join(home, fallback))
    end

    def home
      ENV.fetch("HOME") { Dir.home }
    end

    def legacy_override
      value = ENV["HIVE_HOME"]
      return nil if value.nil? || value.empty?

      File.expand_path(value)
    end

    def remove_empty_legacy_dir(path)
      Dir.rmdir(path)
    rescue SystemCallError
      nil
    end
  end
end
