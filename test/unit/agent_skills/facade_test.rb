require "test_helper"

require "hive/agent_skills"

class AgentSkillsFacadeTest < Minitest::Test
  include HiveTestHelper

  def test_render_is_deterministic_for_every_projection_platform
    %w[openclaw claude codex pi].each do |platform|
      first = Hive::AgentSkills.render(platform)
      second = Hive::AgentSkills.render(platform)

      assert_equal first.to_h, second.to_h
      assert_equal first.files, second.files
      assert_equal platform, first.platform
      assert_includes first.files, ".hive-skill.json"
    end
  end

  def test_plan_is_nonmutating_and_apply_publishes_the_complete_projection
    with_tmp_dir do |trusted_root|
      root = File.join(trusted_root, "agent-home")
      projection = Hive::AgentSkills.render("claude")

      plan = Hive::AgentSkills.plan(
        root: root,
        trusted_root: trusted_root,
        projection: projection
      )

      assert_equal "publish", plan.action
      assert_equal "absent", plan.inspection.state
      assert plan.inspection.snapshot.frozen?
      assert plan.inspection.issues.all?(&:frozen?)
      refute File.exist?(root)

      result = Hive::AgentSkills.apply(plan)
      assert_equal "healthy", result.state
      assert_equal projection.files.keys.sort, installed_files(result.destination)

      noop = Hive::AgentSkills.plan(
        root: root,
        trusted_root: trusted_root,
        projection: projection
      )
      assert_equal "noop", noop.action
      assert_equal result.snapshot, Hive::AgentSkills.apply(noop).snapshot
    end
  end

  def test_apply_refuses_a_destination_that_changed_after_preview
    with_tmp_dir do |trusted_root|
      root = File.join(trusted_root, "agent-home")
      plan = Hive::AgentSkills.plan(
        root: root,
        trusted_root: trusted_root,
        projection: Hive::AgentSkills.render("codex")
      )
      FileUtils.mkdir_p(root, mode: 0o700)

      assert_raises(Hive::AgentSkills::StalePlan) do
        Hive::AgentSkills.apply(plan)
      end
    end
  end

  def test_foreign_destination_produces_a_refusal_plan
    with_tmp_dir do |trusted_root|
      root = File.join(trusted_root, "agent-home")
      destination = File.join(root, "skills", "hive")
      FileUtils.mkdir_p(destination, mode: 0o700)
      File.write(File.join(destination, "SKILL.md"), "user-owned\n")

      plan = Hive::AgentSkills.plan(
        root: root,
        trusted_root: trusted_root,
        projection: Hive::AgentSkills.render("pi")
      )

      assert_equal "refuse", plan.action
      assert_equal "foreign", plan.inspection.state
      assert_raises(Hive::AgentSkills::ForeignContent) do
        Hive::AgentSkills.apply(plan)
      end
    end
  end

  private

  def installed_files(destination)
    Dir.glob(File.join(destination, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
      next unless File.file?(path)

      path.delete_prefix("#{destination}/")
    end.sort
  end
end
