require "json"

require "hive"
require "hive/config"
require "hive/agent_profiles"
require "hive/agent_profiles/claude"
require "hive/agent_profiles/codex"
require "hive/agent_profiles/pi"
require "hive/stages/brainstorm"
require "hive/stages/brainstorm_tmux"

module Hive
  module Commands
    # `hive doctor` — verifies that every configured stage skill AND every
    # 6-review reviewer skill actually resolves to an installed
    # slash-command / skill on the operator's machine. Walks brainstorm
    # + plan stage configs, plus `review.reviewers[]`, asks each agent
    # profile to probe its filesystem, prints a status table, and exits
    # non-zero if any check is `:missing`.
    #
    # Pi rows use pi's `/skill:<name>` form and real skill resolver.
    # Non-skill-form invocations still come back `:not_applicable`
    # because pi cannot resolve those as skills.
    #
    # Reviewer entries with `kind:` ≠ `"agent"` also surface as
    # `:not_applicable`. This is the **only load-time signal** for
    # non-agent kinds — `Hive::Config.validate_reviewers!` does NOT
    # check the `kind` field; only `Hive::Reviewers.dispatch` does, at
    # run-time.
    #
    # `--json` emits a machine-readable envelope so an agent caller
    # (the daemon, an outer orchestrator) can decide how to react
    # without scraping the human-readable table.
    class Doctor
      EXIT_SUCCESS = 0
      EXIT_MISSING_SKILL = 65
      EXIT_CONFIG_ERROR = 78

      STAGES = %w[brainstorm plan].freeze

      # Exposes the row set after `#call` has run. Lets in-process
      # callers (e.g., `Hive::Commands::Init`'s preflight) read the
      # probe results directly without re-running the renderer or the
      # JSON encoder. Returns `nil` before `#call` has populated it.
      attr_reader :rows

      def initialize(config:, project_root:, json: false, output: $stdout)
        @config = config
        @project_root = project_root
        @json = json
        @output = output
        @rows = nil
      end

      def call
        @rows = check_tmux + check_stages + check_reviewers
        if @json
          @output.puts JSON.generate(envelope(@rows))
        else
          render_table(@rows)
        end

        @rows.any? { |r| failing_status?(r[:status]) } ? EXIT_MISSING_SKILL : EXIT_SUCCESS
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

      def check_stages
        STAGES.map { |stage| check_stage(stage) }
      end

      def check_tmux
        return [] unless Hive::Stages::Brainstorm.runtime_for(@config) == :tmux_interactive

        status, message = Hive::Stages::BrainstormTmux.tmux_status
        rows = [
          {
            kind: "dependency",
            stage: "2-brainstorm",
            label: "2-brainstorm/tmux",
            agent: "tmux",
            configured_skill: "tmux >= #{Hive::Stages::BrainstormTmux::MIN_TMUX_VERSION}",
            skill: "tmux",
            status: status.to_s,
            message: message
          }
        ]
        rows.concat(tmux_runtime_warnings)
        rows
      end

      # Operator-visible warnings for the tmux runtime. Each warning is a
      # `kind: "warning"` row — it does NOT contribute to the missing-skill
      # exit code, but renders in the human table with a "!" marker and in
      # the JSON envelope under `summary.warning`. Two checks today:
      #
      #   1. `brainstorm.agent` ≠ claude — the tmux runtime hardcodes claude
      #      at the wrapper level (`interactive_claude_wrapper.sh`), so a
      #      project that picked codex/pi for brainstorm would get a green
      #      doctor and then fail on the first tmux run with a missing
      #      claude install.
      #
      #   2. `ANTHROPIC_API_KEY` / `CLAUDE_API_KEY` exported — the wrapper
      #      unsets these before exec'ing claude, but a parent shell that
      #      exports either still implies the operator may be confused
      #      about the billing-auth boundary. Surface the boundary loudly.
      def tmux_runtime_warnings
        warnings = []
        agent_name = (@config.dig("brainstorm", "agent") || "claude").to_s
        if agent_name != "claude"
          warnings << warning_row(
            label: "2-brainstorm/tmux",
            agent: agent_name,
            configured_skill: "brainstorm.agent",
            skill: agent_name,
            message: "brainstorm.runtime=tmux_interactive hardcodes the claude binary, " \
                     "but brainstorm.agent=#{agent_name}; the tmux run will try to launch claude regardless"
          )
        end

        leaked = %w[ANTHROPIC_API_KEY CLAUDE_API_KEY].select { |k| ENV[k] && !ENV[k].empty? }
        unless leaked.empty?
          # `agent: "claude"` because the API keys named here are
          # claude/anthropic billing inputs — the warning is about the
          # billing-auth boundary, not tmux itself. Labelling this as a
          # "tmux warning" misreads the actual subject.
          warnings << warning_row(
            label: "2-brainstorm/tmux",
            agent: "claude",
            configured_skill: "billing-auth",
            skill: leaked.join(","),
            message: "#{leaked.join(' and ')} is exported in this shell; the tmux wrapper unsets it before exec, " \
                     "but the export hints at parent-shell intent — confirm you want OAuth/subscription billing, not API-key billing"
          )
        end

        warnings
      end

      def warning_row(label:, agent:, configured_skill:, skill:, message:)
        {
          kind: "warning",
          stage: "2-brainstorm",
          label: label,
          agent: agent,
          configured_skill: configured_skill,
          skill: skill,
          status: "warning",
          message: message
        }
      end

      def check_stage(stage)
        agent_name = (@config.dig(stage, "agent") || "claude").to_s
        skill = @config.dig(stage, "skill") || Hive::Config::DEFAULTS.dig(stage, "skill")
        profile = Hive::AgentProfiles.lookup(agent_name.to_sym)
        invocation = profile.format_skill_invocation(skill)

        status, message = profile.verify_skill(invocation, project_root: @project_root)
        {
          kind: "stage",
          stage: stage,
          label: stage,
          agent: agent_name,
          configured_skill: skill.to_s,
          skill: invocation,
          status: status.to_s,
          message: message
        }
      end

      def check_reviewers
        Array(@config.dig("review", "reviewers")).map { |spec| check_reviewer(spec) }
      end

      # Per-reviewer probe. Non-`agent` kinds short-circuit to N/A
      # rather than attempting an `AgentProfiles.lookup` — the row
      # explains why the entry is unrunnable. For `agent`-kind entries,
      # the bare config skill (e.g., `ce-code-review`) is formatted
      # through the profile's `skill_syntax_format` to obtain the full
      # invocation (`/ce-code-review`) before passing to `verify_skill`,
      # so the JSON envelope's `skill` field shape is uniform across
      # stage and reviewer rows.
      def check_reviewer(spec)
        agent_name = spec["agent"].to_s
        name = spec["name"].to_s
        kind = (spec["kind"] || "agent").to_s
        bare_skill = spec["skill"].to_s

        if kind != "agent"
          return reviewer_row(
            name: name,
            agent: agent_name,
            configured_skill: bare_skill,
            skill: bare_skill,
            status: "not_applicable",
            message: "kind '#{kind}' is not 'agent'; doctor only checks agent-kind reviewers"
          )
        end

        profile = Hive::AgentProfiles.lookup(agent_name.to_sym)
        invocation = profile.format_skill_invocation(bare_skill)
        status, message = profile.verify_skill(invocation, project_root: @project_root)
        reviewer_row(
          name: name,
          agent: agent_name,
          configured_skill: bare_skill,
          skill: invocation,
          status: status.to_s,
          message: message
        )
      end

      def reviewer_row(name:, agent:, configured_skill:, skill:, status:, message:)
        {
          kind: "reviewer",
          stage: "6-review",
          name: name,
          label: "6-review/#{name}",
          agent: agent,
          configured_skill: configured_skill,
          skill: skill,
          status: status,
          message: message
        }
      end

      # The `hive-doctor.v1` envelope is additive: `kind`, `name`,
      # `label`, and `configured_skill` are fields on `checks[]` entries
      # added 2026-05-07. Schema name stays `v1` because every change
      # is forward-compatible — consumers that ignore unknown fields
      # continue to work; the `summary` aggregation is still keyed by
      # `status`. `configured_skill` carries the raw config-supplied
      # value (`/anything`), while `skill` carries the formatted
      # profile-aware invocation (`/skill:anything` for pi). Diff them
      # to detect when a profile's `format_skill_invocation` rewrote
      # the operator's input.
      def envelope(rows)
        {
          "schema" => "hive-doctor.v1",
          "checks" => rows,
          "summary" => {
            "missing" => rows.count { |r| r[:status] == "missing" },
            "version_too_old" => rows.count { |r| r[:status] == "version_too_old" },
            "present" => rows.count { |r| r[:status] == "present" },
            "not_applicable" => rows.count { |r| r[:status] == "not_applicable" },
            "warning" => rows.count { |r| r[:status] == "warning" }
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
          next if r[:status] == "present"

          @output.puts "[#{r[:label]}/#{r[:agent]}] #{r[:message]}"
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
        marker = case row[:status]
        when "present" then "✓"
        when "missing" then "✗"
        when "version_too_old" then "✗"
        when "not_applicable" then "—"
        when "warning" then "!"
        else "?"
        end
        format("%-#{widths[:label]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  #{marker} %-#{widths[:status]}s",
               row[:label], row[:agent], row[:skill], row[:status])
      end
    end
  end
end
