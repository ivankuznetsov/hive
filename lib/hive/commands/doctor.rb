require "json"
require "open3"
require "timeout"

require "hive"
require "hive/config"
require "hive/invoked_binary"
require "hive/agent_profiles"
require "hive/agent_profiles/claude"
require "hive/agent_profiles/codex"
require "hive/agent_profiles/pi"
require "hive/claude_launcher"
require "hive/agent_skills"
require "hive/agent_skills/inspector"
require "hive/web/environment"

module Hive
  module Commands
    # `hive doctor` is the read-only renderer for AgentSkills::Inspector.
    # Managed skill rows combine filesystem-only native inventory with the
    # exact filesystem resolver used at runtime; legacy tmux/QMD/config advisories
    # remain separate. `--json` emits the typed hive-doctor.v2 envelope.
    class Doctor
      EXIT_SUCCESS = 0
      EXIT_MISSING_SKILL = 65
      EXIT_CONFIG_ERROR = 78

      # Exposes the row set after `#call` has run. Lets in-process
      # callers (e.g., `Hive::Commands::Init`'s preflight) read the
      # probe results directly without re-running the renderer or the
      # JSON encoder. Returns `nil` before `#call` has populated it.
      attr_reader :rows

      def initialize(config:, project_root:, json: false, output: $stdout,
                     inspector: nil, environment: ENV)
        @config = config
        @project_root = project_root
        @json = json
        @output = output
        @inspector = inspector
        @environment = environment
        @rows = nil
      end

      def call
        legacy_rows = check_tmux + check_llm_wiki_qmd + check_legacy_brainstorm_runtime +
                      check_web_environment_aliases
        managed_rows = managed_skill_rows
        @rows = legacy_rows + managed_rows
        if @json
          @output.puts JSON.generate(envelope(legacy_rows, managed_rows))
        else
          render_table(@rows)
        end

        @rows.any? { |row| failing_row?(row) } ? EXIT_MISSING_SKILL : EXIT_SUCCESS
      rescue Hive::ConfigError, KeyError, ArgumentError => e
        if @json
          @output.puts JSON.generate(error: e.message)
        else
          @output.puts "hive doctor: #{e.message}"
        end
        EXIT_CONFIG_ERROR
      end

      private

      def failing_status?(status)
        status == "missing" || status == "version_too_old"
      end

      def failing_row?(row)
        return failing_status?(row[:status]) unless row[:kind] == "managed_skill"

        %w[missing stale incompatible conflicting].include?(row[:health])
      end

      def managed_skill_rows
        inspector = @inspector || Hive::AgentSkills.hive_inspector(
          config: @config,
          project_root: @project_root,
          environment: @environment,
          include_openclaw: true,
          native_commands: false
        )
        inspector.inspect.map { |inspection| managed_row(inspection) }
      end

      def managed_row(inspection)
        target = inspection.target
        label = target.surfaces.join(",")
        row = {
          kind: "managed_skill",
          stage: target.surfaces.first,
          label: label,
          agent: target.agent,
          capability: target.capability_id,
          managed: target.managed,
          configured_skill: target.configured_skill,
          skill: target.invocation,
          status: inspection.health,
          health: inspection.health,
          severity: inspection.severity,
          message: inspection.explanation,
          remediation: inspection.remediation,
          expected: inspection.expected,
          native: inspection.native,
          resolution: inspection.resolution
        }
        row[:name] = label.delete_prefix("6-review/") if label.start_with?("6-review/")
        row
      end

      def check_tmux
        return [] unless Hive::Config.claude_mode(@config) == :tmux

        status, message = Hive::ClaudeLauncher.tmux_status
        rows = [
          {
            kind: "dependency",
            stage: "claude",
            label: "claude/tmux",
            agent: "tmux",
            configured_skill: "tmux >= #{Hive::ClaudeLauncher::MIN_TMUX_VERSION}",
            skill: "tmux",
            status: status.to_s,
            message: message
          }
        ]
        rows.concat(tmux_runtime_warnings)
        rows
      end

      def check_llm_wiki_qmd
        return [] unless @project_root && File.directory?(File.join(@project_root, ".llm-wiki"))

        qmd = find_qmd
        unless qmd
          return [ warning_row(
            stage: "wiki",
            label: "wiki/qmd",
            agent: "qmd",
            configured_skill: "@tobilu/qmd",
            skill: "qmd",
            message: "qmd is not installed or not discoverable; install Node.js/npm then run " \
                     "`npm install --global --prefix \"${XDG_DATA_HOME:-$HOME/.local/share}/hive/qmd\" @tobilu/qmd` " \
                     "(`hive update` also repairs qmd on bash-channel installs), or set HIVE_QMD_BIN to an executable qmd"
          ) ]
        end

        begin
          out, err, status = Timeout.timeout(15) { Open3.capture3(qmd, "--version") }
        rescue Timeout::Error, SystemCallError => e
          return [ warning_row(
            stage: "wiki",
            label: "wiki/qmd",
            agent: "qmd",
            configured_skill: "@tobilu/qmd",
            skill: "qmd",
            message: "qmd at #{qmd} timed out or could not be executed (#{e.message}); reinstall with " \
                     "`npm install --global --prefix \"${XDG_DATA_HOME:-$HOME/.local/share}/hive/qmd\" @tobilu/qmd` " \
                     "(or rebuild better-sqlite3 with `npm rebuild better-sqlite3`)"
          ) ]
        end

        if status.success?
          return [ {
            kind: "dependency",
            stage: "wiki",
            label: "wiki/qmd",
            agent: "qmd",
            configured_skill: "@tobilu/qmd",
            skill: "qmd",
            status: "present",
            message: [ qmd, out.strip ].reject(&:empty?).join(" ")
          } ]
        end

        diagnostic = first_diagnostic_line(err, out)
        detail = diagnostic.empty? ? "" : " (#{diagnostic})"
        [ warning_row(
          stage: "wiki",
          label: "wiki/qmd",
          agent: "qmd",
          configured_skill: "@tobilu/qmd",
          skill: "qmd",
          message: "qmd is installed at #{qmd} but failed to start#{detail}; " \
                   "reinstall with `npm install --global --prefix \"${XDG_DATA_HOME:-$HOME/.local/share}/hive/qmd\" " \
                   "@tobilu/qmd`, or rebuild the active npm install with `npm rebuild better-sqlite3` " \
                   "(`hive update` also repairs qmd on bash-channel installs)"
        ) ]
      end

      def find_qmd
        env_qmd = ENV["HIVE_QMD_BIN"].to_s
        return env_qmd if !env_qmd.empty? && File.executable?(env_qmd)

        path_qmd = which("qmd")
        return path_qmd if path_qmd

        data_home = ENV["XDG_DATA_HOME"].to_s.empty? ? File.expand_path("~/.local/share") : ENV["XDG_DATA_HOME"]
        candidates = [
          File.join(data_home, "hive", "qmd", "bin", "qmd"),
          File.expand_path("~/.local/share/hive/qmd/bin/qmd")
        ]

        prefix_file = File.join(data_home, "hive", "install-prefix")
        if File.readable?(prefix_file)
          prefix = File.read(prefix_file).lines.first.to_s.strip
          candidates << File.join(prefix, "hive", "qmd", "bin", "qmd") unless prefix.empty?
        end

        candidates.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      end

      def which(name)
        Hive::InvokedBinary.which(name)
      end

      def first_diagnostic_line(*parts)
        parts.join("\n").lines.map(&:strip).find { |line| !line.empty? }.to_s
      end

      def check_legacy_brainstorm_runtime
        rows = []
        if config_yml_unreadable?
          rows << warning_row(
            stage: "2-brainstorm", # coding-scoped: doctor probes coding brainstorm config
            label: ".hive-state/config.yml",
            agent: "config",
            configured_skill: "config.yml",
            skill: ".hive-state/config.yml",
            message: "could not parse .hive-state/config.yml (#{@config_yml_error}); " \
                     "any brainstorm.runtime → claude.mode migration warning is suppressed " \
                     "until the file parses cleanly"
          )
          return rows
        end

        return rows unless legacy_brainstorm_runtime_present?

        rows << warning_row(
          stage: "2-brainstorm", # coding-scoped: doctor probes coding brainstorm config
          label: "2-brainstorm/brainstorm.runtime",
          agent: "claude",
          configured_skill: "brainstorm.runtime",
          skill: "claude.mode",
          message: "brainstorm.runtime is superseded by claude.mode (project-global); " \
                   "migrate by adding the following YAML and removing the brainstorm.runtime key:\n" \
                   "  claude:\n    mode: tmux"
        )
        rows
      end

      def check_web_environment_aliases
        Hive::Web::Environment.warnings(environment: @environment).map do |warning|
          warning_row(
            stage: "web",
            label: "web/environment",
            agent: "environment",
            configured_skill: warning.fetch("alias"),
            skill: warning.fetch("replacement"),
            message: warning.fetch("message")
          ).merge(
            alias: warning.fetch("alias"),
            replacement: warning.fetch("replacement"),
            ignored: warning.fetch("ignored")
          )
        end
      end

      def legacy_brainstorm_runtime_present?
        return true if Hive::Config.explicit_brainstorm_runtime?(@config)

        return false unless @project_root

        path = File.join(@project_root, ".hive-state", "config.yml")
        return false unless File.exist?(path)

        raw = YAML.safe_load(File.read(path)) || {}
        Hive::Config.nested_key?(raw, "brainstorm", "runtime")
      rescue Psych::SyntaxError, Errno::ENOENT
        false
      end

      # Detect a config.yml that cannot be loaded (corrupt YAML, perms,
      # etc.) and remember the underlying error message so the operator
      # sees a row explaining why doctor cannot evaluate the migration
      # warning. Without this, a corrupt config.yml silently hid the
      # legacy_brainstorm_runtime warning AND any other config-derived
      # check that depends on the file.
      def config_yml_unreadable?
        return @config_yml_unreadable unless @config_yml_unreadable.nil?

        @config_yml_unreadable =
          if @project_root
            path = File.join(@project_root, ".hive-state", "config.yml")
            if File.exist?(path)
              begin
                YAML.safe_load(File.read(path))
                false
              rescue Psych::SyntaxError, Errno::EACCES, Errno::EISDIR => e
                @config_yml_error = "#{e.class.name.split('::').last}: #{e.message}"
                true
              end
            else
              false
            end
          else
            false
          end
      end

      # Operator-visible warnings for the tmux runtime. Each warning is a
      # `kind: "warning"` row — it does NOT contribute to the missing-skill
      # exit code, but renders in the human table with a "!" marker and in
      # the JSON envelope under `summary.warning`.
      #
      # Currently surfaces a single check: when the parent shell exports
      # `ANTHROPIC_API_KEY` or `CLAUDE_API_KEY`. The tmux wrapper unsets
      # both before exec'ing claude, but an exported value at this scope
      # hints the operator may be confused about the billing-auth
      # boundary — flag it loudly so OAuth/subscription vs API-key
      # billing intent is explicit.
      def tmux_runtime_warnings
        warnings = []

        leaked = %w[ANTHROPIC_API_KEY CLAUDE_API_KEY].select { |k| ENV[k] && !ENV[k].empty? }
        unless leaked.empty?
          # `agent: "claude"` because the API keys named here are
          # claude/anthropic billing inputs — the warning is about the
          # billing-auth boundary, not tmux itself. Labelling this as a
          # "tmux warning" misreads the actual subject.
          warnings << warning_row(
            stage: "claude",
            label: "claude/tmux",
            agent: "claude",
            configured_skill: "billing-auth",
            skill: leaked.join(","),
            message: "#{leaked.join(' and ')} is exported in this shell; the tmux wrapper unsets it before exec, " \
                     "but the export hints at parent-shell intent — confirm you want OAuth/subscription billing, not API-key billing"
          )
        end

        warnings
      end

      def warning_row(label:, agent:, configured_skill:, skill:, message:, stage: "claude")
        {
          kind: "warning",
          stage: stage,
          label: label,
          agent: agent,
          configured_skill: configured_skill,
          skill: skill,
          status: "warning",
          message: message
        }
      end

      def envelope(legacy_rows, managed_rows)
        health_counts = Hive::AgentSkills::Inspector::HEALTH_PRECEDENCE.to_h do |health|
          [ health, managed_rows.count { |row| row[:health] == health } ]
        end
        {
          "schema" => "hive-doctor.v2",
          "schema_version" => 2,
          "managed_skills" => managed_rows,
          "checks" => legacy_rows,
          "summary" => {
            "managed" => health_counts,
            "legacy_failures" => legacy_rows.count { |row| failing_status?(row[:status]) },
            "warnings" => legacy_rows.count { |row| row[:status] == "warning" }
          }
        }
      end

      def render_table(rows)
        widths = compute_widths(rows)
        @output.puts header(widths)
        @output.puts separator(widths)
        rows.each { |r| @output.puts row_line(r, widths) }
        @output.puts
        rows.each do |r|
          next if %w[present healthy].include?(r[:status])

          @output.puts "[#{r[:label]}/#{r[:agent]}] #{r[:message]}"
          @output.puts "  remediation: #{r[:remediation]}" if r[:remediation]
        end
      end

      def compute_widths(rows)
        {
          label: column_width(rows, :label, "stage"),
          agent: column_width(rows, :agent, "agent"),
          skill: column_width(rows, :skill, "skill"),
          status: column_width(rows, :status, "status")
        }
      end

      def column_width(rows, key, header)
        ([ header.length ] + rows.map { |r| r[key].to_s.length }).max
      end

      def header(widths)
        format("%-#{widths[:label]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  %-#{widths[:status]}s",
               "stage", "agent", "skill", "status")
      end

      def separator(widths)
        format("%-#{widths[:label]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  %-#{widths[:status]}s",
               "-" * widths[:label], "-" * widths[:agent], "-" * widths[:skill], "-" * widths[:status])
      end

      def row_line(row, widths)
        display_status = row[:kind] == "managed_skill" && row[:status] == "healthy" ? "present" : row[:status]
        marker = case row[:status]
        when "present" then "✓"
        when "healthy" then "✓"
        when "missing" then "✗"
        when "stale" then "✗"
        when "incompatible" then "✗"
        when "conflicting" then "✗"
        when "unavailable" then "—"
        when "version_too_old" then "✗"
        when "not_applicable" then "—"
        when "warning" then "!"
        else "?"
        end
        format("%-#{widths[:label]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  #{marker} %-#{widths[:status]}s",
               row[:label], row[:agent], row[:skill], display_status)
      end
    end
  end
end
