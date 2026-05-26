require "fileutils"
require "json"
require "shellwords"

module Hive
  module StopHookInstaller
    HOOK_PATH = File.expand_path("scripts/stop_hook.sh", __dir__)
    BACKUP_SUFFIX = ".hive-pre-install"

    module_function

    def install(stage_dir:, extra_dirs: [])
      paths = [ install_at(stage_dir, stage_dir) ]
      # Claude resolves `.claude/settings.json` from the process cwd, not
      # from --add-dir paths. Stages that launch with cwd != task.folder
      # (4-execute / 6-review reviewers run in the feature worktree)
      # never saw the stop-hook config under task.folder, so the .done
      # / result.json signal files were never written and waits in
      # 5-open-pr / 6-review CI-fix could hang until timeout. Install a
      # second copy in each extra dir so Claude finds the hook
      # regardless of cwd.
      Array(extra_dirs).each do |dir|
        next if dir.to_s.empty?
        next if File.expand_path(dir) == File.expand_path(stage_dir)

        paths << install_at(dir, stage_dir)
      end
      paths
    end

    def install_at(target_dir, stage_dir)
      claude_dir = File.join(target_dir, ".claude")
      FileUtils.mkdir_p(claude_dir)
      settings_path = File.join(claude_dir, "settings.json")
      # If a project-owned `.claude/settings.json` is already present
      # (e.g. committed by `hive init`'s llm-wiki bootstrap or by the
      # operator), back it up so cleanup_scratch can restore it. Without
      # this, the unconditional delete below would destroy the project's
      # plugin/hook configuration and the post-stage dirty-worktree check
      # would fire `EXECUTE_WAITING reason=dirty_worktree` (and the
      # equivalent in 6-review / 8-finalize). Only back up on the FIRST
      # install in a spawn pair: if a backup already exists, the current
      # settings.json is the hive-installed stub from a prior install
      # call, not the project's original — re-backing up would overwrite
      # the original with the stub and lose it forever.
      backup_path = "#{settings_path}#{BACKUP_SUFFIX}"
      if File.exist?(settings_path) && !File.exist?(backup_path)
        FileUtils.cp(settings_path, backup_path)
      end
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
