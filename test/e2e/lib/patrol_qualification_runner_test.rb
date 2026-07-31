require_relative "../../test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_lane_result"
require "hive/workflow_package/canonical_json"
require_relative "../../support/qualification_run_fixture"
require_relative "patrol_qualification_plan"
require_relative "patrol_qualification_runner"

class E2EPatrolQualificationRunnerTest < Minitest::Test
  include QualificationRunFixture

  Candidate = Data.define(
    :candidate_sha, :manifest_bytes, :inputs, :digests
  )

  class Preparer
    def initialize(candidate, workspace)
      @candidate = candidate
      @workspace = workspace
    end

    def call
      artifacts =
        File.join(@workspace, "candidate-artifacts")
      Dir.mkdir(artifacts, 0o700)
      artifact = File.join(artifacts, "manifest.json")
      File.binwrite(artifact, "{}\n")
      File.chmod(0o400, artifact)
      File.chmod(0o500, artifacts)
      @candidate
    end
  end

  class FailingPreparer
    def initialize(workspace)
      @workspace = workspace
    end

    def call
      artifacts =
        File.join(@workspace, "candidate-artifacts")
      Dir.mkdir(artifacts, 0o700)
      artifact = File.join(artifacts, "manifest.json")
      File.binwrite(artifact, "{}\n")
      File.chmod(0o400, artifact)
      File.chmod(0o500, artifacts)
      original = HiveReleaseCandidate::UnavailableError.new(
        "fixture candidate unavailable"
      )
      normalized = HivePatrolEvidence::Error.new(
        original.message,
        exit_code: original.exit_code,
        kind: original.kind
      )
      raise normalized, cause: original
    end
  end

  class Plan
    def initialize(fixture)
      @fixture = fixture
    end

    def call(candidate:, control:)
      raise "candidate omitted" unless candidate
      raise "control omitted" unless control

      Hive::E2E::PatrolQualificationPlan::Result.new(
        run_id: @fixture.dig(:payload, "run_id"),
        descriptor_bytes: @fixture.fetch(:descriptor),
        inputs: @fixture.fetch(:inputs)
      )
    end
  end

  class LaneRunner
    NOW = Time.utc(2026, 7, 31, 12, 0, 0)

    def initialize(
      repository, deterministic_status: "passed",
      installed_status: "blocked", return_mismatch: false
    )
      @repository = repository
      @deterministic_status = deterministic_status
      @installed_status = installed_status
      @return_mismatch = return_mismatch
    end

    def call(run_id:, lane:, live_authorized:)
      raise "live authority escaped harness" if live_authorized

      descriptor =
        Hive::Modules::Migration::
          QualificationRunDescriptor.load(
            @repository.qualification_descriptor(run_id)
          )
      target =
        lane == "deterministic" ?
          descriptor.candidate.fetch(
            "source_archive_sha256"
          ) :
          descriptor.candidate.fetch(
            "installed_tree_sha256"
          )
      if lane == "installed"
        if @installed_status == "passed"
          result = build(
            run_id, lane, target,
            status: "passed"
          )
          @repository.publish_qualification_lane(
            run_id: run_id,
            lane: lane,
            result_bytes: lane_bytes(result),
            bundle_bytes: canonical("records" => []),
            artifacts: {
              "process-results.json" =>
                canonical("processes" => [])
            },
            repro_json:
              canonical("run_id" => run_id, "lane" => lane),
            repro_script:
              "#!/usr/bin/env bash\nexit 0\n"
          )
          return result
        end

        result = build(
          run_id, lane, target,
          status: "blocked",
          reason: "live_lane_not_authorized"
        )
        @repository.publish_qualification_lane_diagnostic(
          run_id: run_id,
          lane: lane,
          result_bytes: lane_bytes(result)
        )
        return result
      end

      if @deterministic_status == "passed"
        result = build(
          run_id, lane, target,
          status: "passed"
        )
        @repository.publish_qualification_lane(
          run_id: run_id,
          lane: lane,
          result_bytes: lane_bytes(result),
          bundle_bytes: canonical("records" => []),
          artifacts: {
            "process-results.json" =>
              canonical("processes" => [])
          },
          repro_json:
            canonical("run_id" => run_id, "lane" => lane),
          repro_script:
            "#!/usr/bin/env bash\nexit 0\n"
        )
      else
        result = build(
          run_id, lane, target,
          status: "failed",
          reason: "scenario_failed",
          exit_code: 1
        )
        @repository.publish_qualification_lane_result(
          run_id: run_id,
          lane: lane,
          result_bytes: lane_bytes(result)
        )
        if @return_mismatch
          return build(
            run_id, lane, target,
            status: "failed",
            reason: "candidate_execution_failed",
            exit_code: 1
          )
        end
      end
      result
    end

    private

    def build(run_id, lane, target, status:, reason: nil,
              exit_code: status == "passed" ? 0 : nil)
      Hive::Modules::Migration::QualificationLaneResult.build(
        run_id: run_id,
        lane: lane,
        status: status,
        started_at: NOW,
        ended_at: NOW,
        target_sha256: target,
        exit_code: exit_code,
        failure_reason: reason
      )
    end

    def lane_bytes(result)
      Hive::Modules::Migration::QualificationLaneResult
        .canonical(result.to_h)
    end

    def canonical(value)
      Hive::WorkflowPackage::CanonicalJSON.generate(value)
    end
  end

  def test_deterministic_only_run_is_diagnostic_not_qualifying
    with_runner do |context|
      result = context.fetch(:runner).call(
        project_root: context.fetch(:project),
        run_home: context.fetch(:run_home),
        artifacts_root: context.fetch(:artifacts)
      )

      assert_equal "deterministic_evidence_ready",
                   result.fetch("status")
      assert_equal context.fetch(:run_id),
                   result.fetch("run_id")
      refute Hive::E2E::PatrolQualificationRunner
        .harness_complete?(result)
      assert Hive::E2E::PatrolQualificationRunner
        .diagnostic_complete?(result)
      run_dir = result.fetch("artifacts_dir")
      assert_equal(
        File.join(
          context.fetch(:artifacts),
          context.fetch(:run_id)
        ),
        run_dir
      )
      aggregate = JSON.parse(
        File.binread(File.join(run_dir, "result.json"))
      )
      assert_equal "passed",
                   aggregate.dig("deterministic", "status")
      assert_equal "blocked",
                   aggregate.dig("installed", "status")
      assert_equal(
        "live_lane_not_authorized",
        aggregate.dig("installed", "failure_reason")
      )
      assert File.file?(
        File.join(
          run_dir,
          "lanes/deterministic/bundle.json"
        )
      )
      assert_equal(
        [ "result.json" ],
        Dir.children(
          File.join(run_dir, "lanes/installed")
        )
      )
      refute File.exist?(
        File.join(
          context.fetch(:artifacts),
          ".candidate-preparation"
        )
      )
    end
  end

  def test_local_control_remains_advisory_after_deterministic_pass
    with_runner(control_trust_scope: "local") do |context|
      result = context.fetch(:runner).call(
        project_root: context.fetch(:project),
        run_home: context.fetch(:run_home),
        artifacts_root: context.fetch(:artifacts)
      )

      assert_equal "evidence_required", result.fetch("status")
      aggregate = JSON.parse(
        File.binread(
          File.join(result.fetch("artifacts_dir"), "result.json")
        )
      )
      assert_equal(
        %w[
          qualification_control_untrusted
          qualification_control_not_independent
        ],
        aggregate.fetch("blockers")
      )
      refute Hive::E2E::PatrolQualificationRunner
        .harness_complete?(result)
      assert Hive::E2E::PatrolQualificationRunner
        .diagnostic_complete?(result)
    end
  end

  def test_both_passed_lanes_with_independent_control_are_qualifying
    with_runner(installed_status: "passed") do |context|
      result = context.fetch(:runner).call(
        project_root: context.fetch(:project),
        run_home: context.fetch(:run_home),
        artifacts_root: context.fetch(:artifacts)
      )

      assert_equal "evidence_ready_for_operator",
                   result.fetch("status")
      assert Hive::E2E::PatrolQualificationRunner
        .harness_complete?(result)
      assert Hive::E2E::PatrolQualificationRunner
        .diagnostic_complete?(result)
    end
  end

  def test_failed_deterministic_lane_never_claims_ready
    with_runner(deterministic_status: "failed") do |context|
      result = context.fetch(:runner).call(
        project_root: context.fetch(:project),
        run_home: context.fetch(:run_home),
        artifacts_root: context.fetch(:artifacts)
      )

      assert_equal "failed", result.fetch("status")
      aggregate = JSON.parse(
        File.binread(
          File.join(
            result.fetch("artifacts_dir"),
            "result.json"
          )
        )
      )
      assert_equal "failed", aggregate.fetch("status")
      assert_equal "failed",
                   aggregate.dig("deterministic", "status")
    end
  end

  def test_changed_failed_result_is_rejected_instead_of_falling_back
    with_runner(
      deterministic_status: "failed",
      return_mismatch: true
    ) do |context|
      error = assert_raises(Hive::ConfigError) do
        context.fetch(:runner).call(
          project_root: context.fetch(:project),
          run_home: context.fetch(:run_home),
          artifacts_root: context.fetch(:artifacts)
        )
      end

      assert_equal "patrol qualification lane result changed",
                   error.message
      refute File.exist?(
        File.join(
          context.fetch(:artifacts),
          context.fetch(:run_id)
        )
      )
    end
  end

  def test_cleanup_refuses_symlinks_without_removing_the_workspace
    Dir.mktmpdir("patrol-cleanup-link") do |root|
      workspace = File.join(root, "workspace")
      outside = File.join(root, "outside")
      Dir.mkdir(workspace, 0o700)
      File.binwrite(outside, "outside\n")
      link = File.join(workspace, "outside")
      File.symlink(outside, link)
      runner =
        Hive::E2E::PatrolQualificationRunner.new(
          repo_root: root
        )

      error = assert_raises(Hive::ConfigError) do
        runner.send(:remove_workspace, workspace)
      end

      assert_equal(
        "patrol qualification cleanup target is unsafe",
        error.message
      )
      assert File.symlink?(link)
      assert_equal "outside\n", File.binread(outside)
    end
  end

  def test_cleanup_refuses_hardlinks_without_changing_external_mode
    Dir.mktmpdir("patrol-cleanup-hardlink") do |root|
      workspace = File.join(root, "workspace")
      outside = File.join(root, "outside")
      Dir.mkdir(workspace, 0o700)
      File.binwrite(outside, "outside\n")
      File.chmod(0o640, outside)
      link = File.join(workspace, "outside")
      File.link(outside, link)
      runner =
        Hive::E2E::PatrolQualificationRunner.new(
          repo_root: root
        )

      error = assert_raises(Hive::ConfigError) do
        runner.send(:remove_workspace, workspace)
      end

      assert_equal(
        "patrol qualification cleanup target is unsafe",
        error.message
      )
      assert_equal 0o640, File.stat(outside).mode & 0o777
      assert_equal 2, File.stat(outside).nlink
      assert File.exist?(workspace)
    end
  end

  def test_cleanup_refuses_special_entries_before_removal
    Dir.mktmpdir("patrol-cleanup-special") do |root|
      workspace = File.join(root, "workspace")
      fifo = File.join(workspace, "provider.pipe")
      Dir.mkdir(workspace, 0o700)
      File.mkfifo(fifo, 0o600)
      remover_called = false
      runner =
        Hive::E2E::PatrolQualificationRunner.new(
          repo_root: root,
          workspace_remover:
            lambda do |_path|
              remover_called = true
            end
        )

      error = assert_raises(Hive::ConfigError) do
        runner.send(:remove_workspace, workspace)
      end

      assert_equal(
        "patrol qualification cleanup target is unsafe",
        error.message
      )
      refute remover_called
      assert_equal "fifo", File.ftype(fifo)
      assert File.directory?(workspace)
    end
  end

  def test_cleanup_requires_absence_and_never_chmods_regular_files
    Dir.mktmpdir("patrol-cleanup-postcondition") do |root|
      workspace = File.join(root, "workspace")
      artifacts = File.join(workspace, "candidate-artifacts")
      artifact = File.join(artifacts, "manifest.json")
      Dir.mkdir(workspace, 0o700)
      Dir.mkdir(artifacts, 0o700)
      File.binwrite(artifact, "{}\n")
      File.chmod(0o400, artifact)
      File.chmod(0o500, artifacts)
      runner =
        Hive::E2E::PatrolQualificationRunner.new(
          repo_root: root,
          workspace_remover: ->(_path) { nil }
        )

      error = assert_raises(Hive::ConfigError) do
        runner.send(:remove_workspace, workspace)
      end

      assert_equal(
        "patrol qualification cleanup target is unsafe",
        error.message
      )
      assert File.directory?(workspace)
      assert_equal 0o700, File.stat(artifacts).mode & 0o777
      assert_equal 0o400, File.stat(artifact).mode & 0o777
    ensure
      File.chmod(0o700, artifacts) if
        artifacts && File.directory?(artifacts)
    end
  end

  def test_cleanup_rejects_directory_inode_substitution_before_chmod
    Dir.mktmpdir("patrol-cleanup-substitution") do |root|
      workspace = File.join(root, "workspace")
      directory = File.join(workspace, "candidate-artifacts")
      moved = File.join(workspace, "original-artifacts")
      Dir.mkdir(workspace, 0o700)
      Dir.mkdir(directory, 0o500)
      runner =
        Hive::E2E::PatrolQualificationRunner.new(
          repo_root: root
        )
      tree = runner.send(:inspect_cleanup_tree, workspace)
      File.rename(directory, moved)
      Dir.mkdir(directory, 0o755)

      error = assert_raises(Hive::ConfigError) do
        runner.send(:verify_cleanup_tree!, tree)
      end

      assert_equal(
        "patrol qualification cleanup target is unsafe",
        error.message
      )
      assert_equal 0o755, File.stat(directory).mode & 0o777
      assert_equal 0o500, File.stat(moved).mode & 0o777
    ensure
      runner&.send(:close_cleanup_tree, tree)
      File.chmod(0o700, moved) if
        moved && File.directory?(moved)
    end
  end

  def test_candidate_failure_removes_immutable_workspace_and_preserves_cause
    factory = lambda do |workspace|
      FailingPreparer.new(workspace)
    end
    with_runner(candidate_preparer_factory: factory) do |context|
      error = assert_raises(Hive::ConfigError) do
        context.fetch(:runner).call(
          project_root: context.fetch(:project),
          run_home: context.fetch(:run_home),
          artifacts_root: context.fetch(:artifacts)
        )
      end

      assert_includes error.message,
                      "candidate is unavailable"
      assert_instance_of HivePatrolEvidence::Error,
                         error.cause
      assert_instance_of HiveReleaseCandidate::UnavailableError,
                         error.cause.cause
      refute File.exist?(
        File.join(
          context.fetch(:artifacts),
          ".candidate-preparation"
        )
      )
      assert_empty Dir.children(context.fetch(:artifacts))
    end
  end

  def test_candidate_and_cleanup_failures_preserve_the_full_cause_chain
    factory = lambda do |workspace|
      FailingPreparer.new(workspace)
    end
    remover = lambda do |_path|
      raise Hive::ConfigError,
            "fixture workspace removal failed"
    end
    with_runner(
      candidate_preparer_factory: factory,
      workspace_remover: remover
    ) do |context|
      error = assert_raises(
        Hive::E2E::PatrolQualificationRunner::CleanupFailure
      ) do
        context.fetch(:runner).call(
          project_root: context.fetch(:project),
          run_home: context.fetch(:run_home),
          artifacts_root: context.fetch(:artifacts)
        )
      end

      candidate_failure = error.cause
      assert_same error.primary, candidate_failure
      assert_instance_of Hive::ConfigError,
                         candidate_failure
      assert_includes candidate_failure.message,
                      "candidate is unavailable"
      assert_instance_of HivePatrolEvidence::Error,
                         candidate_failure.cause
      assert_instance_of HiveReleaseCandidate::UnavailableError,
                         candidate_failure.cause.cause
      assert_includes error.cleanup.message,
                      "workspace removal failed"
    end
  end

  def test_workspace_cleanup_precedes_lanes_and_terminal_publication
    with_runner do |context|
      runner = context.fetch(:runner)
      original = runner.method(:remove_workspace)
      cleanup_calls = 0
      lane_started = false
      runner.define_singleton_method(:remove_workspace) do |path|
        cleanup_calls += 1
        if cleanup_calls == 1
          raise Hive::ConfigError,
                "fixture cleanup failed before lanes"
        end

        original.call(path)
      end
      runner.instance_variable_set(
        :@lane_runner_factory,
        lambda do |_repository|
          lane_started = true
          raise "lane must not start before cleanup"
        end
      )

      error = assert_raises(Hive::ConfigError) do
        runner.call(
          project_root: context.fetch(:project),
          run_home: context.fetch(:run_home),
          artifacts_root: context.fetch(:artifacts)
        )
      end

      assert_equal "fixture cleanup failed before lanes",
                   error.message
      assert_equal 2, cleanup_calls
      refute lane_started
      assert_empty Dir.children(context.fetch(:artifacts))
      refute File.exist?(
        File.join(
          context.fetch(:artifacts),
          context.fetch(:run_id),
          "result.json"
        )
      )
    end
  end

  def test_cleanup_failure_preserves_primary_as_cause
    primary = RuntimeError.new("primary failure")
    cleanup = Hive::ConfigError.new("cleanup failure")
    runner =
      Hive::E2E::PatrolQualificationRunner.new(
        repo_root: Dir.pwd
      )
    runner.define_singleton_method(:remove_workspace) do |_path|
      raise cleanup
    end

    error = assert_raises(
      Hive::E2E::PatrolQualificationRunner::CleanupFailure
    ) do
      runner.send(
        :cleanup_after_failure,
        "/unused",
        primary
      )
    end

    assert_same primary, error.primary
    assert_same cleanup, error.cleanup
    assert_same primary, error.cause
    assert_includes error.message, "primary failure"
    assert_includes error.message, "cleanup failure"
  end

  private

  def with_runner(
    deterministic_status: "passed",
    installed_status: "blocked",
    return_mismatch: false,
    candidate_preparer_factory: nil,
    workspace_remover: nil,
    control_trust_scope: "trusted_remote"
  )
    Dir.mktmpdir("patrol-runner") do |root|
      File.chmod(0o700, root)
      project = File.join(root, "project")
      run_home = File.join(root, "hive-home")
      artifacts = File.join(root, "artifacts")
      repository_root = File.join(root, "repository")
      FileUtils.mkdir_p(
        [ project, run_home ],
        mode: 0o700
      )
      fixture = qualification_run_fixture
      if control_trust_scope == "local"
        payload = fixture.fetch(:payload)
        payload.fetch("control")["trust_scope"] = "local"
        payload.fetch("control")["ref"] = nil
        payload.fetch("control")["commit_sha"] =
          payload.dig("candidate", "commit_sha")
        payload.fetch("control")["provenance"] = {
          "workflow_path" => nil,
          "workflow_sha" => nil,
          "run_id" => nil,
          "run_attempt" => nil,
          "action_lock_sha256" => nil
        }
        seal_qualification_payload!(payload)
        fixture[:descriptor] = canonical(payload)
      end
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: repository_root
        )
      candidate = candidate_from(fixture)
      control =
        Hive::Modules::Migration::
          TrustedQualificationControl.from_h(
            fixture.fetch(:payload).fetch("control"),
            checkout_root: root
          )
      candidate_preparer_factory ||=
        lambda do |workspace|
          Preparer.new(candidate, workspace)
        end
      runner = Hive::E2E::PatrolQualificationRunner.new(
        repo_root: root,
        candidate_preparer_factory:
          candidate_preparer_factory,
        plan: Plan.new(fixture),
        control_provider: ->(**) { control },
        repository_factory: ->(_project) { repository },
        workspace_remover: workspace_remover,
        lane_runner_factory:
          lambda do |actual_repository|
            LaneRunner.new(
              actual_repository,
              deterministic_status: deterministic_status,
              installed_status: installed_status,
              return_mismatch: return_mismatch
            )
          end
      )
      yield(
        runner: runner,
        project: project,
        run_home: run_home,
        artifacts: artifacts,
        run_id: fixture.dig(:payload, "run_id")
      )
    end
  end

  def candidate_from(fixture)
    Candidate.new(
      candidate_sha:
        fixture.dig(:payload, "candidate", "commit_sha"),
      manifest_bytes:
        fixture.dig(
          :inputs,
          "inputs/candidate/manifest.json",
          :bytes
        ),
      inputs: fixture.fetch(:inputs),
      digests: fixture.fetch(:payload).fetch("candidate")
        .slice(
          *%w[
            artifact_manifest_sha256 source_archive_sha256
            candidate_gem_sha256 skills_archive_sha256
            installed_tree_sha256
          ]
        )
    )
  end
end
