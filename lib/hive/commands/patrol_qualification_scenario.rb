require "digest"
require "pathname"
require "hive/managed_directory"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_driver"
require "hive/modules/migration/qualification_scenario_input"
require "hive/modules/migration/qualification_scenario_request"

module Hive
  module Commands
    # Private candidate-side adapter for one descriptor-confined Patrol
    # qualification stimulus. It is routed before Thor and the wiki scheduler
    # so a qualification subprocess cannot mutate ambient Hive state.
    class PatrolQualificationScenario
      REQUEST_MODE = 0o600
      DIRECTORY_MODE = 0o700

      def self.from_argv(argv)
        unless
          argv.is_a?(Array) &&
            argv.length == 4 &&
            argv.fetch(0) == "--workspace" &&
            argv.fetch(2) == "--request"
          raise Hive::ConfigError,
                "patrol qualification scenario invocation is malformed"
        end
        new(
          workspace: argv.fetch(1),
          request_ref: argv.fetch(3)
        )
      end

      def initialize(workspace:, request_ref:)
        @workspace = workspace.to_s
        @request_ref = request_ref.to_s
      end

      def call
        workspace = validated_workspace
        directory = Hive::ManagedDirectory.new(
          root: workspace,
          label: "patrol qualification scenario workspace"
        )
        request = load_request(directory)
        unless
          @request_ref ==
            "requests/#{request.case_id}.json"
          raise Hive::ConfigError,
                "patrol qualification scenario request is unsafe"
        end
        validate_output_absent!(directory, request)
        scenario = load_scenario(directory, request)
        package_root = request.resolve(
          workspace,
          request.package_root_ref
        )
        validate_owned_directory!(package_root)
        sandbox_root = request.resolve(
          workspace,
          request.sandbox_root_ref
        )
        unless directory.entry_type(
          request.sandbox_root_ref,
          missing: true
        ).nil?
          raise Hive::ConfigError,
                "patrol qualification scenario sandbox is not empty"
        end
        result =
          Hive::Modules::Migration::
            QualificationScenarioDriver.new(
              candidate_source_root: package_root,
              sandbox_root: sandbox_root,
              project: request.project,
              scenario_input: scenario
            ).call
        actuals =
          Hive::Modules::Migration::
            QualificationScenarioActuals.from_h(
              "schema" =>
                Hive::Modules::Migration::
                  QualificationScenarioActuals::SCHEMA,
              "schema_version" =>
                Hive::Modules::Migration::
                  QualificationScenarioActuals::SCHEMA_VERSION,
              "actuals" => [ result.observation ]
            )
        directory.atomic_write(
          request.output_ref,
          Hive::Modules::Migration::
            QualificationScenarioActuals.canonical(actuals.to_h),
          mode: REQUEST_MODE,
          expected_absent: true
        )
        0
      rescue Hive::ManagedDirectory::UnsafeError
        raise Hive::ConfigError,
              "patrol qualification scenario workspace is unsafe"
      end

      private

      def validated_workspace
        path = @workspace
        pathname = Pathname.new(path)
        unless
          !path.empty? &&
            !path.include?("\0") &&
            pathname.absolute? &&
            path == File.expand_path(path)
          raise Hive::ConfigError,
                "patrol qualification scenario workspace is unsafe"
        end
        validate_owned_directory!(path)
        unless File.realpath(path) == path
          raise Hive::ConfigError,
                "patrol qualification scenario workspace is unsafe"
        end
        path.freeze
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
             Errno::ELOOP, ArgumentError
        raise Hive::ConfigError,
              "patrol qualification scenario workspace is unsafe"
      end

      def load_request(directory)
        snapshot = directory.read_with_metadata(
          request_ref,
          max_bytes:
            Hive::Modules::Migration::
              QualificationScenarioRequest::MAX_BYTES
        )
        unless snapshot.fetch(:mode) == REQUEST_MODE
          raise Hive::ConfigError,
                "patrol qualification scenario request is unsafe"
        end
        Hive::Modules::Migration::
          QualificationScenarioRequest.load(
            snapshot.fetch(:bytes)
          )
      rescue KeyError
        raise Hive::ConfigError,
              "patrol qualification scenario request is unsafe"
      end

      def request_ref
        value = @request_ref
        unless
          value.match?(
            %r{\Arequests/[a-z0-9][a-z0-9._-]{0,127}\.json\z}
          )
          raise Hive::ConfigError,
                "patrol qualification scenario request is unsafe"
        end
        value
      end

      def load_scenario(directory, request)
        snapshot = directory.read_with_metadata(
          request.scenario_ref,
          max_bytes:
            Hive::Modules::Migration::
              QualificationScenarioInput::MAX_BYTES
        )
        unless
          snapshot.fetch(:mode) == REQUEST_MODE &&
            Digest::SHA256.hexdigest(snapshot.fetch(:bytes)) ==
              request.scenario_sha256
          raise Hive::ConfigError,
                "patrol qualification scenario digest changed"
        end
        Hive::Modules::Migration::
          QualificationScenarioInput.load(
            snapshot.fetch(:bytes),
            expected_case_id: request.case_id
          )
      rescue KeyError
        raise Hive::ConfigError,
              "patrol qualification scenario input is unsafe"
      end

      def validate_output_absent!(directory, request)
        return if directory.entry_type(
          request.output_ref,
          missing: true
        ).nil?

        raise Hive::ConfigError,
              "patrol qualification scenario output already exists"
      end

      def validate_owned_directory!(path)
        stat = File.lstat(path)
        unless
          stat.directory? &&
            !stat.symlink? &&
            stat.uid == Process.euid &&
            (stat.mode & 0o777) == DIRECTORY_MODE
          raise Hive::ConfigError,
                "patrol qualification scenario workspace is unsafe"
        end
        true
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR,
             Errno::ELOOP
        raise Hive::ConfigError,
              "patrol qualification scenario workspace is unsafe"
      end
    end
  end
end
