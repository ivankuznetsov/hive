require "json"
require "hive"

module Hive
  module Commands
    class Module
      SUBCOMMANDS = %w[install update enable disable uninstall list inspect status doctor dry-run migration].freeze

      class UsageError < Hive::Error
        attr_reader :value, :expected

        def initialize(message, value: nil, expected: nil)
          super(message)
          @value = value
          @expected = expected
        end

        def exit_code = Hive::ExitCodes::USAGE
      end

      def initialize(subcommand, subject = nil, project_root: Dir.pwd, json: false, stdout: $stdout,
                     yes: false, dry_run: false, receipt: nil, settings: [], hooks: [], grants: [],
                     event_name: nil, schedule: nil, occurred_at: nil, reviewer: nil)
        @subcommand = subcommand
        @subject = subject
        @project_root = project_root
        @json = json
        @stdout = stdout
        @yes = yes
        @dry_run = dry_run
        @receipt = receipt
        @settings = settings
        @hooks = hooks
        @grants = grants
        @event_name = event_name
        @schedule = schedule
        @occurred_at = occurred_at
        @reviewer = reviewer
      end

      def call
        call!
      rescue UsageError, Hive::Error, SystemCallError, IOError => e
        if @json
          @stdout.puts JSON.generate(
            Hive::Schemas::ErrorEnvelope.build(
              schema: schema_for_subcommand, error: e,
              error_kind: e.is_a?(UsageError) ? "usage" : "error"
            )
          )
        else
          warn "hive module: #{e.message}"
        end
        exit(e.respond_to?(:exit_code) ? e.exit_code : Hive::ExitCodes::GENERIC)
      end

      def call!
        expected = SUBCOMMANDS.join(", ")
        raise UsageError.new("missing SUBCOMMAND (expected: #{expected})", expected: SUBCOMMANDS) unless @subcommand
        unless SUBCOMMANDS.include?(@subcommand)
          raise UsageError.new(
            "unknown module subcommand #{@subcommand.inspect} (expected: #{expected})",
            value: @subcommand, expected: SUBCOMMANDS
          )
        end
        if @subcommand == "migration"
          raise UsageError, "module migration requires status, report, cutover, or rollback" if @subject.to_s.empty?
          require "hive/commands/module/migration"
          return Migration.new(
            @subject, project_root: @project_root, json: @json, stdout: @stdout,
            yes: @yes, reviewer: @reviewer
          ).call
        end
        if %w[list status].include?(@subcommand) && @subject.nil?
          require "hive/commands/module/#{@subcommand}"
          command_class = self.class.const_get(@subcommand.capitalize, false)
          arguments = @subcommand == "status" ? [ "" ] : []
          return command_class.new(*arguments, project_root: @project_root, json: @json, stdout: @stdout).call
        end
        raise UsageError.new("module #{@subcommand} requires a source or name") if @subject.to_s.empty?
        command.call
      end

      private

      def command
        common = {
          project_root: @project_root, json: @json, stdout: @stdout,
          yes: @yes, dry_run: @dry_run, receipt: @receipt
        }
        case @subcommand
        when "install"
          require "hive/commands/module/install"
          Install.new(@subject, **common, settings: @settings, hooks: @hooks, grants: @grants)
        when "update"
          require "hive/commands/module/update"
          Update.new(@subject, **common, settings: @settings, hooks: @hooks, grants: @grants)
        when "dry-run"
          raise UsageError, "module dry-run requires --event" if @event_name.to_s.empty?
          require "hive/commands/module/dry_run"
          DryRun.new(
            @subject, **common, event_name: @event_name, hook_id: Array(@hooks).first,
            schedule: @schedule, occurred_at: @occurred_at
          )
        else
          require "hive/commands/module/#{@subcommand}"
          self.class.const_get(@subcommand.capitalize, false).new(@subject, **common)
        end
      end

      def schema_for_subcommand
        case @subcommand
        when "list" then "hive-module-list"
        when "inspect", "status" then "hive-module-status"
        when "doctor" then "hive-module-doctor"
        when "dry-run" then "hive-module-dry-run"
        when "migration"
          @subject == "report" ? "hive-module-migration-report" : "hive-module-migration"
        else "hive-module-lifecycle"
        end
      end
    end
  end
end
