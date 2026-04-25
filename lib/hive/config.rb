require "yaml"
require "fileutils"

module Hive
  module Config
    DEFAULTS = {
      "hive_state_path" => ".hive-state",
      "worktree_root" => nil,
      "max_review_passes" => 4,
      "default_branch" => nil,
      "project_name" => nil,
      "budget_usd" => {
        "brainstorm" => 10,
        "plan" => 20,
        "execute_implementation" => 100,
        "execute_review" => 50,
        "pr" => 10
      },
      "timeout_sec" => {
        "brainstorm" => 300,
        "plan" => 600,
        "execute_implementation" => 2700,
        "execute_review" => 600,
        "pr" => 300
      }
    }.freeze

    module_function

    def hive_home
      ENV["HIVE_HOME"] || File.expand_path("~/Dev/hive")
    end

    def global_config_path
      File.join(hive_home, "config.yml")
    end

    def hive_state_dir(project_root, hive_state_name = ".hive-state")
      File.join(project_root, hive_state_name)
    end

    def load(project_root)
      project_root = File.expand_path(project_root)
      candidate = File.join(project_root, ".hive-state", "config.yml")
      data = if File.exist?(candidate)
               parsed = YAML.safe_load(File.read(candidate)) || {}
               raise ConfigError, "config.yml at #{candidate} must be a hash" unless parsed.is_a?(Hash)

               parsed
             else
               {}
             end
      merge_defaults(data).merge("project_root" => project_root)
    end

    def registered_projects
      path = global_config_path
      return [] unless File.exist?(path)

      data = YAML.safe_load(File.read(path)) || {}
      raise ConfigError, "global config at #{path} must be a hash" unless data.is_a?(Hash)

      Array(data["registered_projects"]).map do |entry|
        raise ConfigError, "registered_projects entries must be hashes" unless entry.is_a?(Hash)

        {
          "name" => entry.fetch("name"),
          "path" => File.expand_path(entry.fetch("path")),
          "hive_state_path" => entry["hive_state_path"] ||
            File.join(File.expand_path(entry.fetch("path")), ".hive-state")
        }
      end
    end

    def find_project(name)
      registered_projects.find { |p| p["name"] == name }
    end

    def register_project(name:, path:)
      FileUtils.mkdir_p(hive_home)
      data = if File.exist?(global_config_path)
               YAML.safe_load(File.read(global_config_path)) || {}
             else
               {}
             end
      data["registered_projects"] ||= []
      abs_path = File.expand_path(path)
      hive_state_path = File.join(abs_path, ".hive-state")
      entry = { "name" => name, "path" => abs_path, "hive_state_path" => hive_state_path }
      existing = data["registered_projects"].find { |p| p["name"] == name }
      if existing
        existing.replace(entry)
      else
        data["registered_projects"] << entry
      end
      File.write(global_config_path, data.to_yaml)
      entry
    end

    def merge_defaults(data)
      out = deep_dup(DEFAULTS)
      data.each do |k, v|
        out[k] = if v.is_a?(Hash) && out[k].is_a?(Hash)
                   out[k].merge(v)
                 else
                   v
                 end
      end
      out
    end

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end
  end
end
