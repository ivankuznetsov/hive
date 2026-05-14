require "fileutils"
require "json"

module Hive
  module StopHookInstaller
    HOOK_PATH = File.expand_path("scripts/stop_hook.sh", __dir__)

    module_function

    def install(stage_dir:)
      claude_dir = File.join(stage_dir, ".claude")
      FileUtils.mkdir_p(claude_dir)
      settings_path = File.join(claude_dir, "settings.json")
      File.write(settings_path, JSON.pretty_generate(settings(stage_dir)) + "\n")
      settings_path
    end

    def settings(stage_dir)
      {
        "hooks" => {
          "Stop" => [
            {
              "command" => HOOK_PATH,
              "args" => [],
              "env" => { "HIVE_TASK_STAGE_DIR" => stage_dir }
            }
          ]
        }
      }
    end
  end
end
