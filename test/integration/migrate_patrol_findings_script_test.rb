require "test_helper"
require "hive/commands/init"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_adapter"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/source_snapshot"
require "hive/refactor_patrol/job_store"
require "open3"

class MigratePatrolFindingsScriptTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../script/migrate_patrol_findings.rb", __dir__)

  def test_reserves_active_findings_without_materializing_tasks_and_is_idempotent
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        target_sha = git_head(project)
        finding = Hive::Patrol::Finding.new(
          id: "finding-1", feature_id: "feature", category: "bug",
          severity: "medium", confidence: "high", title: "Refresh state",
          description: "Refresh can leave state inconsistent.",
          scope: { "paths" => [ "lib/hive/patrol.rb" ] },
          root_cause: "The refresh writes stale state.",
          reproduction: "Run the refresh twice.", fingerprint: "refresh-root",
          target_sha: target_sha, lifecycle_state: "active",
          lifecycle_updated_at: "2026-08-21T00:00:00Z"
        )
        finding_path = File.join(project, ".hive-state", "patrol", "findings", "finding-1.json")
        FileUtils.mkdir_p(File.dirname(finding_path))
        File.write(finding_path, JSON.generate(finding.to_h))

        dry_out, dry_err, dry_status = run_script(project, "--dry-run")
        assert dry_status.success?, dry_err
        assert_includes dry_out, "ordinary: would migrate 1, already present 0"
        assert_empty task_folders(project)
        assert_empty admissions(project)

        first_out, first_err, first_status = run_script(project)
        assert first_status.success?, first_err
        assert_includes first_out, "migrated 1, already present 0"

        assert_empty task_folders(project)
        records = admissions(project)
        assert_equal 1, records.length
        assert_equal "ordinary_patrol", records.first.dig("source", "engine")
        assert_equal "finding-1", records.first.dig("source", "identity")

        second_out, second_err, second_status = run_script(project)
        assert second_status.success?, second_err
        assert_includes second_out, "migrated 0, already present 1"
        assert_empty task_folders(project)
        assert_equal 1, admissions(project).length
      end
    end
  end

  def test_unrelated_corrupt_task_metadata_does_not_block_import
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(project)
        corrupt = File.join(project, ".hive-state", "stages", "1-inbox", "unrelated")
        FileUtils.mkdir_p(corrupt)
        File.write(File.join(corrupt, Hive::TaskMeta::FILENAME), "not: [valid\n")

        out, err, status = run_script(project)

        assert status.success?, err
        assert_includes out, "migrated 1, already present 0"
      end
    end
  end

  def test_conflicting_ordinary_admission_fails_closed
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(project)
        finding = stored_finding(project)
        snapshot = Hive::Patrol::FixAdmissionAdapter.snapshot_for(
          finding, accepted_at: Time.at(0).utc
        )
        occurrence_id = "ordinary:#{finding.id}:#{snapshot.evidence_digest[0, 24]}"
        conflicting = Hive::PatrolFix::SourceSnapshot.new(
          snapshot.to_h.merge("title" => "Different source bytes")
        )
        admission_store(project).reserve!(
          occurrence_id: occurrence_id, snapshot: conflicting, now: Time.at(0).utc
        )

        _out, err, status = run_script(project)

        refute status.success?
        assert_includes err, "different data for ordinary Patrol occurrence"
      end
    end
  end

  def test_duplicate_ordinary_finding_ids_fail_before_writes
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(project)
        findings = File.join(project, ".hive-state", "patrol", "findings")
        duplicate = JSON.parse(File.binread(File.join(findings, "finding-1.json")))
        duplicate["title"] = "Conflicting duplicate"
        File.write(File.join(findings, "duplicate.json"), JSON.generate(duplicate))

        _out, err, status = run_script(project)

        refute status.success?
        assert_includes err, "duplicate Patrol finding id finding-1"
        assert_empty admissions(project)
      end
    end
  end

  def test_uses_the_live_adapter_snapshot_conversion
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(
          project, scope: {}, evidence: [ { "file" => "lib/hive/patrol.rb", "line" => 12 } ]
        )

        _out, err, status = run_script(project)

        assert status.success?, err
        assert_equal [ "lib/hive/patrol.rb" ],
                     admissions(project).fetch(0).dig("source", "affected_code")
        assert_empty task_folders(project)
      end
    end
  end

  def test_uses_the_current_default_revision_for_legacy_findings_without_target_sha
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(project, target_sha: nil)

        out, err, status = run_script(project)

        assert status.success?, err
        assert_includes out, "ordinary: migrated 1, already present 0"
        assert_equal git_head(project),
                     admissions(project).fetch(0).dig("source", "target_revision")
        assert_empty task_folders(project)
      end
    end
  end

  def test_normalizes_an_unknown_active_legacy_reason_for_admission
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(project, lifecycle_reason: "legacy_import")

        out, err, status = run_script(project)

        assert status.success?, err
        assert_includes out, "ordinary: migrated 1, already present 0"
        assert_equal "finding-1", admissions(project).fetch(0).dig("source", "identity")
        assert_empty task_folders(project)
      end
    end
  end

  def test_migrates_accepted_architecture_dispositions_via_admission_store
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        Hive::RefactorPatrol::JobStore.new(project).write_job!(architecture_job)

        dry_out, dry_err, dry_status = run_script(project, "--dry-run")

        assert dry_status.success?, dry_err
        assert_includes dry_out, "architecture: would migrate 2, already present 0"
        assert_empty Dir.glob(File.join(project, ".hive-state", "patrol-fix", "admissions", "records", "*.json"))

        first_out, first_err, first_status = run_script(project)

        assert first_status.success?, first_err
        assert_includes first_out, "architecture: migrated 2, already present 0"
        records = admissions(project)
        assert_equal 2, records.length
        assert_equal [ "architecture_patrol" ], records.map { |item| item.dig("source", "engine") }.uniq
        assert_equal %w[job-legacy:discuss-1 job-legacy:fix-1],
                     records.map { |item| item.dig("source", "identity") }.sort

        second_out, second_err, second_status = run_script(project)

        assert second_status.success?, second_err
        assert_includes second_out, "architecture: migrated 0, already present 2"
        assert_equal 2, admissions(project).length
        assert_empty task_folders(project)
      end
    end
  end

  def test_redacts_secret_like_legacy_evidence_without_dropping_the_finding
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        secret = [ "ghp", "a" * 36 ].join("_")
        write_finding(project, evidence: [ secret ])

        out, err, status = run_script(project)

        assert status.success?, err
        assert_includes out, "ordinary: migrated 1, already present 0"
        source = admissions(project).fetch(0).fetch("source")
        refute_includes JSON.generate(source), secret
        assert_includes JSON.generate(source), "[REDACTED:"
        assert_empty task_folders(project)
      end
    end
  end

  private

  def admission_store(project)
    Hive::PatrolFix::AdmissionStore.new(
      root: File.join(project, ".hive-state", "patrol-fix", "admissions")
    )
  end

  def admissions(project)
    admission_store(project).pending(limit: 64)
  end

  def task_folders(project)
    Dir.glob(File.join(project, ".hive-state", "stages", "*", "*"))
       .select { |path| File.directory?(path) }
  end

  def stored_finding(project)
    path = File.join(project, ".hive-state", "patrol", "findings", "finding-1.json")
    Hive::Patrol::Finding.from_h(JSON.parse(File.binread(path)))
  end

  def run_script(project, *arguments)
    Open3.capture3(RbConfig.ruby, SCRIPT, project, *arguments)
  end

  def write_finding(project, scope: { "paths" => [ "lib/hive/patrol.rb" ] }, evidence: nil,
                    target_sha: git_head(project), lifecycle_reason: nil)
    finding = Hive::Patrol::Finding.new(
      id: "finding-1", feature_id: "feature", category: "bug",
      severity: "medium", confidence: "high", title: "Refresh state",
      description: "Refresh can leave state inconsistent.",
      scope: scope,
      root_cause: "The refresh writes stale state.",
      reproduction: "Run the refresh twice.", evidence: evidence, fingerprint: "refresh-root",
      target_sha: target_sha, lifecycle_state: "active",
      lifecycle_reason: lifecycle_reason,
      lifecycle_updated_at: "2026-08-21T00:00:00Z"
    )
    path = File.join(project, ".hive-state", "patrol", "findings", "finding-1.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(finding.to_h))
  end

  def git_head(project)
    output, = Open3.capture2("git", "-C", project, "rev-parse", "HEAD")
    output.strip
  end

  def architecture_job
    fix = architecture_disposition("fix-1", "fix")
    discuss = architecture_disposition("discuss-1", "discuss")
    dismiss = architecture_disposition("dismiss-1", "dismiss", admissible: false)
    {
      "schema" => "hive-refactor-patrol-job",
      "schema_version" => Hive::RefactorPatrol::JobStore::SCHEMA_VERSION,
      "job_id" => "job-legacy",
      "occurrence_id" => "occ-#{'1' * 64}",
      "intake_transition_id" => "intent-#{'2' * 64}",
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7", "number" => 7,
        "repository" => "acme/demo", "registration" => "demo",
        "base_branch" => "main", "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40, "merged_at" => "2026-08-20T10:00:00Z"
      },
      "analysis_sha" => "c" * 40,
      "policy" => { "discovery" => true, "auto_fix" => true, "issue_filing" => false },
      "state" => "complete", "complete" => true,
      "dispositions" => { "fix" => [ fix ], "discuss" => [ discuss ], "dismiss" => [ dismiss ] },
      "feature_results" => [
        { "feature_id" => "checkout", "complete" => true,
          "thesis_ids" => %w[discuss-1 dismiss-1 fix-1], "errors" => [] }
      ],
      "review_errors" => [], "zero_reason" => nil,
      "attempts" => [ { "number" => 1, "outcome" => "complete" } ],
      "actions" => [],
      "created_at" => "2026-08-20T10:00:00Z",
      "updated_at" => "2026-08-20T10:01:00Z"
    }
  end

  def architecture_disposition(id, route, admissible: true)
    fingerprint = Digest::SHA256.hexdigest(id)
    {
      "id" => id, "feature_id" => "checkout", "fingerprint" => fingerprint,
      "route" => route, "admissible" => admissible,
      "reasons" => disposition_reasons(route, admissible),
      "thesis" => {
        "id" => id, "feature_id" => "checkout", "feature" => "Checkout",
        "fingerprint" => fingerprint, "problem" => "Scattered policy",
        "cost" => "Repeated edits", "evidence" => [],
        "proposed_refactor" => "Consolidate policy",
        "feature_boundary" => { "owned_files" => [ "lib/checkout.rb" ] },
        "architecture_effects" => [ "one policy owner replaces repeated edits" ],
        "route" => route, "confidence" => "high",
        "risk" => { "flags" => [], "advisories" => [] },
        "required_validation" => { "commands" => [ "bin/test" ] },
        "admissible" => admissible,
        "admissibility_reason" => admissible ? "verified" : "inadmissible",
        "follow_up_approval_state" => "pending"
      }
    }
  end

  def disposition_reasons(route, admissible)
    return [] if route == "fix" && admissible
    return [ "requires_discussion" ] if route == "discuss"

    [ "inadmissible" ]
  end
end
