require "test_helper"
require "digest"
require "json"
require "json_schemer"
require "hive/modules/migration/report_projection"
require "hive/modules/migration/report"

class ModulesMigrationReportProjectionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 3, 12)

  def test_migration_without_authoritative_qualification_requires_evidence
    projection = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [], generated_at: NOW,
      migration: migration_metadata
    )

    assert_equal "evidence_required", projection.status
    assert_nil projection.candidate_sha
    assert_nil projection.lanes.fetch("deterministic")
    assert_nil projection.lanes.fetch("installed_live")
    assert_includes projection.blockers, "deterministic:evidence_required"
    assert_includes projection.blockers, "installed_live:evidence_required"
    assert_schema_valid(projection.to_h)

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.build(
        qualifications: [], generated_at: NOW,
        migration: migration_metadata.merge("disposition" => "projected")
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.build(
        qualifications: [], generated_at: NOW,
        migration: migration_metadata.merge("archive_digest" => "e" * 64)
      )
    end
  end

  def test_partial_report_round_trips_and_accepts_only_the_missing_lane
    deterministic = qualification("deterministic")
    partial = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic ], generated_at: NOW
    )
    loaded = Hive::Modules::Migration::ReportProjection.from_h(partial.to_h)
    installed = qualification("installed_live")
    complete = Hive::Modules::Migration::ReportProjection.merge(
      existing: loaded, qualification: installed, generated_at: NOW + 1
    )

    assert_equal deterministic.to_h,
                 complete.lanes.fetch("deterministic").to_h
    assert_equal installed.to_h,
                 complete.lanes.fetch("installed_live").to_h
    assert_equal partial.report_id, complete.supersedes
    assert_equal "qualified", complete.status
    assert complete.eligible?
    assert_schema_valid(complete.to_h)
  end

  def test_readding_the_identical_lane_is_byte_stable
    deterministic = qualification("deterministic")
    partial = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic ], generated_at: NOW
    )

    merged = Hive::Modules::Migration::ReportProjection.merge(
      existing: partial, qualification: deterministic,
      generated_at: NOW + 60
    )
    assert_equal partial.to_h, merged.to_h
  end

  def test_rejects_lane_replacement_and_mixed_candidate_bindings
    deterministic = qualification("deterministic")
    partial = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic ], generated_at: NOW
    )
    replacement = qualification(
      "deterministic", qualification_seed: "f"
    )
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.merge(
        existing: partial, qualification: replacement,
        generated_at: NOW + 1
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.build(
        qualifications: [
          deterministic,
          qualification("installed_live", catalog_digest: "e" * 64)
        ],
        generated_at: NOW
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.build(
        qualifications: [
          deterministic,
          qualification("installed_live", patrol_configuration: "e" * 64)
        ],
        generated_at: NOW
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.build(
        qualifications: [
          deterministic,
          qualification("installed_live", candidate_sha: "e" * 40)
        ],
        generated_at: NOW
      )
    end
  end

  def test_invalidated_lane_supersedes_prior_readiness
    deterministic = qualification("deterministic")
    installed = qualification("installed_live")
    ready = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic, installed ], generated_at: NOW
    )
    invalidated = qualification(
      "installed_live", status: "invalidated",
      supersedes: installed.qualification_id,
      contradiction: {
        "kind" => "production_decision_diverged",
        "receipt_id" => installed.receipt_ids.first,
        "observed_at" => (NOW + 60).iso8601(6)
      }
    )
    report = Hive::Modules::Migration::ReportProjection.merge(
      existing: ready, qualification: invalidated,
      generated_at: NOW + 61
    )

    assert_equal "invalidated", report.status
    refute report.eligible?
    assert_equal ready.report_id, report.supersedes
    assert_equal deterministic.qualification_id,
                 report.lanes.fetch("deterministic").qualification_id
    assert_includes report.blockers,
                    "installed_live:contradictory_telemetry"

    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      Hive::Modules::Migration::Report.write_projection(path, ready)
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.write_projection(
          path, report, expected_digest: "f" * 64
        )
      end
      expected = Digest::SHA256.hexdigest(File.binread(path))
      Hive::Modules::Migration::Report.write_projection(
        path, report, expected_digest: expected
      )
      assert_equal report.to_h,
                   Hive::Modules::Migration::Report.load(path).to_h

      invalidated_digest = Digest::SHA256.hexdigest(File.binread(path))
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.write_projection(
          path, ready, expected_digest: invalidated_digest
        )
      end
      stale = Hive::Modules::Migration::ReportProjection.build(
        qualifications: [
          qualification(
            "deterministic", qualification_seed: "3",
            run_id: "stale-deterministic", generated_at: NOW + 121,
            evidence_started_at: NOW + 59
          ),
          qualification(
            "installed_live", qualification_seed: "4",
            run_id: "stale-installed-live", generated_at: NOW + 121,
            evidence_started_at: NOW + 59
          )
        ],
        generated_at: NOW + 121,
        supersedes: report.report_id
      )
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.write_projection(
          path, stale, expected_digest: invalidated_digest
        )
      end
      fresh = Hive::Modules::Migration::ReportProjection.build(
        qualifications: [
          qualification(
            "deterministic", qualification_seed: "3",
            run_id: "fresh-deterministic", generated_at: NOW + 121,
            evidence_started_at: NOW + 61
          ),
          qualification(
            "installed_live", qualification_seed: "4",
            run_id: "fresh-installed-live", generated_at: NOW + 121,
            evidence_started_at: NOW + 61
          )
        ],
        generated_at: NOW + 122,
        supersedes: report.report_id
      )
      Hive::Modules::Migration::Report.write_projection(
        path, fresh, expected_digest: invalidated_digest
      )
      assert_equal fresh.to_h,
                   Hive::Modules::Migration::Report.load(path).to_h
    end
  end

  def test_successor_preserves_migration_provenance
    deterministic = qualification("deterministic")
    current = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic ], generated_at: NOW,
      migration: migration_metadata.merge("disposition" => "projected")
    )
    installed = qualification("installed_live")
    stripped = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic, installed ], generated_at: NOW + 1,
      supersedes: current.report_id
    )
    preserved = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ deterministic, installed ], generated_at: NOW + 1,
      supersedes: current.report_id, migration: current.migration
    )

    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.validate_successor!(
        current: current, successor: stripped
      )
    end
    assert_equal preserved.to_h,
                 Hive::Modules::Migration::ReportProjection
                   .validate_successor!(
                     current: current, successor: preserved
                   ).to_h
  end

  def test_round_trip_rejects_extra_fields_and_forged_identity
    report = Hive::Modules::Migration::ReportProjection.build(
      qualifications: [ qualification("deterministic") ],
      generated_at: NOW
    )
    assert_equal report.to_h,
                 Hive::Modules::Migration::ReportProjection.from_h(
                   report.to_h
                 ).to_h
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.from_h(
        report.to_h.merge("unexpected" => true)
      )
    end
    assert_raises(Hive::ConfigError) do
      Hive::Modules::Migration::ReportProjection.from_h(
        report.to_h.merge("report_id" => "report-#{'f' * 64}")
      )
    end
  end

  private

  def qualification(lane, candidate_sha: "1" * 40,
                    qualification_seed: lane == "deterministic" ? "1" : "2",
                    status: "qualified", supersedes: nil, contradiction: nil,
                    catalog_digest: "2" * 64,
                    patrol_configuration: "5" * 64,
                    run_id: "run-#{lane}", generated_at: NOW,
                    evidence_started_at: NOW)
    blockers = status == "invalidated" ? [ "contradictory_telemetry" ] : []
    modules = %w[patrol architecture-patrol].to_h do |module_name|
      [ module_name, {
        "decision_count" => 10,
        "decision_identities" => 10.times.map do |index|
          "decision-#{Digest::SHA256.hexdigest(
            "#{qualification_seed}:#{module_name}:#{index}"
          )}"
        end.sort.freeze,
        "decision_classes" => %w[negative positive],
        "repository_shas" => [ "7" * 40, "8" * 40 ],
        "change_windows" => %w[window-0 window-1],
        "configuration_digest" =>
          module_name == "patrol" ? patrol_configuration : "a" * 64,
        "elapsed_seconds" => 9,
        "blockers" => []
      }.freeze ]
    end.freeze
    Hive::Modules::Migration::PatrolQualification.send(
      :create,
      {
        lane: lane,
        run_id: run_id,
        candidate_sha: candidate_sha,
        catalog_digest: catalog_digest,
        source_digest: "3" * 64,
        manifest_digest: "4" * 64,
        scenario_manifest_digest: "6" * 64,
        status: status,
        receipt_ids: 20.times.map do |index|
          "evidence-#{Digest::SHA256.hexdigest(
            "#{qualification_seed}:#{index}"
          )}"
        end.sort.freeze,
        decision_replay_count: 0,
        modules: modules,
        effect_count: 0,
        effect_replay_count: 0,
        duplicate_effects: [].freeze,
        unsettled_effects: [].freeze,
        elapsed_seconds: 9,
        evidence_started_at: evidence_started_at.iso8601(6),
        blockers: blockers.freeze,
        supersedes: supersedes,
        contradiction: contradiction&.freeze,
        generated_at: generated_at.iso8601(6)
      }
    )
  end

  def migration_metadata
    {
      "source_schema_version" => 1,
      "source_digest" => "d" * 64,
      "archive_digest" => "d" * 64,
      "disposition" => "evidence_required"
    }
  end

  def assert_schema_valid(payload)
    schema = JSONSchemer.schema(JSON.parse(File.read(
      Hive::Schemas.schema_path("hive-module-migration-report", version: 2)
    )))
    assert_empty schema.validate(payload).to_a
  end
end
