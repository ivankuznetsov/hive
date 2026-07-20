require "json"
require "shellwords"

require "hive"
require "hive/agent_skills/provisioner"

module Hive
  module Commands
    class SetupAgents
      def initialize(config:, project_root:, yes: false, json: false,
                     agents: nil, skills: nil, provisioner: nil,
                     input: $stdin, output: $stdout, error: $stderr,
                     consent_provenance: nil)
        @config = config
        @project_root = project_root
        @yes = yes
        @json = json
        @agents = agents
        @skills = skills
        @input = input
        @output = output
        @error = error
        @consent_provenance = consent_provenance
        @provisioner = provisioner || Hive::AgentSkills::Provisioner.new(
          config: config, project_root: project_root
        )
      end

      def call
        emit(run)
      rescue Hive::ConfigError, Hive::AgentSkills::Manifest::ValidationError, KeyError, ArgumentError => e
        emit_config_error(e)
      end

      # Shared coordinator entrypoint for `hive setup`. It preserves the exact
      # preview, consent, and revalidation lifecycle without emitting a nested
      # JSON envelope; callers receive the typed provisioning result instead.
      def run
        plan = @provisioner.build_plan(agents: @agents, skills: @skills)
        render_plan(plan) unless @json
        return @provisioner.noop_result(plan) if plan.operations.empty?

        provenance = consent_provenance
        return @provisioner.refusal_result(plan, provenance: refusal_provenance) unless provenance

        revised, changed = @provisioner.revalidate(plan)
        if changed
          plan = revised
          render_changed_plan(plan) unless @json
          return @provisioner.noop_result(plan) if plan.operations.empty?
          unless automatic_consent?
            return @provisioner.refusal_result(plan, provenance: "revalidation_declined") unless confirm?
            provenance = "interactive_revalidated"
          end
        end

        @provisioner.execute(plan, consent_provenance: provenance)
      end

      private

      def consent_provenance
        return @consent_provenance if @consent_provenance
        return "yes_flag" if @yes
        return nil if @json || !interactive?
        confirm? ? "interactive" : nil
      end

      def automatic_consent?
        @yes || !@consent_provenance.nil?
      end

      def refusal_provenance
        return "json_requires_yes" if @json
        return "non_tty" unless interactive?
        "declined"
      end

      def interactive?
        @input.respond_to?(:tty?) && @input.tty?
      rescue IOError
        false
      end

      def confirm?
        @error.print "Proceed? [y/N]: "
        @error.flush
        answer = @input.gets
        %w[y yes].include?(answer.to_s.strip.downcase)
      end

      def render_plan(plan)
        @output.puts "Agent skill provisioning plan"
        plan.inspections.each do |row|
          @output.puts "  #{row.agent}/#{row.capability_id || row.target.configured_skill}: #{row.health} — #{row.explanation}"
        end
        if plan.operations.empty?
          @output.puts "No managed agent skill changes are planned."
          return
        end
        plan.operations.each do |operation|
          command = if operation.kind == "bundled_skill_publish"
            "(Hive atomic directory publish)"
          elsif operation.argv.empty?
            "(Hive atomic file write)"
          else
            Shellwords.join(operation.argv)
          end
          @output.puts "  [#{operation.id}] #{command}"
          operation.files.each { |path| @output.puts "    file: #{path}" }
          @output.puts "    after: #{operation.depends_on.join(', ')}" unless operation.depends_on.empty?
        end
        plan.conflicts.each { |conflict| @output.puts "  conflict: #{conflict}" }
      end

      def render_changed_plan(plan)
        @output.puts "State changed after preview; revised plan:"
        render_plan(plan)
      end

      def render_result(result)
        @output.puts "Agent skill setup: #{result.classification} (exit #{result.exit_code})"
        result.operation_results.each do |outcome|
          @output.puts "  #{outcome.operation_id}: #{outcome.status} — #{outcome.message}"
        end
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(payload(result))
        else
          render_result(result)
        end
        result.exit_code
      end

      def payload(result)
        skips = result.final_health.select { |row| row.health == "unavailable" }.map(&:to_h)
        skips.concat(result.operation_results.select { |outcome| outcome.status == "skipped" }.map(&:to_h))
        {
          "schema" => "hive-setup-agents",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-setup-agents"),
          "ok" => result.exit_code.zero?,
          "preview" => result.preview.to_h,
          "consent" => result.consent,
          "operation_results" => result.operation_results.map(&:to_h),
          "final_health" => result.final_health.map(&:to_h),
          "skips" => skips,
          "exit_code" => result.exit_code,
          "classification" => result.classification
        }
      end

      def emit_config_error(error)
        if @json
          @output.puts JSON.generate(
            "schema" => "hive-setup-agents",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-setup-agents"),
            "ok" => false,
            "exit_code" => Hive::ExitCodes::CONFIG,
            "classification" => "invalid_config",
            "error_class" => error.class.name,
            "message" => error.message
          )
        else
          @error.puts "hive setup-agents: #{error.message}"
        end
        Hive::ExitCodes::CONFIG
      end
    end
  end
end
