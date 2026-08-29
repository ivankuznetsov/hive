# frozen_string_literal: true

require "hive/runtime_control_plane"

module Hive
  module Babysitter
    # Shared process boundary for babysitter dry-run passthroughs. Policies
    # classify argv without side effects; this runner owns skip reporting,
    # absolute real-binary validation, environment preparation, handoff-error
    # mapping, and optional cleanup.
    class PassthroughRunner
      def initialize(tool:, argv:, allowed:, real_env_key:, skip_reporter:,
                     environment: ENV, prepare_environment: nil,
                     command_argv: nil, preflight: nil, executor: nil,
                     cleanup: nil)
        @tool = tool
        @argv = argv
        @allowed = allowed
        @real_env_key = real_env_key
        @skip_reporter = skip_reporter
        @environment = environment
        @prepare_environment = prepare_environment
        @command_argv = command_argv || -> { argv }
        @preflight = preflight
        @executor = executor || method(:exec_process)
        @cleanup = cleanup
      end

      def call
        unless @allowed
          warn @skip_reporter.call
          return 0
        end

        real = validated_real_binary
        return 127 unless real

        @prepare_environment&.call(@environment)
        preflight_status = @preflight&.call(real, @environment)
        return preflight_status if preflight_status

        @executor.call(real, Array(@command_argv.call), @environment)
      rescue SystemCallError => e
        warn "hive-babysitter dry-run: cannot exec real #{@tool} at #{real.inspect}: #{e.message}"
        127
      ensure
        @cleanup&.call
      end

      private

      def validated_real_binary
        real = @environment[@real_env_key].to_s
        if real.empty?
          warn "hive-babysitter dry-run: #{@real_env_key} is unset; " \
               "refusing to guess a path for the real #{@tool} binary"
          return nil
        end
        unless File.absolute_path?(real)
          warn "hive-babysitter dry-run: #{@real_env_key} must be an absolute path; " \
               "refusing to exec #{real.inspect}"
          return nil
        end

        real
      end

      def exec_process(real, argv, _environment)
        Hive::RuntimeControlPlane::ProcessGuard.exec(real, *argv)
      end
    end
  end
end
