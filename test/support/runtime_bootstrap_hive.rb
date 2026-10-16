require "json"

module Sequel
  class Error < StandardError; end
end

module Thor
  class Error < StandardError; end
end

module Hive
  VERSION = "test"

  class Error < StandardError
    attr_reader :code, :action, :details, :exit_code

    def initialize(message, code: nil, action: nil, details: {}, exit_code: 70)
      super(message)
      @code, @action, @details, @exit_code = code, action, details, exit_code
    end
  end

  module Paths
    module_function

    def state_home = ENV.fetch("HIVE_HOME", "/state")
  end

  module Schemas
    module ErrorEnvelope
      module_function

      def build(schema:, error:, error_kind:, extras: {})
        {
          "schema" => schema, "ok" => false, "error_kind" => error_kind,
          "message" => error.message, "exit_code" => error.exit_code
        }.merge(extras)
      end
    end
  end

  module RuntimeControlPlane
    module Codec
      module_function

      def normalize(value) = value
    end

    class Error < Hive::Error; end
    class Unavailable < Error; end

    def self.storage_error
      Unavailable.new(
        "Hive state is mounted read-only", code: :state_storage_read_only,
        action: "Use a writable, accessible state root (HIVE_HOME)."
      )
    end

    module ActivationGate
      module_function

      def check!(argv:)
        raise RuntimeControlPlane.storage_error if ENV["BOOTSTRAP_SCENARIO"] == "activation_failure"
        true
      end

      def command(argv) = Array(argv).find { |word| !word.start_with?("-") }
      def strict_no_write_route?(_argv) = false
    end

    class Registration
      def finish!
        BootstrapFixture.event("finish")
        raise RuntimeControlPlane.storage_error
      end
    end

    module CommandRegistration
      CHILD_RESERVATION_ENV = "HIVE_RUNTIME_CHILD_RESERVATION_ID"

      class << self
        attr_reader :current

        def start!(argv:)
          if ENV["BOOTSTRAP_SCENARIO"] == "registration_failure"
            @fallback_safe = true
            raise RuntimeControlPlane.storage_error
          end
          @current = Registration.new if ENV["BOOTSTRAP_SCENARIO"] == "finish_failure"
        end

        def fallback_safe_after_failure? = @fallback_safe == true
      end
    end

    module OperationalInspection
      module_function

      def activate_from_failure(error:, argv:, state_home:, inherited_reservation: false)
        eligible = argv.first == "status" && argv.include?("--operational")
        confirmed = ENV.fetch("BOOTSTRAP_CONFIRMED", "0") == "1"
        BootstrapFixture.event(
          "activate:#{eligible}:#{confirmed}:#{inherited_reservation}:#{state_home}:#{error.code}"
        )
        @active = eligible && confirmed && !inherited_reservation
      end

      def active? = @active == true

      def clear!
        BootstrapFixture.event("clear")
        @active = false
      end
    end
  end

  module LlmWikiBootstrap
    module Scheduler
      module_function

      def reconcile_existing! = true
    end
  end

  module CliJsonOptions
    BOOLEAN_OPTIONS = [].freeze
  end

  module CliArgvPolicy
    module_function

    def validate_encoding(argv) = argv
    def new_text_start_index(_argv, value_options:) = 0
    def reject_unsupported_json_assignments(argv, before_index:) = argv
    def normalize_leading_json_options(argv) = argv
    def rewrite_help(argv, text_start_index:) = argv
    def lift_new_options(argv, value_options:) = argv
    def one_shot_requested?(_argv) = false
    def json_requested?(argv) = argv.include?("--json")
  end

  module CliUsageContracts
    module_function

    def contract(*) = nil
  end

  module OneShot
    module Result
      class ReportedError < Hive::Error; end
    end
  end

  module CLI
    module_function

    def start(_argv, debug:) = debug
  end
end

module BootstrapFixture
  module_function

  def event(value)
    path = ENV["BOOTSTRAP_EVENTS"]
    File.open(path, "a") { |file| file.puts(value) } if path
  end
end

%w[
  hive/runtime_control_plane/activation_gate.rb
  hive/runtime_control_plane/command_registration.rb
  hive/runtime_control_plane/operational_inspection.rb
  hive/schemas.rb
  hive/llm_wiki_bootstrap.rb
  hive/cli.rb
  hive/cli_argv_policy.rb
  hive/cli_json_options.rb
  hive/cli_usage_contracts.rb
  hive/one_shot/result.rb
].each { |feature| $LOADED_FEATURES << feature }
