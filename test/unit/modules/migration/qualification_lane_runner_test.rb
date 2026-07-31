require "test_helper"
require "hive/managed_directory"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/qualification_lane_runner"
require "hive/modules/migration/qualification_run_authority_provider"
require_relative "../../../support/qualification_run_fixture"

class QualificationLaneRunnerTest < Minitest::Test
  include HiveTestHelper
  include QualificationRunFixture

  NOW = Time.utc(2026, 7, 31, 10, 0, 0)
  PROCESS_RESULT =
    Hive::Modules::Migration::QualificationScenarioProcess::Result

  MaterializedSource = Data.define(:root)
  MaterializedInstalled =
    Data.define(:root, :executable, :tree_sha256)
  Verification = Data.define(:status) do
    def verified? = status == "verified"
  end

  class SourceMaterializer
    def materialize(_bytes, destination:, executable_ref:)
      executable = File.join(destination, executable_ref)
      FileUtils.mkdir_p(
        File.dirname(executable),
        mode: 0o700
      )
      File.binwrite(executable, "#!/usr/bin/env ruby\n")
      File.chmod(0o700, executable)
      MaterializedSource.new(root: destination).freeze
    end
  end

  class InstalledMaterializer
    def materialize(files:, destination:, expected_tree_sha256:,
                    expected_executable:, **)
      ref = "inputs/installed-target/#{expected_executable}"
      raise "missing executable" unless files.key?(ref)

      executable = File.join(destination, expected_executable)
      FileUtils.mkdir_p(
        File.dirname(executable),
        mode: 0o700
      )
      File.binwrite(executable, files.fetch(ref).fetch(:bytes))
      File.chmod(0o700, executable)
      MaterializedInstalled.new(
        root: destination,
        executable: executable,
        tree_sha256: expected_tree_sha256
      ).freeze
    end
  end

  class ScenarioProcess
    def initialize(actual:, record:)
      @actual = actual
      @record = record
    end

    def call(workspace:, argv:, **)
      request_ref = argv.fetch(-1)
      request =
        Hive::Modules::Migration::
          QualificationScenarioRequest.load(
            File.binread(File.join(workspace, request_ref))
          )
      directory = Hive::ManagedDirectory.new(
        root: workspace,
        label: "test qualification process"
      )
      directory.atomic_write(
        request.output_ref,
        Hive::Modules::Migration::
          QualificationScenarioActuals.canonical(
            "schema" =>
              Hive::Modules::Migration::
                QualificationScenarioActuals::SCHEMA,
            "schema_version" =>
              Hive::Modules::Migration::
                QualificationScenarioActuals::SCHEMA_VERSION,
            "actuals" => [ @actual ]
          ),
        mode: 0o600,
        expected_absent: true
      )
      shadow = Hive::ManagedDirectory.new(
        root: File.join(
          workspace,
          request.sandbox_root_ref,
          "hive-state",
          "module-runtime",
          "migration",
          "shadow"
        ),
        label: "test qualification shadow evidence"
      )
      shadow.atomic_write(
        "#{@record.fetch('module')}/" \
        "#{@record.fetch('decision_id')}.json",
        Hive::WorkflowPackage::CanonicalJSON.generate(
          @record
        ),
        mode: 0o600,
        expected_absent: true
      )
      empty_stream = {
        "bytes" => 0,
        "sha256" => Digest::SHA256.hexdigest(""),
        "truncated" => false
      }.freeze
      teardown = {
        "status" => "passed",
        "attempt_count" => 2,
        "custody_count" => 2,
        "live_processes" => 0,
        "kill_authority" => "host_pid_namespace"
      }.freeze
      PROCESS_RESULT.new(
        status: "passed",
        exit_status: 0,
        signal: nil,
        timed_out: false,
        network_isolated: true,
        stdout: empty_stream,
        stderr: empty_stream,
        duration_seconds: 0.1,
        executable_sha256: "1" * 64,
        ruby_sha256: "2" * 64,
        attempt_count: 2,
        custody_count: 2,
        sandbox_profile_sha256: "3" * 64,
        source_inventory_sha256: "4" * 64,
        installed_inventory_sha256: "5" * 64,
        teardown: teardown
      ).freeze
    end
  end

  class AcceptingVerifier
    def self.verify(**)
      Verification.new(status: "verified").freeze
    end
  end

  HostEvidence = Data.define(:case_id, :payload) do
    def to_h = payload
  end

  class EvidenceCollector
    def call(case_id:, candidate_row:, **)
      HostEvidence.new(
        case_id: case_id.freeze,
        payload: {
          "schema" => "test-patrol-qualification-host-evidence",
          "schema_version" => 1,
          "case_id" => case_id,
          "candidate_sha256" =>
            Digest::SHA256.hexdigest(
              Hive::WorkflowPackage::CanonicalJSON.generate(
                candidate_row
              )
            )
        }.freeze
      ).freeze
    end
  end

  class RejectingEvidenceCollector
    def call(**)
      raise Hive::ConfigError,
            "patrol qualification host evidence is malformed"
    end
  end

  def test_installed_without_live_authorization_retains_a_retryable_diagnostic
    with_qualification_repository do |repository, fixture, run_id|
      runner = runner(repository)

      first = runner.call(
        run_id: run_id,
        lane: "installed",
        live_authorized: false
      )
      second = runner.call(
        run_id: run_id,
        lane: "installed",
        live_authorized: false
      )

      assert_equal "blocked", first.status
      assert_equal "live_lane_not_authorized",
                   first.failure_reason
      assert_equal(
        fixture.dig(
          :payload, "candidate", "installed_tree_sha256"
        ),
        first.target_sha256
      )
      assert_equal first.to_h, second.to_h
      assert_equal(
        [ first.to_h ],
        repository.qualification_lane_diagnostics(
          run_id,
          "installed"
        ).map(&:to_h)
      )
      assert_nil repository.qualification_lane_result(
        run_id, "installed", missing: true
      )
      refute File.exist?(
        File.join(
          repository.root,
          "qualification/runs",
          run_id,
          "lanes/installed/bundle.json"
        )
      )
    end
  end

  def test_installed_live_lane_reports_credentials_and_provider_separately
    with_qualification_repository do |repository, _fixture, run_id|
      result = runner(
        repository,
        environment: {}
      ).call(
        run_id: run_id,
        lane: "installed",
        live_authorized: true
      )

      assert_equal "blocked", result.status
      assert_equal "credentials_unavailable",
                   result.failure_reason
    end

    with_qualification_repository do |repository, _fixture, run_id|
      unavailable = runner(
        repository,
        environment: {}
      ).call(
        run_id: run_id,
        lane: "installed",
        live_authorized: false
      )
      result = runner(
        repository,
        environment: {
          "GITHUB_TOKEN" => "repository-token",
          "OPENROUTER_API_KEY" => "provider-token"
        }
      ).call(
        run_id: run_id,
        lane: "installed",
        live_authorized: true
      )

      assert_equal "blocked", result.status
      assert_equal "provider_unavailable",
                   result.failure_reason
      assert_nil repository.qualification_lane_result(
        run_id, "installed", missing: true
      )
      assert_equal(
        %w[
          live_lane_not_authorized provider_unavailable
        ],
        repository.qualification_lane_diagnostics(
          run_id,
          "installed"
        ).map(&:failure_reason).sort
      )
      refute_equal unavailable.failure_reason,
                   result.failure_reason
      authority =
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider.new(
            repository: repository
          ).call(
            run_id: run_id,
            lane: "installed"
          )
      assert_equal "blocked", authority.status
      assert_equal(
        [ "qualification_lane_blocked:provider_unavailable" ],
        authority.issues
      )
    end
  end

  def test_deterministic_lane_executes_candidate_and_publishes_full_capture
    with_qualification_repository do |repository, fixture, run_id|
      observation =
        qualification_scenario_observations(
          fixture,
          lane: "deterministic"
        ).fetch("observations").fetch(0)
      actual = observation.reject do |key, _value|
        key == "decision_class"
      end
      result = runner(
        repository,
        source_materializer: SourceMaterializer.new,
        installed_materializer:
          InstalledMaterializer.new,
        scenario_process: ScenarioProcess.new(
          actual: actual,
          record: fixture.fetch(:observation_record)
        ),
        verifier: AcceptingVerifier
      ).call(
        run_id: run_id,
        lane: "deterministic"
      )

      assert_equal "passed", result.status
      assert_equal 0, result.exit_code
      lane = repository.qualification_lane(
        run_id,
        "deterministic"
      )
      assert_equal(
        [
          "artifacts/host-evidence/#{actual.fetch('case_id')}.json",
          "artifacts/process-results.json",
          "artifacts/scenario-observations.json",
          "bundle.json",
          "repro.json",
          "repro.sh",
          "result.json"
        ],
        lane.keys.sort
      )
      assert_equal(
        "resolved",
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider.new(
            repository: repository
          ).call(
            run_id: run_id,
            lane: "deterministic"
          ).status
      )
    end
  end

  def test_candidate_actuals_cannot_bypass_host_evidence_reconstruction
    with_qualification_repository do |repository, fixture, run_id|
      observation =
        qualification_scenario_observations(
          fixture,
          lane: "deterministic"
        ).fetch("observations").fetch(0)
      actual = observation.reject do |key, _value|
        key == "decision_class"
      end
      result = runner(
        repository,
        source_materializer: SourceMaterializer.new,
        installed_materializer:
          InstalledMaterializer.new,
        scenario_process: ScenarioProcess.new(
          actual: actual,
          record: fixture.fetch(:observation_record)
        ),
        evidence_collector: RejectingEvidenceCollector.new,
        verifier: AcceptingVerifier
      ).call(
        run_id: run_id,
        lane: "deterministic"
      )

      assert_equal "failed", result.status
      assert_equal "evidence_verification_failed",
                   result.failure_reason
      lane = repository.qualification_lane(
        run_id,
        "deterministic"
      )
      refute(
        lane.keys.any? do |key|
          key.start_with?("artifacts/host-evidence/")
        end
      )
    end
  end

  def test_invalid_source_archive_fails_closed_instead_of_passing_stub
    with_qualification_repository do |repository, _fixture, run_id|
      result = runner(repository).call(
        run_id: run_id,
        lane: "deterministic"
      )

      assert_equal "failed", result.status
      assert_equal "evidence_verification_failed",
                   result.failure_reason
      lane = repository.qualification_lane(
        run_id,
        "deterministic"
      )
      assert_equal(
        %w[
          artifacts/failure.json
          artifacts/process-results.json
          artifacts/scenario-manifest.json
          bundle.json repro.json repro.sh result.json
        ],
        lane.keys.sort
      )
      bundle = JSON.parse(lane.fetch("bundle.json"))
      assert_empty bundle.fetch("records")
      assert_empty bundle.dig("receipt", "decisions")
      outcome =
        Hive::Modules::Migration::
          QualificationRunAuthorityProvider.new(
            repository: repository
          ).call(
            run_id: run_id,
            lane: "deterministic"
          )
      assert_equal "failed", outcome.status
      assert_equal(
        [
          "qualification_lane_failed:" \
          "evidence_verification_failed"
        ],
        outcome.issues
      )
    end
  end

  def test_successful_process_that_crosses_lane_wall_deadline_is_a_timeout
    with_qualification_repository do |repository, fixture, run_id|
      observation =
        qualification_scenario_observations(
          fixture,
          lane: "deterministic"
        ).fetch("observations").fetch(0)
      actual = observation.reject do |key, _value|
        key == "decision_class"
      end
      times = [
        NOW,
        NOW + 301,
        NOW + 301
      ]
      result =
        Hive::Modules::Migration::QualificationLaneRunner.new(
          repository: repository,
          clock: -> { times.shift || NOW + 301 },
          source_materializer: SourceMaterializer.new,
          installed_materializer:
            InstalledMaterializer.new,
          scenario_process: ScenarioProcess.new(
            actual: actual,
            record: fixture.fetch(:observation_record)
          ),
          evidence_collector: EvidenceCollector.new,
          verifier: AcceptingVerifier
        ).call(
          run_id: run_id,
          lane: "deterministic"
        )

      assert_equal "timeout", result.status
      assert_equal "lane_timeout", result.failure_reason
      assert_nil result.exit_code
      lane = repository.qualification_lane(
        run_id,
        "deterministic"
      )
      failure = JSON.parse(
        lane.fetch("artifacts/failure.json")
      )
      assert_equal "timeout", failure.fetch("status")
      assert_equal "lane_timeout", failure.fetch("reason")
      refute lane.key?("artifacts/scenario-observations.json")
    end
  end

  def test_exact_descriptor_input_and_private_mode_are_required
    with_qualification_repository do |repository, fixture, run_id|
      target = fixture.dig(
        :payload, "lanes", "deterministic", "target_ref"
      )
      path = File.join(
        repository.root, "qualification/runs", run_id, target
      )
      File.chmod(0o644, path)

      error = assert_raises(Hive::ConfigError) do
        runner(repository).call(
          run_id: run_id,
          lane: "deterministic"
        )
      end
      assert_includes error.message, "unsafe"
      assert_nil repository.qualification_lane_result(
        run_id, "deterministic", missing: true
      )
    end
  end

  private

  def runner(repository, **options)
    options = {
      evidence_collector: EvidenceCollector.new
    }.merge(options)
    Hive::Modules::Migration::QualificationLaneRunner.new(
      repository: repository,
      clock: -> { NOW },
      **options
    )
  end

  def with_qualification_repository
    with_tmp_dir do |root|
      fixture = qualification_run_fixture
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: root
        )
      run_id = repository.import_qualification_run(
        descriptor_bytes: fixture.fetch(:descriptor),
        inputs: fixture.fetch(:inputs)
      )
      yield repository, fixture, run_id
    end
  end
end
