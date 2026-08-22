require "test_helper"
require "hive/commands/init"
require "hive/patrol/finding"
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

  private

  def run_script(project, *arguments)
    Open3.capture3(RbConfig.ruby, SCRIPT, project, *arguments)
  end

  def write_finding(project, scope: { "paths" => [ "lib/hive/patrol.rb" ] }, evidence: nil)
    finding = Hive::Patrol::Finding.new(
      id: "finding-1", feature_id: "feature", category: "bug",
      severity: "medium", confidence: "high", title: "Refresh state",
      description: "Refresh can leave state inconsistent.",
      scope: scope,
      root_cause: "The refresh writes stale state.",
      reproduction: "Run the refresh twice.", evidence: evidence, fingerprint: "refresh-root",
      target_sha: git_head(project), lifecycle_state: "active",
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
end
