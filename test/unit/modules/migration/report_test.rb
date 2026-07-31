require "test_helper"
require "json_schemer"
require "hive/modules/migration/migration_repository"
require "hive/modules/migration/report"
require_relative "../../../support/patrol_evidence_scenario"

class ModulesMigrationReportTest < Minitest::Test
  include HiveTestHelper
  include PatrolEvidenceScenario

  START = PatrolEvidenceScenario::START

  def test_two_fresh_lanes_build_and_reload_a_v2_operator_ready_projection
    report = build_report

    assert_equal 2, report.payload.fetch("schema_version")
    assert_equal "evidence_ready_for_operator", report.status
    assert_empty report.blockers
    refute_respond_to report, :eligible?
    refute_respond_to report, :ready_for_operator?
    assert_equal(
      PatrolEvidenceScenario::CONFIGURATION_DIGESTS,
      report.configuration_digests
    )
    assert_match(
      /\Amigration-report-[0-9a-f]{64}\z/,
      report.payload.fetch("report_id")
    )
    assert_empty report_schema.validate(report.payload).to_a

    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.write_report(report)
      loaded = repository.load_report(
        live_bindings_resolver:
          qualification_live_resolver
      )
      assert_equal report.payload, loaded.payload
      assert_equal(
        "evidence_ready_for_operator",
        loaded.qualification.status
      )
      assert loaded.qualification.ready_for_operator?
      assert_instance_of(
        Hive::Modules::Migration::PatrolQualification,
        loaded.qualification
      )
    end
  end

  def test_missing_or_blocked_installed_lane_is_evidence_required
    missing = Hive::Modules::Migration::Report.build(
      run_id: RUN_ID,
      lane_evidence: {
        "deterministic" =>
          qualification_bundle(lane: "deterministic")
      },
      reviewer: "operator",
      reviewed_at: START + 40,
      live_bindings_resolver:
        qualification_live_resolver
    )
    assert_equal "blocked", missing.status
    assert_includes missing.blockers, "installed:lane_evidence_missing"

    blocked = Hive::Modules::Migration::Report.build(
      run_id: RUN_ID,
      lane_evidence: {
        "deterministic" =>
          qualification_bundle(lane: "deterministic"),
        "installed" => qualification_bundle(
          lane: "installed",
          lane_result: "blocked",
          failure_reason: "credentials_missing"
        )
      },
      reviewer: "operator",
      reviewed_at: START + 40,
      live_bindings_resolver:
        qualification_live_resolver
    )
    assert_equal "blocked", blocked.status
    assert_includes(
      blocked.blockers,
      "installed:lane_blocked:credentials_missing"
    )
  end

  def test_one_lane_can_persist_reload_and_later_complete
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)

      partial = Hive::Modules::Migration::Report.build(
        run_id: RUN_ID,
        lane_evidence: {
          "deterministic" =>
            qualification_bundle(lane: "deterministic")
        },
        reviewer: "operator",
        reviewed_at: START + 40,
        live_bindings_resolver:
          qualification_live_resolver
      )
      repository.write_report(partial)
      reloaded = repository.load_report(
        live_bindings_resolver:
          qualification_live_resolver
      )
      assert_equal "blocked", reloaded.status
      assert_includes reloaded.blockers, "installed:lane_evidence_missing"

      complete = Hive::Modules::Migration::Report.build(
        run_id: RUN_ID,
        lane_evidence: {
          "deterministic" =>
            qualification_bundle(lane: "deterministic"),
          "installed" =>
            qualification_bundle(lane: "installed")
        },
        reviewer: "operator",
        reviewed_at: START + 41,
        live_bindings_resolver:
          qualification_live_resolver
      )
      repository.write_report(complete)

      assert_equal(
        "evidence_ready_for_operator",
        repository.load_report(
          live_bindings_resolver:
            qualification_live_resolver
        ).status
      )
    end
  end

  def test_cross_lane_candidate_run_and_scenario_drift_fail_closed
    installed = qualification_bundle(
      lane: "installed",
      candidate_sha: "f" * 40,
      run_id: "patrol-#{"f" * 64}",
      scenario_manifest_digest: "8" * 64
    )
    report = Hive::Modules::Migration::Report.build(
      run_id: RUN_ID,
      lane_evidence: {
        "deterministic" =>
          qualification_bundle(lane: "deterministic"),
        "installed" => installed
      },
      reviewer: "operator",
      reviewed_at: START + 40,
      live_bindings_resolver:
        qualification_live_resolver
    )

    assert_equal "evidence_required", report.status
    assert_includes(
      report.blockers,
      "installed:candidate_binding_mismatch"
    )
    assert_includes report.blockers, "installed:run_binding_mismatch"
    assert_includes(
      report.blockers,
      "installed:scenario_manifest_binding_mismatch"
    )
  end

  def test_load_revalidates_bundle_bytes_and_projection
    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.write_report(build_report)
      payload = JSON.parse(File.binread(repository.report_path))
      relative = payload.dig(
        "lanes", "deterministic", "bundle_path"
      )
      bundle_path = File.join(root, relative)
      bundle = JSON.parse(File.binread(bundle_path))
      bundle.fetch("receipt").fetch("candidate")[
        "commit_sha"
      ] =
        "f" * 40
      File.binwrite(
        bundle_path,
        Hive::Modules::Migration::Report.canonical(bundle)
      )

      error = assert_raises(Hive::ConfigError) do
        repository.load_report(
          live_bindings_resolver:
            qualification_live_resolver
        )
      end
      assert_match(/digest changed/, error.message)
    end
  end

  def test_v1_is_not_a_runtime_report
    fixture = File.expand_path(
      "../../../fixtures/module_migration/report-v1.json",
      __dir__
    )

    with_tmp_dir do |root|
      repository =
        Hive::Modules::Migration::MigrationRepository.new(root: root)
      repository.write_report_bytes(File.binread(fixture))
      error = assert_raises(Hive::ConfigError) do
        repository.load_report
      end
      assert_match(/malformed/, error.message)
    end
  end

  private

  def build_report
    Hive::Modules::Migration::Report.build(
      run_id: RUN_ID,
      lane_evidence: {
        "deterministic" =>
          qualification_bundle(lane: "deterministic"),
        "installed" =>
          qualification_bundle(lane: "installed")
      },
      reviewer: "operator",
      reviewed_at: START + 40,
      generated_at: START + 40,
      live_bindings_resolver:
        qualification_live_resolver
    )
  end

  def report_schema
    JSONSchemer.schema(
      Pathname(
        Hive::Schemas.schema_path("hive-module-migration-report")
      )
    )
  end
end
