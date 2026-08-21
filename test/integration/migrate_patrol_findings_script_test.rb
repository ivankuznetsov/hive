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

  private

  def run_script(project, *arguments)
    Open3.capture3(RbConfig.ruby, SCRIPT, project, *arguments)
  end

  def git_head(project)
    output, = Open3.capture2("git", "-C", project, "rev-parse", "HEAD")
    output.strip
  end
end
