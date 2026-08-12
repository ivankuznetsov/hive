require "test_helper"
require "hive/plan_review/plan_signals"

class PlanReviewPlanSignalsTest < Minitest::Test
  def test_affirmative_local_plan_is_skip_eligible
    with_plan(<<~PLAN) do |path, task_folder|
      # Add local parser guard

      ## Files
      - `lib/hive/parser.rb`
      - `test/unit/parser_test.rb`

      ## Test scenarios
      - accepts a valid local input
      - rejects an empty input

      ## Rollback
      Revert the commit; this change is fully reversible and has no data migration.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path, task_folder: task_folder, max_files: 5
      )

      assert result.valid?
      assert result.skip_eligible?
      assert_equal %w[lib/hive/parser.rb test/unit/parser_test.rb], result.declared_files
      assert_empty result.mandatory_reasons
      assert_empty result.uncertainties
    end
  end

  def test_missing_affirmative_test_or_rollback_evidence_is_uncertain
    with_plan(<<~PLAN) do |path, task_folder|
      # Adjust parser wording

      ## Files
      - `lib/hive/parser.rb`
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path, task_folder: task_folder, max_files: 5
      )

      refute result.skip_eligible?
      assert_includes result.uncertainties, "tests_not_explicit"
      assert_includes result.uncertainties, "rollback_not_explicit"
    end
  end

  def test_each_sensitive_category_is_reported_in_deterministic_order
    body = <<~PLAN
      # Sensitive change

      ## Files
      - `db/migrate/20260812000000_drop_tokens.rb`
      - `lib/hive/recovery/owner.rb`
      - `.github/workflows/release.yml`

      ## Risks
      Change authentication permissions and secret handling. Drop a production
      column irreversibly. Change the public API compatibility contract and
      concurrent recovery ownership. Publish the release supply chain.
    PLAN

    with_plan(body) do |path, task_folder|
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path, task_folder: task_folder, max_files: 5
      )

      assert_equal %w[
        auth_secrets_permissions
        destructive_data_schema
        public_compatibility
        concurrency_recovery_ownership
        deployment_release_supply_chain
      ], result.mandatory_reasons.map { |entry| entry.fetch("category") }
    end
  end

  def test_protected_paths_add_a_mandatory_reason
    with_plan(<<~PLAN) do |path, task_folder|
      # Update CI

      ## Files
      - `.github/workflows/ci.yml`

      ## Test scenarios
      - validates the workflow

      ## Rollback
      Revert the commit.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path,
        task_folder: task_folder,
        max_files: 5,
        protected_paths: [ ".github/**" ]
      )

      reason = result.mandatory_reasons.last
      assert_equal "protected_path", reason.fetch("category")
      assert_equal ".github/workflows/ci.yml", reason.fetch("path")
      assert_equal ".github/**", reason.fetch("pattern")
    end
  end

  def test_symlink_traversal_invalid_utf8_and_oversize_fail_conservatively
    Dir.mktmpdir("hive-plan-signals") do |task_folder|
      outside = File.join(File.dirname(task_folder), "outside-plan.md")
      File.write(outside, "# outside\n")
      link = File.join(task_folder, "plan.md")
      File.symlink(outside, link)

      symlink = Hive::PlanReview::PlanSignals.analyze(
        plan_path: link, task_folder: task_folder
      )
      refute symlink.valid?
      assert_includes symlink.uncertainties, "plan_symlink"

      traversal = Hive::PlanReview::PlanSignals.analyze(
        plan_path: outside, task_folder: task_folder
      )
      refute traversal.valid?
      assert_includes traversal.uncertainties, "plan_outside_task"

      File.unlink(link)
      File.binwrite(link, "\xFF\xFE")
      invalid = Hive::PlanReview::PlanSignals.analyze(
        plan_path: link, task_folder: task_folder
      )
      assert_includes invalid.uncertainties, "invalid_utf8"

      File.binwrite(link, "a" * 65)
      oversized = Hive::PlanReview::PlanSignals.analyze(
        plan_path: link, task_folder: task_folder, max_bytes: 64
      )
      assert_includes oversized.uncertainties, "plan_too_large"
    ensure
      FileUtils.rm_f(outside)
    end
  end

  private

  def with_plan(body)
    Dir.mktmpdir("hive-plan-signals") do |task_folder|
      path = File.join(task_folder, "plan.md")
      File.write(path, body)
      yield path, task_folder
    end
  end
end
