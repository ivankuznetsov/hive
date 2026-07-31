require "fileutils"
require "find"
require "json"
require "hive/errors"
require "hive/config"
require "hive/managed_directory"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_lane_result"
require "hive/modules/migration/qualification_lane_runner"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/modules/migration/trusted_qualification_control"
require "hive/workflow_package/canonical_json"
require_relative "../../../packaging/patrol_evidence/candidate"
require_relative "path_safety"
require_relative "paths"
require_relative "patrol_qualification_control_provider"
require_relative "patrol_qualification_plan"

module Hive
  module E2E
    # Source-side controller for the compressed Patrol qualification scenario.
    # Production descriptor/repository objects own authority and persistence;
    # this adapter only prepares and executes the two exact command targets,
    # then copies their already-verified result into the E2E artifact tree.
    class PatrolQualificationRunner
      RUN_ID =
        Hive::Modules::Migration::QualificationRunDescriptor::RUN_ID
      REQUIRED_COVERAGE_ID =
        "module.patrol_compressed_evidence".freeze
      DIAGNOSTIC_COVERAGE_ID =
        "module.patrol_compressed_evidence_diagnostic".freeze
      LOCAL_COMPLETE_BLOCKERS = %w[
        qualification_control_untrusted
        qualification_control_not_independent
      ].freeze
      RESULT_SCHEMA =
        "hive-patrol-qualification-harness-result".freeze
      RESULT_MAX_BYTES = 64 * 1024
      CleanupEntry = Data.define(
        :path, :device, :inode, :directory, :handle, :children
      )
      CleanupTree = Data.define(
        :root, :device, :inode, :entries, :directories
      )

      class CleanupFailure < Hive::ConfigError
        attr_reader :primary, :cleanup

        def initialize(primary:, cleanup:)
          @primary = primary
          @cleanup = cleanup
          super(
            "patrol qualification failed " \
            "(#{primary.class}: #{primary.message}); " \
            "#{cleanup.message}"
          )
        end
      end

      class << self
        def coverage_complete?(result, coverage_id:)
          case coverage_id.to_s
          when REQUIRED_COVERAGE_ID
            harness_complete?(result)
          when DIAGNOSTIC_COVERAGE_ID
            diagnostic_complete?(result)
          else
            false
          end
        end

        def harness_complete?(result)
          complete?(result, allow_diagnostic: false)
        end

        def diagnostic_complete?(result)
          complete?(result, allow_diagnostic: true)
        end

        private

        def complete?(result, allow_diagnostic:)
          return false unless
            result.is_a?(Hash) &&
              result.keys.sort ==
                %w[artifacts_dir run_id status]
          path = File.join(
            result.fetch("artifacts_dir"),
            "result.json"
          )
          stat = File.lstat(path)
          return false unless
            stat.file? &&
              !stat.symlink? &&
              stat.nlink == 1 &&
              stat.uid == Process.euid &&
              stat.size <= RESULT_MAX_BYTES &&
              (stat.mode & 0o777) == 0o600
          bytes = File.binread(path)
          value = JSON.parse(bytes)
          return false unless
            bytes == canonical(value) &&
              value.keys.sort == %w[
                blockers candidate_sha control deterministic
                installed run_id schema schema_version status
              ] &&
              value.fetch("schema") == RESULT_SCHEMA &&
              value.fetch("schema_version") == 1 &&
              value.fetch("run_id") == result.fetch("run_id") &&
              value.fetch("status") == result.fetch("status") &&
              RUN_ID.match?(value.fetch("run_id").to_s) &&
              value.fetch("candidate_sha").is_a?(String) &&
              value.fetch("candidate_sha").match?(
                /\A[0-9a-f]{40}\z/
              ) &&
              value.fetch("blockers").is_a?(Array)
          control =
            Hive::Modules::Migration::
              TrustedQualificationControl.normalize(
                value.fetch("control")
              )
          deterministic = lane(value, "deterministic")
          installed = lane(value, "installed")
          qualifying_outcome?(
            value,
            control: control,
            deterministic: deterministic,
            installed: installed
          ) || (
            allow_diagnostic &&
              diagnostic_outcome?(
                value,
                control: control,
                deterministic: deterministic,
                installed: installed
              )
          )
        rescue Hive::ConfigError, JSON::ParserError,
               EncodingError, KeyError, NoMethodError,
               TypeError, SystemCallError
          false
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def lane(value, name)
          result =
            Hive::Modules::Migration::
              QualificationLaneResult.load(
                canonical(value.fetch(name))
              )
          raise Hive::ConfigError, "lane changed" unless
            result.lane == name &&
              result.run_id == value.fetch("run_id")
          result
        end

        def qualifying_outcome?(
          value, control:, deterministic:, installed:
        )
          candidate_sha = value.fetch("candidate_sha")
          value.fetch("status") ==
            "evidence_ready_for_operator" &&
            value.fetch("blockers").empty? &&
            independent_control?(control, candidate_sha) &&
            deterministic.passed? &&
            installed.passed?
        end

        def diagnostic_outcome?(
          value, control:, deterministic:, installed:
        )
          candidate_sha = value.fetch("candidate_sha")
          status = value.fetch("status")
          blockers = value.fetch("blockers")
          if status == "evidence_required"
            return (
              control.fetch("trust_scope") == "local" &&
                control.fetch("ref").nil? &&
                control.fetch("commit_sha") == candidate_sha &&
                blockers == LOCAL_COMPLETE_BLOCKERS &&
                deterministic.passed? &&
                live_not_authorized?(installed)
            )
          end

          status == "deterministic_evidence_ready" &&
            blockers.empty? &&
            independent_control?(control, candidate_sha) &&
            deterministic.passed? &&
            live_not_authorized?(installed)
        end

        def independent_control?(control, candidate_sha)
          control.fetch("trust_scope") == "trusted_remote" &&
            control.fetch("ref") ==
              Hive::Modules::Migration::
                TrustedQualificationControl::TRUSTED_REF &&
            control.fetch("commit_sha") != candidate_sha
        end

        def live_not_authorized?(installed)
          installed.blocked? &&
            installed.failure_reason ==
              "live_lane_not_authorized"
        end
      end

      def initialize(
        repo_root: Paths.repo_root,
        candidate_preparer_factory: nil,
        plan: PatrolQualificationPlan.new,
        control_provider: nil,
        repository_factory: nil,
        lane_runner_factory: nil,
        workspace_remover: nil
      )
        @repo_root = File.expand_path(repo_root)
        @candidate_preparer_factory =
          candidate_preparer_factory ||
          lambda do |workspace|
            HivePatrolEvidence::CandidatePreparer.new(
              repo_root: @repo_root,
              workspace: workspace
            )
          end
        @plan = plan
        @control_provider =
          control_provider ||
          lambda do |candidate_sha:|
            PatrolQualificationControlProvider.new(
              repo_root: @repo_root
            ).call(candidate_sha: candidate_sha)
          end
        @repository_factory =
          repository_factory || method(:repository_for)
        @lane_runner_factory =
          lane_runner_factory ||
          lambda do |repository|
            Hive::Modules::Migration::
              QualificationLaneRunner.new(
                repository: repository
              )
          end
        @workspace_remover =
          workspace_remover ||
          FileUtils.method(:remove_entry_secure)
      end

      def call(project_root:, run_home:, artifacts_root:)
        workspace = nil
        begin
          project = private_directory!(
            project_root,
            label: "project",
            private: false
          )
          private_directory!(
            run_home,
            label: "run home"
          )
          artifacts = prepare_artifacts_root(artifacts_root)
          workspace_path =
            File.join(artifacts, ".candidate-preparation")
          Dir.mkdir(workspace_path, 0o700)
          workspace = workspace_path
          candidate =
            @candidate_preparer_factory.call(workspace).call
          control = @control_provider.call(
            candidate_sha: candidate.candidate_sha
          )
          unless
            control.is_a?(
              Hive::Modules::Migration::
                TrustedQualificationControl
            )
            raise Hive::ConfigError,
                  "patrol qualification trusted control is unavailable"
          end
          prepared = @plan.call(
            candidate: candidate,
            control: control
          )
          repository = @repository_factory.call(project)
          run_id = repository.import_qualification_run(
            descriptor_bytes: prepared.descriptor_bytes,
            inputs: prepared.inputs
          )
          unless run_id == prepared.run_id &&
                 RUN_ID.match?(run_id)
            raise Hive::ConfigError,
                  "patrol qualification imported run identity changed"
          end
          remove_workspace(workspace)
          workspace = nil
          runner = @lane_runner_factory.call(repository)
          deterministic = runner.call(
            run_id: run_id,
            lane: "deterministic",
            live_authorized: false
          )
          installed = runner.call(
            run_id: run_id,
            lane: "installed",
            live_authorized: false
          )
          control_blockers =
            control.qualification_issues(
              candidate.candidate_sha
            )
          status = aggregate_status(
            deterministic,
            installed,
            control_blockers: control_blockers
          )
          run_dir = publish_capture(
            artifacts: artifacts,
            repository: repository,
            prepared: prepared,
            candidate: candidate,
            deterministic: deterministic,
            installed: installed,
            control: control.payload,
            blockers: control_blockers,
            status: status
          )
          result = {
            "run_id" => run_id,
            "status" => status,
            "artifacts_dir" => run_dir
          }.freeze
        rescue HivePatrolEvidence::Error => error
          failure = Hive::ConfigError.new(
            "patrol qualification candidate is unavailable: " \
            "#{error.message}"
          )
          begin
            raise failure, cause: error
          rescue Hive::ConfigError => normalized
            cleanup_after_failure(workspace, normalized)
            raise
          end
        rescue StandardError => error
          cleanup_after_failure(workspace, error)
          raise
        else
          remove_workspace(workspace)
          result
        end
      end

      private

      def repository_for(project_root)
        config = Hive::Config.load(project_root)
        state = File.expand_path(
          config.fetch("hive_state_path"),
          project_root
        )
        Hive::Modules::Migration::MigrationRepository.for(
          project_root: project_root,
          hive_state_path: state
        )
      rescue KeyError
        raise Hive::ConfigError,
              "patrol qualification project state is unavailable"
      end

      def aggregate_status(
        deterministic, installed, control_blockers:
      )
        unless lane_result?(
          deterministic,
          lane: "deterministic"
        ) && lane_result?(installed, lane: "installed")
          raise Hive::ConfigError,
                "patrol qualification lane outcome is malformed"
        end
        return "failed" unless deterministic.passed?
        if
          !control_blockers.empty? &&
            (
              installed.passed? ||
                (
                  installed.blocked? &&
                    installed.failure_reason ==
                      "live_lane_not_authorized"
                )
            )
          return "evidence_required"
        end
        return "evidence_ready_for_operator" if
          installed.passed?
        if
          installed.blocked? &&
            installed.failure_reason ==
              "live_lane_not_authorized"
          return "deterministic_evidence_ready"
        end

        installed.blocked? ? "blocked" : "failed"
      end

      def lane_result?(value, lane:)
        value.is_a?(
          Hive::Modules::Migration::QualificationLaneResult
        ) &&
          value.lane == lane
      end

      def publish_capture(
        artifacts:, repository:, prepared:, candidate:,
        deterministic:, installed:, control:, blockers:, status:
      )
        run_dir = File.join(artifacts, prepared.run_id)
        if File.exist?(run_dir) || File.symlink?(run_dir)
          raise Hive::ConfigError,
                "patrol qualification artifact run already exists"
        end
        Dir.mkdir(run_dir, 0o700)
        directory = Hive::ManagedDirectory.new(
          root: run_dir,
          anchor: artifacts,
          label: "patrol qualification harness artifacts"
        )
        directory.prepare!
        directory.atomic_write(
          "descriptor.json",
          prepared.descriptor_bytes,
          mode: 0o600,
          expected_absent: true
        )
        directory.atomic_write(
          "candidate-manifest.json",
          candidate.manifest_bytes,
          mode: 0o600,
          expected_absent: true
        )
        directory.atomic_write(
          "scenario-manifest.json",
          repository.qualification_input(
            prepared.run_id,
            "inputs/scenarios/manifest.json"
          ),
          mode: 0o600,
          expected_absent: true
        )
        {
          "deterministic" => deterministic,
          "installed" => installed
        }.each do |lane, result|
          publish_lane(
            directory,
            repository: repository,
            run_id: prepared.run_id,
            lane: lane,
            result: result
          )
        end
        aggregate = canonical(
          "schema" => RESULT_SCHEMA,
          "schema_version" => 1,
          "run_id" => prepared.run_id,
          "candidate_sha" => candidate.candidate_sha,
          "control" => control,
          "status" => status,
          "blockers" => blockers,
          "deterministic" => deterministic.to_h,
          "installed" => installed.to_h
        )
        # The aggregate is the harness completion sentinel and is always last.
        directory.atomic_write(
          "result.json",
          aggregate,
          mode: 0o600,
          expected_absent: true
        )
        run_dir.freeze
      rescue StandardError => error
        cleanup_after_failure(run_dir, error)
        raise
      end

      def publish_lane(
        directory, repository:, run_id:, lane:, result:
      )
        files = captured_lane(
          repository,
          run_id: run_id,
          lane: lane,
          result: result
        )
        files.keys.sort.each do |relative|
          mode = relative == "repro.sh" ? 0o700 : 0o600
          directory.atomic_write(
            "lanes/#{lane}/#{relative}",
            files.fetch(relative),
            mode: mode,
            expected_absent: true
          )
        end
      end

      def captured_lane(repository, run_id:, lane:, result:)
        if result.blocked?
          matching =
            repository.qualification_lane_diagnostics(
              run_id, lane
            ).select do |diagnostic|
              diagnostic.to_h == result.to_h
            end
          unless matching.one?
            raise Hive::ConfigError,
                  "patrol qualification lane result changed"
          end
          return {
            "result.json" =>
              Hive::Modules::Migration::
                QualificationLaneResult.canonical(
                  matching.first.to_h
                )
          }.freeze
        end

        result_bytes = repository.qualification_lane_result(
          run_id, lane
        )
        unless
          Hive::Modules::Migration::QualificationLaneResult
            .load(result_bytes).to_h == result.to_h
          raise Hive::ConfigError,
                "patrol qualification lane result changed"
        end

        begin
          repository.qualification_lane(run_id, lane)
        rescue Hive::ConfigError
          raise if result.passed?

          { "result.json" => result_bytes }.freeze
        end
      end

      def prepare_artifacts_root(value)
        path = File.expand_path(value)
        if File.exist?(path) || File.symlink?(path)
          private_directory!(
            path,
            label: "artifacts root"
          )
          unless Dir.children(path).empty?
            raise Hive::ConfigError,
                  "patrol qualification artifacts root is not empty"
          end
          return path.freeze
        end

        parent = File.dirname(path)
        private_directory!(
          parent,
          label: "artifacts parent",
          private: false
        )
        Dir.mkdir(path, 0o700)
        path.freeze
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        raise Hive::ConfigError,
              "patrol qualification artifacts root is unsafe"
      end

      def private_directory!(value, label:, private: true)
        path = File.expand_path(value)
        stat = File.lstat(path)
        unless
          stat.directory? &&
            !stat.symlink? &&
            stat.uid == Process.euid &&
            File.realpath(path) == path &&
            (!private || (stat.mode & 0o077).zero?)
          raise Hive::ConfigError,
                "patrol qualification #{label} is unsafe"
        end
        path.freeze
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        raise Hive::ConfigError,
              "patrol qualification #{label} is unsafe"
      end

      def remove_workspace(path)
        return unless path &&
                      (
                        File.exist?(path) ||
                          File.symlink?(path)
                      )

        root = File.expand_path(path)
        cleanup_unsafe! if root == File::SEPARATOR
        tree = inspect_cleanup_tree(root)
        begin
          verify_cleanup_tree!(tree)
          tree.directories.each do |entry|
            stat = entry.handle.stat
            cleanup_unsafe! unless
              cleanup_identity?(entry, stat) &&
                cleanup_directory_stat?(
                  stat, device: tree.device
                )
            entry.handle.chmod(0o700)
          end
          verify_cleanup_tree!(tree)
          @workspace_remover.call(root)
          begin
            File.lstat(root)
          rescue Errno::ENOENT
            return nil
          end
          cleanup_unsafe!
        ensure
          close_cleanup_tree(tree)
        end
      rescue Hive::ConfigError
        raise
      rescue SystemCallError, IOError, ArgumentError
        cleanup_unsafe!
      end

      def cleanup_after_failure(path, primary)
        remove_workspace(path)
      rescue Hive::ConfigError => cleanup
        failure = CleanupFailure.new(
          primary: primary,
          cleanup: cleanup
        )
        raise failure, cause: primary
      end

      def cleanup_unsafe!
        raise Hive::ConfigError,
              "patrol qualification cleanup target is unsafe"
      end

      def inspect_cleanup_tree(root)
        handles = []
        root_entry = open_cleanup_directory!(
          root,
          device: nil,
          private: true
        )
        handles << root_entry.handle
        entries = [ root_entry ]
        directories = [ root_entry ]
        Find.find(root) do |path|
          next if path == root

          cleanup_unsafe! unless
            PathSafety.contained?(root, path)
          stat = File.lstat(path)
          entry =
            if stat.directory?
              open_cleanup_directory!(
                path,
                device: root_entry.device,
                observed: stat
              )
            else
              inspect_cleanup_regular!(
                path,
                device: root_entry.device,
                observed: stat
              )
            end
          entries << entry
          if entry.directory
            handles << entry.handle
            directories << entry
          end
        end
        CleanupTree.new(
          root: root.freeze,
          device: root_entry.device,
          inode: root_entry.inode,
          entries: entries.freeze,
          directories: directories.freeze
        )
      rescue StandardError
        handles&.reverse_each { |handle| close_cleanup_handle(handle) }
        raise
      end

      def verify_cleanup_tree!(tree)
        tree.entries.each do |entry|
          if entry.directory
            verify_cleanup_directory!(
              entry, device: tree.device
            )
          else
            current = inspect_cleanup_regular!(
              entry.path,
              device: tree.device
            )
            cleanup_unsafe! unless
              current.device == entry.device &&
                current.inode == entry.inode
          end
        end
        root = tree.directories.first
        cleanup_unsafe! unless
          root.device == tree.device &&
            root.inode == tree.inode
        true
      end

      def verify_cleanup_directory!(entry, device:)
        descriptor = entry.handle.stat
        binding = File.lstat(entry.path)
        cleanup_unsafe! unless
          cleanup_identity?(entry, descriptor) &&
            cleanup_identity?(entry, binding) &&
            cleanup_directory_stat?(
              descriptor, device: device
            ) &&
            cleanup_directory_stat?(
              binding, device: device
            ) &&
            File.realpath(entry.path) ==
              File.expand_path(entry.path) &&
            cleanup_directory_children(entry.handle) ==
              entry.children
        true
      end

      def open_cleanup_directory!(
        path, device:, observed: nil, private: false
      )
        cleanup_no_follow_available!
        observed ||= File.lstat(path)
        valid_observation =
          if device
            cleanup_directory_stat?(
              observed, device: device
            )
          else
            cleanup_owned_directory_stat?(observed)
          end
        cleanup_unsafe! unless valid_observation
        handle = File.open(
          path,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK
        )
        descriptor = handle.stat
        expected_device = device || descriptor.dev
        unless
          cleanup_directory_stat?(
            observed, device: expected_device
          ) &&
            cleanup_directory_stat?(
              descriptor, device: expected_device
            ) &&
            observed.dev == descriptor.dev &&
            observed.ino == descriptor.ino &&
            File.realpath(path) == File.expand_path(path) &&
            (
              !private ||
                (descriptor.mode & 0o077).zero?
            )
          cleanup_unsafe!
        end
        CleanupEntry.new(
          path: File.expand_path(path).freeze,
          device: descriptor.dev,
          inode: descriptor.ino,
          directory: true,
          handle: handle,
          children: cleanup_directory_children(handle)
        )
      rescue StandardError
        close_cleanup_handle(handle)
        raise
      end

      def inspect_cleanup_regular!(
        path, device:, observed: nil
      )
        cleanup_no_follow_available!
        observed ||= File.lstat(path)
        cleanup_unsafe! unless
          cleanup_regular_stat?(
            observed, device: device
          )
        handle = File.open(
          path,
          File::RDONLY | File::NOFOLLOW | File::NONBLOCK
        )
        descriptor = handle.stat
        unless
          cleanup_regular_stat?(
            observed, device: device
          ) &&
            cleanup_regular_stat?(
              descriptor, device: device
            ) &&
            observed.dev == descriptor.dev &&
            observed.ino == descriptor.ino &&
            File.realpath(path) == File.expand_path(path)
          cleanup_unsafe!
        end
        CleanupEntry.new(
          path: File.expand_path(path).freeze,
          device: descriptor.dev,
          inode: descriptor.ino,
          directory: false,
          handle: nil,
          children: nil
        )
      ensure
        close_cleanup_handle(handle)
      end

      def cleanup_directory_stat?(stat, device:)
        cleanup_owned_directory_stat?(stat) &&
          stat.dev == device
      end

      def cleanup_owned_directory_stat?(stat)
        stat.directory? &&
          !stat.symlink? &&
          stat.uid == Process.euid
      end

      def cleanup_regular_stat?(stat, device:)
        stat.file? &&
          !stat.symlink? &&
          stat.nlink == 1 &&
          stat.uid == Process.euid &&
          stat.dev == device
      end

      def cleanup_identity?(entry, stat)
        stat.dev == entry.device &&
          stat.ino == entry.inode
      end

      def cleanup_no_follow_available!
        cleanup_unsafe! unless
          File.const_defined?(:NOFOLLOW)
      end

      def cleanup_directory_children(handle)
        duplicate = handle.dup
        directory = Dir.for_fd(duplicate.fileno)
        duplicate.autoclose = false
        directory.children.sort.freeze
      ensure
        if directory
          directory.close
        else
          duplicate&.close
        end
      end

      def close_cleanup_tree(tree)
        tree&.directories&.reverse_each do |entry|
          close_cleanup_handle(entry.handle)
        end
      end

      def close_cleanup_handle(handle)
        handle&.close unless handle&.closed?
      rescue IOError, SystemCallError
        nil
      end

      def canonical(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end
    end
  end
end
