require "fileutils"
require "json"
require "shellwords"

module Hive
  module StopHookInstaller
    HOOK_PATH = File.expand_path("scripts/stop_hook.sh", __dir__)

    module_function

    def install(stage_dir:)
      claude_dir = File.join(stage_dir, ".claude")
      FileUtils.mkdir_p(claude_dir)
      settings_path = File.join(claude_dir, "settings.json")
      # Brainstorm Claude runs with --permission-mode bypassPermissions
      # plus Write/Edit in --allowedTools, both scoped to this stage_dir.
      # A prompt-injected idea.md could otherwise direct the agent to
      # overwrite the Stop hook command with arbitrary shell. Drop the
      # previous file before re-writing (it may already be 0o444 from a
      # prior install), then chmod 0o444 so the OS rejects any further
      # write before Claude's tool layer can apply it.
      File.delete(settings_path) if File.exist?(settings_path)
      File.write(settings_path, JSON.pretty_generate(settings(stage_dir)) + "\n")
      File.chmod(0o444, settings_path)
      settings_path
    end

    # Real Claude Code expects each Stop entry to be a matcher group whose
    # `hooks` array carries handler descriptors with `type: "command"` and a
    # shell-string `command`. HIVE_TASK_STAGE_DIR is propagated by prefixing
    # the command with a shell `VAR=… script` assignment, since Claude Code
    # invokes the command via a shell and there is no per-hook `env` field.
    def settings(stage_dir)
      {
        "hooks" => {
          "Stop" => [
            {
              "hooks" => [
                {
                  "type" => "command",
                  "command" => "HIVE_TASK_STAGE_DIR=#{Shellwords.escape(stage_dir)} #{Shellwords.escape(HOOK_PATH)}"
                }
              ]
            }
          ]
        }
      }
    end
  end
end
