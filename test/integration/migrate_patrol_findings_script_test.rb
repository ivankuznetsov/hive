require "test_helper"
require "hive/commands/init"
require "hive/patrol/finding"
require "hive/patrol_fix/admission_store"
require "hive/refactor_patrol/job_store"
require "open3"

class MigratePatrolFindingsScriptTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../script/migrate_patrol_findings.rb", __dir__)

  def test_migrates_active_findings_and_is_idempotent
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

        first_out, first_err, first_status = run_script(project)
        assert first_status.success?, first_err
        assert_includes first_out, "migrated 1, already present 0"

        folders = Dir.glob(File.join(project, ".hive-state", "stages", "*", "*"))
        assert_equal 1, folders.length
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folders.first).read
        assert_equal "finding-1", manifest.dig("sources", 0, "identity")
        assert_equal "ordinary_finding", manifest.dig("aliases", 0, "kind")

        second_out, second_err, second_status = run_script(project)
        assert second_status.success?, second_err
        assert_includes second_out, "migrated 0, already present 1"
        assert_equal 1, Dir.glob(File.join(project, ".hive-state", "stages", "*", "*", "patrol-fix-manifest.json")).length
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

  def test_conflicting_candidate_patrol_fix_metadata_fails_closed
    with_tmp_global_config do
      with_tmp_git_repo do |project|
        capture_io { Hive::Commands::Init.new(project, agent_skill_preflight: false).call }
        write_finding(project)
        candidate = File.join(project, ".hive-state", "stages", "1-inbox", "candidate")
        Hive::TaskMeta.write(
          candidate, id: 99, slug: "candidate", display_name: nil,
          workflow: "patrol-fix",
          idempotency_key: "patrol-fix:legacy-finding:finding-1",
          input_fingerprint: "f" * 64
        )

        _out, err, status = run_script(project)

        refute status.success?
        assert_includes err, "different data for Patrol finding finding-1"
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
        folder = Dir.glob(File.join(project, ".hive-state", "stages", "*", "*")).fetch(0)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
        assert_equal [ "lib/hive/patrol.rb" ], manifest.dig("sources", 0, "affected_code")
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
        folder = Dir.glob(File.join(project, ".hive-state", "stages", "*", "*")).fetch(0)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
        assert_equal git_head(project), manifest.fetch("target_revision")
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
        admissions = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(project, ".hive-state", "patrol-fix", "admissions")
        ).pending(limit: 64)
        assert_equal 2, admissions.length
        assert_equal [ "architecture_patrol" ], admissions.map { |item| item.dig("source", "engine") }.uniq
        assert_equal %w[job-legacy:discuss-1 job-legacy:fix-1],
                     admissions.map { |item| item.dig("source", "identity") }.sort

        second_out, second_err, second_status = run_script(project)

        assert second_status.success?, second_err
        assert_includes second_out, "architecture: migrated 0, already present 2"
        assert_equal 2, Hive::PatrolFix::AdmissionStore.new(
          root: File.join(project, ".hive-state", "patrol-fix", "admissions")
        ).pending(limit: 64).length
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
        folder = Dir.glob(File.join(project, ".hive-state", "stages", "*", "*")).fetch(0)
        manifest = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read
        refute_includes JSON.generate(manifest), secret
        assert_includes JSON.generate(manifest), "[REDACTED:"
      end
    end
  end

  private

  def run_script(project, *arguments)
    Open3.capture3(RbConfig.ruby, SCRIPT, project, *arguments)
  end

  def write_finding(project, scope: { "paths" => [ "lib/hive/patrol.rb" ] }, evidence: nil,
                    target_sha: git_head(project))
    finding = Hive::Patrol::Finding.new(
      id: "finding-1", feature_id: "feature", category: "bug",
      severity: "medium", confidence: "high", title: "Refresh state",
      description: "Refresh can leave state inconsistent.",
      scope: scope,
      root_cause: "The refresh writes stale state.",
      reproduction: "Run the refresh twice.", evidence: evidence, fingerprint: "refresh-root",
      target_sha: target_sha, lifecycle_state: "active",
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
