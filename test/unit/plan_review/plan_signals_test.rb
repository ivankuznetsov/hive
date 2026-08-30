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

  def test_explicitly_negated_risk_statements_do_not_trigger_mandatory_review
    with_plan(<<~PLAN) do |path, task_folder|
      # Local wording change

      ## Files
      - `lib/hive/parser.rb`
      - `test/unit/parser_test.rb`

      ## Test scenarios
      - focused parser test passes

      ## Rollback
      Revert the change; no data migration is required.

      No authentication changes. Deployment is out of scope. This does not
      change the public API. No permissions changes. No concurrency changes.
      No recovery changes. No release changes.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path, task_folder:, max_files: 5
      )

      assert_empty result.mandatory_reasons
    end
  end

  def test_literal_credential_pattern_requires_mandatory_review
    token = "sk-#{'A' * 24}"
    with_plan(<<~PLAN) do |path, task_folder|
      # Update a local fixture

      **Files:**
      - `lib/hive/parser.rb`
      - `test/unit/parser_test.rb`

      **Test scenarios:**
      - focused parser test passes

      **Rollback:**
      Revert the change.

      Fixture value: #{token}
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

      assert_includes result.mandatory_reasons.map { |entry| entry.fetch("category") },
                      "auth_secrets_permissions"
      refute result.skip_eligible?
    end
  end

  def test_repeated_bold_evidence_blocks_are_parsed
    with_plan(<<~PLAN) do |path, task_folder|
      # Local parser guard

      **Files:**
      - `lib/hive/parser.rb`

      **Test scenarios:**
      - accepts a valid input

      **Files:**
      - `test/unit/parser_test.rb`

      **Test scenarios:**
      - rejects an invalid input

      **Rollback:**
      Revert the commit; the change is reversible.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

      assert_equal %w[lib/hive/parser.rb test/unit/parser_test.rb], result.declared_files
      assert_equal 2, result.test_scenarios.length
      assert result.skip_eligible?
    end
  end

  def test_unquoted_frontmatter_date_and_list_prefixed_evidence_are_parsed
    with_plan(<<~PLAN) do |path, task_folder|
      ---
      date: 2026-08-30
      ---
      # Local parser guard

      - **Files:**
        - `lib/hive/parser.rb`
        - `test/unit/parser_test.rb`
      - **Test scenarios:**
        1. accepts a valid input
      - **Rollback:** Revert the commit.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

      assert_equal %w[lib/hive/parser.rb test/unit/parser_test.rb], result.declared_files
      assert_equal [ "accepts a valid input" ], result.test_scenarios
      assert result.rollback_explicit
      assert result.skip_eligible?
      refute_includes result.uncertainties, "malformed_frontmatter"
    end
  end

  def test_inline_bold_files_label_is_parsed
    with_plan(<<~PLAN) do |path, task_folder|
      # Local parser guard

      **Files:** `lib/hive/parser.rb`, `test/unit/parser_test.rb`

      **Test scenarios:**
      - accepts a valid input

      **Rollback:** Revert the commit.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

      assert_equal %w[lib/hive/parser.rb test/unit/parser_test.rb], result.declared_files
      assert result.skip_eligible?
    end
  end

  def test_oversized_frontmatter_is_uncertain_even_with_complete_markdown_evidence
    oversized = "note: #{'x' * (64 * 1024)}"
    with_plan(<<~PLAN) do |path, task_folder|
      ---
      #{oversized}
      ---
      # Local parser guard

      **Files:**
      - `lib/hive/parser.rb`
      - `test/unit/parser_test.rb`

      **Test scenarios:**
      - focused parser test passes

      **Rollback:**
      Revert the commit.
    PLAN
      result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

      assert_includes result.uncertainties, "frontmatter_too_large"
      refute result.skip_eligible?
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

  def test_unreadable_and_absent_plans_are_reported_distinctly
    Dir.mktmpdir("hive-plan-signals") do |task_folder|
      absent = Hive::PlanReview::PlanSignals.analyze(
        plan_path: File.join(task_folder, "never-written.md"), task_folder:
      )

      refute absent.valid?
      assert_includes absent.uncertainties, "plan_missing"

      path = File.join(task_folder, "plan.md")
      File.write(path, "# Plan\n")
      File.chmod(0o000, path)
      skip "running as a user that bypasses file permissions" if File.readable?(path)

      unreadable = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

      refute unreadable.valid?
      assert_includes unreadable.uncertainties, "plan_unreadable"
    ensure
      File.chmod(0o600, path) if path && File.exist?(path)
    end
  end

  def test_non_numeric_policy_limits_are_rejected_rather_than_raised
    with_plan("# Plan\n\n## Files\n- `lib/hive/parser.rb`\n") do |path, task_folder|
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path, task_folder:, max_files: "many"
      )

      refute result.valid?
      assert_includes result.uncertainties, "invalid_policy_limits"
    end
  end

  def test_every_unusable_frontmatter_shape_is_flagged_without_raising
    bodies = {
      "unterminated" => "---\nfiles:\n  - lib/hive/parser.rb\n\n# Plan\n",
      "not a mapping" => "---\n- lib/hive/parser.rb\n- test/unit/parser_test.rb\n---\n\n# Plan\n",
      "unparsable yaml" => "---\nfiles: [unclosed\n---\n\n# Plan\n"
    }
    bodies.each do |shape, body|
      with_plan(body) do |path, task_folder|
        result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)

        assert result.valid?, "#{shape} frontmatter should still yield a usable result"
        assert_includes result.uncertainties, "malformed_frontmatter", shape
      end
    end
  end

  def test_traversing_declared_and_protected_paths_are_dropped_as_uncertain
    body = <<~PLAN
      # Plan

      ## Files
      - `../outside/secrets.rb`
      - `lib/hive/parser.rb`
    PLAN
    with_plan(body) do |path, task_folder|
      result = Hive::PlanReview::PlanSignals.analyze(
        plan_path: path, task_folder:, protected_paths: [ "../escaping/**", "lib/hive/**" ]
      )

      assert_equal %w[lib/hive/parser.rb], result.declared_files
      assert_includes result.uncertainties, "invalid_declared_path"
      assert_includes result.uncertainties, "invalid_protected_path_glob"
    end
  end

  def test_a_literal_credential_escalates_alongside_other_sensitive_categories
    body = <<~PLAN
      # Plan

      ## Files
      - `db/migrate/20260815000000_add_index.rb`
      - `lib/hive/parser.rb`

      ## Notes
      Replace the placeholder with aws_secret_access_key = AKIAIOSFODNN7EXAMPLE
    PLAN
    with_plan(body) do |path, task_folder|
      result = Hive::PlanReview::PlanSignals.analyze(plan_path: path, task_folder:)
      categories = result.mandatory_reasons.map { |reason| reason.fetch("category") }

      assert_includes categories, "auth_secrets_permissions"
      refute_equal 1, categories.length, "the migration path must also be reported"
      assert_equal "literal_credential_pattern", result.mandatory_reasons.first.fetch("evidence")
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
