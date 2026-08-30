require "hive/config"
require "hive/recovery/migration"
require "hive/runtime_control_plane/cutover"

module Hive
  module Commands
    # Installation-wide runtime migration. Project files are only observed by
    # the cutover; no project is committed before the global activation intent.
    class MigrateAll
      def initialize(projects: nil, output: $stdout, input: $stdin, confirm: false, exclusions: [],
                     cutover: Hive::Recovery::Migration.method(:cutover))
        @projects = projects || Hive::Config.registered_projects
        @output = output
        @input = input
        @confirm = confirm
        @exclusions = exclusions
        @cutover = cutover
      end

      def call
        confirmation!
        @output.puts "hive: migration: irreversible fleet cutover; legacy runtime cannot be restored"
        @output.puts "hive: migration: preparing #{@projects.size} registered projects"
        result = @cutover.call(
          confirm: true, exclusions: @exclusions, projects: @projects
        )
        @output.puts "hive: migration: #{result.phase}"
        0
      end

      private

      def confirmation!
        return if @confirm
        unless @input.tty?
          raise Hive::RuntimeControlPlane::Cutover::ConfirmationRequired.new(
            "runtime cutover is irreversible and non-interactive input cannot confirm it",
            code: :confirmation_required, action: "hive migrate --all --yes"
          )
        end

        @output.puts "This fleet cutover cannot be rolled back. Type 'yes' to continue:"
        return if @input.gets&.strip == "yes"

        raise Hive::RuntimeControlPlane::Cutover::ConfirmationRequired.new(
          "runtime cutover was not confirmed", code: :confirmation_required,
          action: "hive migrate --all --yes"
        )
      end
    end
  end
end
