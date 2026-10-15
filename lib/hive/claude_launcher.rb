require "json"
require "set"

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
    # The repair runs before every spawn, so a kept backup is reported once
    # per settings path per process instead of on every launch.
    KEPT_BACKUP_WARNED = Set.new
    KEPT_BACKUP_WARNED_LOCK = Mutex.new

    module_function

    # Launch options `spawn_claude!` and `launch!` take through `**options`
    # rather than naming them, with their defaults. Most reach spawn_agent
    # unchanged. A fresh Hash per call keeps the Array defaults unshared.
    def launch_option_defaults
      {
        expected_output: nil, status_mode: nil, permission_mode: nil,
        allowed_tools: nil, disallowed_tools: nil,
        identity_arguments: nil, routing_arguments: nil, runtime_policy: nil,
        additional_read_roots: [], additional_write_roots: [],
        edit_patterns: [], bash_patterns: [],
        resource_guards: nil, agent_custody: nil,
        model: nil, effort: nil, mcp_scope: nil
      }
    end

    LAUNCH_OPTIONS = launch_option_defaults.keys.freeze

    # Raise like a keyword signature on anything outside LAUNCH_OPTIONS:
    # spawn_agent accepts more (cfg:, cli_flags:, ...) than callers may pass.
    def launch_options(options)
      unknown = options.keys - LAUNCH_OPTIONS
      unless unknown.empty?
        raise ArgumentError,
              "unknown keyword#{'s' unless unknown.one?}: #{unknown.map(&:inspect).join(', ')}"
      end
      launch_option_defaults.merge(options)
    end

    def launch!(task:, cfg:, prompt:, add_dirs:, cwd:, max_budget_usd:,
                timeout_sec:, log_label:, profile: nil, **options)
      options = launch_options(options)
      routing_arguments = options[:routing_arguments]
      identity_arguments = options[:identity_arguments]
      model = options[:model]
      effort = options[:effort]
      profile ||= Hive::AgentProfiles.lookup(:claude, cfg: cfg)
      ensure_claude_profile!(profile)
      permission_mode = options[:permission_mode] || Hive::Config.claude_permission_mode(cfg)
      profile.validate_routing_arguments!(routing_arguments) if routing_arguments
      routed_flags = routing_arguments&.native_arguments
      # Per-stage model/effort override the project-global claude.* pins.
      # The resolved pair also goes to spawn_agent for the session receipt.
      receipt_model, receipt_effort =
        if routed_flags || identity_arguments || cfg.nil?
          [ nil, nil ]
        else
          Hive::Config.claude_identity(cfg, model: model, effort: effort)
        end
      cli_flags = routed_flags || identity_arguments ||
                  (cfg ? Hive::Config.claude_cli_flags(cfg, model: model, effort: effort) : [])
      require "hive/stages/base"
      headless_flags = routing_arguments ? [] : cli_flags
      # model/effort are already folded into cli_flags and the receipt pair.
      Hive::Stages::Base.spawn_agent(
        task,
        prompt: prompt, add_dirs: add_dirs, cwd: cwd,
        max_budget_usd: max_budget_usd, timeout_sec: timeout_sec,
        log_label: log_label, profile: profile,
        **options.except(:model, :effort),
        permission_mode: permission_mode,
        cli_flags: headless_flags,
        receipt_model: receipt_model,
        receipt_effort: receipt_effort
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
          warn_kept_backup_once(settings_path, backup_path)
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

    def warn_kept_backup_once(settings_path, backup_path)
      return unless KEPT_BACKUP_WARNED_LOCK.synchronize { KEPT_BACKUP_WARNED.add?(settings_path) }

      warn "[hive] left legacy Claude settings backup #{backup_path} in place: " \
           "#{settings_path} is not the tmux-era stub"
    end

    def reset_kept_backup_warnings!
      KEPT_BACKUP_WARNED_LOCK.synchronize { KEPT_BACKUP_WARNED.clear }
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
