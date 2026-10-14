require "json"

require "hive/agent_profiles"
require "hive/agent_support/claude"
require "hive/config"

module Hive
  module ClaudeLauncher
    extend Hive::AgentSupport::Claude::Launch

    # Allowed-tool sets shared by every stage that spawns Claude. Keeping
    # them as constants means a policy change lands in one place; previous
    # PRs inlined the string literal across 11 sites and silently drifted
    # when one of them was updated without the others. R4 in the plan
    # called out the implementer/planner split — keep them separate.
    #
    # These are CSV STRINGS, while a resolved PermissionScope::Scope feeds
    # Arrays into the same `allowed_tools:`/`disallowed_tools:` params. That
    # is intentional: both forms are normalized by PermissionScope.tool_csv
    # at the argv chokepoint, which accepts CSV String | Array | nil (see its
    # doc for the idempotency caveat).
    PLANNER_ALLOWED_TOOLS = Hive::AgentSupport::Claude::Launch::PLANNER_TOOLS
    IMPLEMENTER_ALLOWED_TOOLS = Hive::AgentSupport::Claude::Launch::IMPLEMENTER_TOOLS

    # The retired tmux launch mode wrote a read-only Stop-hook stub to
    # `.claude/settings.json` (backing up a project-owned file to this
    # suffix first) and restored it when the stage ended. A runner killed
    # before that cleanup left both behind; `repair_legacy_scratch_settings`
    # puts them right before the next launch.
    LEGACY_SETTINGS_BACKUP_SUFFIX = ".hive-pre-install".freeze
    LEGACY_STOP_HOOK_SCRIPT = "/stop_hook.sh".freeze

    module_function

    def launch!(task:, cfg:, prompt:, add_dirs:, cwd:, max_budget_usd:,
                timeout_sec:, log_label:, status_mode: nil,
                expected_output: nil, profile: nil,
                allowed_tools: nil,
                disallowed_tools: nil,
                permission_mode: nil, mcp_config_path: nil,
                strict_mcp_config: false, identity_arguments: nil,
                routing_arguments: nil, runtime_policy: nil,
                additional_read_roots: [], additional_write_roots: [],
                edit_patterns: [], bash_patterns: [],
                resource_guards: nil, agent_custody: nil,
                model: nil, effort: nil)
      profile ||= Hive::AgentProfiles.lookup(:claude, cfg: cfg)
      ensure_claude_profile!(profile)
      permission_mode ||= Hive::Config.claude_permission_mode(cfg)
      profile.validate_routing_arguments!(routing_arguments) if routing_arguments
      routed_flags = routing_arguments&.native_arguments
      # Per-stage model/effort override the project-global claude.* pins.
      cli_flags = routed_flags || identity_arguments ||
                  (cfg ? Hive::Config.claude_cli_flags(cfg, model: model, effort: effort) : [])
      require "hive/stages/base"
      headless_flags = (routing_arguments ? [] : cli_flags) +
                       (runtime_policy ? [] : mcp_cli_flags(mcp_config_path, strict_mcp_config))
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: prompt,
        add_dirs: add_dirs,
        cwd: cwd,
        max_budget_usd: max_budget_usd,
        timeout_sec: timeout_sec,
        log_label: log_label,
        profile: profile,
        expected_output: expected_output,
        status_mode: status_mode,
        permission_mode: permission_mode,
        allowed_tools: allowed_tools,
        disallowed_tools: disallowed_tools,
        cli_flags: headless_flags,
        identity_arguments: identity_arguments,
        routing_arguments: routing_arguments,
        runtime_policy: runtime_policy,
        additional_read_roots: additional_read_roots,
        additional_write_roots: additional_write_roots,
        edit_patterns: edit_patterns,
        bash_patterns: bash_patterns,
        resource_guards: resource_guards,
        agent_custody: agent_custody
      )
    end

    def repair_legacy_scratch_settings(dirs)
      dirs.compact.map { |dir| File.expand_path(dir.to_s) }.uniq.each do |dir|
        repair_legacy_settings_at(File.join(dir, ".claude", "settings.json"))
      end
      nil
    end

    # Restore a project-owned settings.json from its backup; otherwise drop
    # a Stop-hook stub. Any other settings.json belongs to the project and
    # is left alone. rename(2)/unlink(2) need only directory write access,
    # so the 0444 stub is replaced without a chmod. Nothing here may abort
    # a launch.
    def repair_legacy_settings_at(settings_path)
      backup_path = "#{settings_path}#{LEGACY_SETTINGS_BACKUP_SUFFIX}"
      dir = File.dirname(settings_path)
      # Never act through a symlink: it could point outside the scratch dir.
      return if [ dir, settings_path, backup_path ].any? { |path| File.symlink?(path) }

      stub = legacy_stop_hook_stub?(settings_path)
      if File.exist?(backup_path)
        if stub || !File.exist?(settings_path)
          File.rename(backup_path, settings_path)
        else
          warn "[hive] left legacy Claude settings backup #{backup_path} in place: " \
               "#{settings_path} is not the tmux-era stub"
        end
      elsif stub
        File.delete(settings_path)
        Dir.rmdir(dir) if Dir.empty?(dir)
      end
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      nil
    rescue SystemCallError => e
      warn "[hive] could not repair legacy Claude settings #{settings_path}: #{e.class}: #{e.message}"
      nil
    end

    # The exact shape the tmux-era installer wrote: one Stop matcher group
    # holding one command handler that runs Hive's stop_hook.sh.
    def legacy_stop_hook_stub?(settings_path)
      return false if File.symlink?(settings_path) || !File.file?(settings_path)

      raw = File.read(settings_path)
      # Most launches find a project-owned settings.json; skip the parse
      # unless it could be the stub.
      return false unless raw.include?(LEGACY_STOP_HOOK_SCRIPT)

      data = JSON.parse(raw)
      return false unless data.is_a?(Hash)

      command = data.dig("hooks", "Stop", 0, "hooks", 0, "command")
      data == { "hooks" => { "Stop" => [ { "hooks" => [ { "type" => "command", "command" => command } ] } ] } } &&
        command.is_a?(String) &&
        command.start_with?("HIVE_TASK_STAGE_DIR=") &&
        command.end_with?(LEGACY_STOP_HOOK_SCRIPT)
    rescue JSON::ParserError, TypeError
      false
    end
  end
end
