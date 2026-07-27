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
      assert_equal "publish", plan.to_h.fetch("action")
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

  def test_noop_plan_refuses_a_destination_that_changed_after_preview
    with_tmp_dir do |trusted_root|
      root = File.join(trusted_root, "agent-home")
      projection = Hive::AgentSkills.render("claude")
      Hive::AgentSkills.apply(
        Hive::AgentSkills.plan(
          root: root, trusted_root: trusted_root, projection: projection
        )
      )
      plan = Hive::AgentSkills.plan(
        root: root, trusted_root: trusted_root, projection: projection
      )
      File.open(File.join(plan.inspection.destination, "SKILL.md"), "a") do |file|
        file.write("\nchanged after preview\n")
      end

      assert_raises(Hive::AgentSkills::StalePlan) do
        Hive::AgentSkills.apply(plan)
      end
    end
  end

  def test_plan_contract_rejects_wrong_projection_report_and_destination
    with_tmp_dir do |trusted_root|
      root = File.join(trusted_root, "agent-home")
      projection = Hive::AgentSkills.render("claude")
      inspection = Hive::AgentSkills.inspect(
        root: root, trusted_root: trusted_root, projection: projection
      )
      attributes = {
        action: "publish",
        projection: projection,
        root: root,
        trusted_root: trusted_root,
        inspection: inspection
      }

      assert_raises(ArgumentError) do
        Hive::AgentSkills::Plan.new(**attributes.merge(projection: Object.new))
      end
      assert_raises(ArgumentError) do
        Hive::AgentSkills::Plan.new(**attributes.merge(inspection: Object.new))
      end

      other = Hive::AgentSkills::ProjectionReport.new(
        state: inspection.state,
        destination: File.join(root, "other"),
        manifest: inspection.manifest,
        files: inspection.files,
        snapshot: inspection.snapshot,
        issues: inspection.issues
      )
      assert_raises(ArgumentError) do
        Hive::AgentSkills::Plan.new(**attributes.merge(inspection: other))
      end
    end
  end

  def test_projection_copies_and_freezes_the_bytes_bound_to_a_plan
    with_tmp_dir do |trusted_root|
      canonical = Hive::AgentSkills.render("claude")
      source_files = canonical.files.to_h do |path, content|
        [ path.dup, content.dup ]
      end
      projection = Hive::AgentSkills::Projection.new(
        platform: canonical.platform.dup,
        invocation: canonical.invocation.dup,
        destination_relative: canonical.destination_relative.dup,
        skill_version: canonical.skill_version.dup,
        canonical_digest: canonical.canonical_digest.dup,
        files: source_files
      )
      root = File.join(trusted_root, "agent-home")
      plan = Hive::AgentSkills.plan(
        root: root, trusted_root: trusted_root, projection: projection
      )
      expected_skill = projection.files.fetch("SKILL.md")

      source_files["SKILL.md"].replace("changed after preview\n")
      source_files["new.md"] = "not previewed\n"

      assert_raises(FrozenError) { projection.files["new.md"] = "blocked\n" }
      assert_raises(FrozenError) do
        projection.files.fetch("SKILL.md").replace("blocked\n")
      end

      result = Hive::AgentSkills.apply(plan)
      assert_equal expected_skill.b,
                   File.binread(File.join(result.destination, "SKILL.md"))
      refute File.exist?(File.join(result.destination, "new.md"))
    end
  end

  def test_projection_rejects_invalid_public_shapes
    canonical = Hive::AgentSkills.render("claude")
    attributes = {
      platform: canonical.platform,
      invocation: canonical.invocation,
      destination_relative: canonical.destination_relative,
      skill_version: canonical.skill_version,
      canonical_digest: canonical.canonical_digest,
      files: canonical.files
    }

    error = assert_raises(ArgumentError) do
      Hive::AgentSkills::Projection.new(**attributes.merge(files: []))
    end
    assert_includes error.message, "String-to-String mapping"

    %i[
      platform invocation destination_relative skill_version canonical_digest
    ].each do |field|
      error = assert_raises(ArgumentError) do
        Hive::AgentSkills::Projection.new(**attributes.merge(field => ""))
      end
      assert_includes error.message, field.to_s
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
