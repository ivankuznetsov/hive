require "json"
require "hive"

module Hive
  module Commands
    class Module
      SUBCOMMANDS = %w[install update enable disable uninstall list].freeze

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
                     yes: false, dry_run: false, receipt: nil, settings: [], hooks: [], grants: [])
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
        if @subcommand == "list"
          raise UsageError.new("module list does not accept a name", value: @subject) if @subject
          require "hive/commands/module/list"
          return List.new(project_root: @project_root, json: @json, stdout: @stdout).call
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
        else
          require "hive/commands/module/#{@subcommand}"
          self.class.const_get(@subcommand.capitalize, false).new(@subject, **common)
        end
      end

      def schema_for_subcommand
        @subcommand == "list" ? "hive-module-list" : "hive-module-lifecycle"
      end
    end
  end
end
