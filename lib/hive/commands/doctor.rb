require "json"

require "hive"
require "hive/config"
require "hive/agent_profiles"
require "hive/agent_profiles/claude"
require "hive/agent_profiles/codex"
require "hive/agent_profiles/pi"

module Hive
  module Commands
    # `hive doctor` — verifies that every configured stage skill
    # actually resolves to an installed slash-command / skill on the
    # operator's machine. Walks the brainstorm and plan stage configs,
    # asks each stage's agent profile to probe its filesystem, prints a
    # status table, and exits non-zero if any check is `:missing`.
    #
    # Pi rows always come back `:not_applicable` — pi has no
    # slash-command resolver. That's not a fail; the prompt text still
    # gets sent to the model.
    #
    # `--json` emits a machine-readable envelope so an agent caller
    # (the daemon, an outer orchestrator) can decide how to react
    # without scraping the human-readable table.
    class Doctor
      EXIT_SUCCESS = 0
      EXIT_MISSING_SKILL = 65
      EXIT_CONFIG_ERROR = 78

      STAGES = %w[brainstorm plan].freeze

      def initialize(config:, project_root:, json: false, output: $stdout)
        @config = config
        @project_root = project_root
        @json = json
        @output = output
      end

      def call
        rows = STAGES.map { |stage| check_stage(stage) }
        if @json
          @output.puts JSON.generate(envelope(rows))
        else
          render_table(rows)
        end

        rows.any? { |r| r[:status] == "missing" } ? EXIT_MISSING_SKILL : EXIT_SUCCESS
      rescue Hive::ConfigError, KeyError, ArgumentError => e
        if @json
          @output.puts JSON.generate(error: e.message)
        else
          @output.puts "hive doctor: #{e.message}"
        end
        EXIT_CONFIG_ERROR
      end

      private

      def check_stage(stage)
        agent_name = (@config.dig(stage, "agent") || "claude").to_s
        skill = @config.dig(stage, "skill") || Hive::Config::DEFAULTS.dig(stage, "skill")
        profile = Hive::AgentProfiles.lookup(agent_name.to_sym)

        status, message = profile.verify_skill(skill, project_root: @project_root)
        {
          stage: stage,
          agent: agent_name,
          skill: skill,
          status: status.to_s,
          message: message
        }
      end

      def envelope(rows)
        {
          "schema" => "hive-doctor.v1",
          "checks" => rows,
          "summary" => {
            "missing" => rows.count { |r| r[:status] == "missing" },
            "present" => rows.count { |r| r[:status] == "present" },
            "not_applicable" => rows.count { |r| r[:status] == "not_applicable" }
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

          @output.puts "[#{r[:stage]}/#{r[:agent]}] #{r[:message]}"
        end
      end

      def compute_widths(rows)
        {
          stage: column_width(rows, :stage, "stage"),
          agent: column_width(rows, :agent, "agent"),
          skill: column_width(rows, :skill, "skill"),
          status: column_width(rows, :status, "status")
        }
      end

      def column_width(rows, key, header)
        ([ header.length ] + rows.map { |r| r[key].to_s.length }).max
      end

      def header(widths)
        format("%-#{widths[:stage]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  %-#{widths[:status]}s",
               "stage", "agent", "skill", "status")
      end

      def separator(widths)
        format("%-#{widths[:stage]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  %-#{widths[:status]}s",
               "-" * widths[:stage], "-" * widths[:agent], "-" * widths[:skill], "-" * widths[:status])
      end

      def row_line(row, widths)
        marker = case row[:status]
        when "present" then "✓"
        when "missing" then "✗"
        when "not_applicable" then "—"
        else "?"
        end
        format("%-#{widths[:stage]}s  %-#{widths[:agent]}s  %-#{widths[:skill]}s  #{marker} %-#{widths[:status]}s",
               row[:stage], row[:agent], row[:skill], row[:status])
      end
    end
  end
end
