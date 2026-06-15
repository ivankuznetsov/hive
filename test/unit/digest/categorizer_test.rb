require "test_helper"
require "hive/digest/categorizer"

class HiveDigestCategorizerTest < Minitest::Test
  include HiveTestHelper

  FIXTURE = File.expand_path("../../fixtures/digest/items.json", __dir__)

  class CapturingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message)
      @warnings << message
    end
  end

  def test_maps_canned_json_to_categorized_items_by_pr_number
    grouped = {
      "alpha" => [
        item(pr_number: 10, pr_title: "Build digest"),
        item(pr_number: 11, pr_title: "Escape markdown")
      ]
    }

    result = Hive::Digest::Categorizer.map_output_file(FIXTURE, grouped: grouped, logger: nil)

    assert_equal %w[feature fix], result.fetch("alpha").map(&:category)
    assert_equal "Adds the daily digest command.", result.fetch("alpha").first.summary
    assert_same grouped.fetch("alpha").first, result.fetch("alpha").first.item
  end

  def test_unknown_category_defaults_only_that_row
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({
        "items" => [
          { "id" => "alpha/10", "category" => "mystery", "summary" => "Odd row" },
          { "id" => "alpha/11", "category" => "patrol", "summary" => "Runs maintenance." }
        ]
      }))
      grouped = {
        "alpha" => [
          item(pr_number: 10, pr_title: "Fallback title"),
          item(pr_number: 11, pr_title: "Patrol title")
        ]
      }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal [ "feature", "patrol" ], result.fetch("alpha").map(&:category)
      assert_equal "Odd row", result.fetch("alpha").first.summary
      assert_equal "Runs maintenance.", result.fetch("alpha").last.summary
    end
  end

  def test_missing_row_uses_default_summary
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({ "items" => [] }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Fallback title") ] }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal "feature", result.fetch("alpha").first.category
      assert_equal "Fallback title", result.fetch("alpha").first.summary
    end
  end

  def test_bad_agent_result_raises_model_error
    error = assert_raises(Hive::Digest::ModelError) do
      Hive::Digest::Categorizer.parse_result!(
        { status: :error, error_message: "boom" },
        output_path: FIXTURE,
        grouped: { "alpha" => [] },
        logger: nil
      )
    end

    assert_match(/boom/, error.message)
  end

  def test_missing_or_malformed_output_raises_model_error
    with_tmp_dir do |dir|
      assert_raises(Hive::Digest::ModelError) do
        Hive::Digest::Categorizer.map_output_file(File.join(dir, "missing.json"), grouped: {}, logger: nil)
      end

      bad = File.join(dir, "bad.json")
      File.write(bad, "{")

      assert_raises(Hive::Digest::ModelError) do
        Hive::Digest::Categorizer.map_output_file(bad, grouped: {}, logger: nil)
      end
    end
  end

  def test_prompt_renders_full_pr_body_and_output_path
    grouped = {
      "alpha" => [
        item(pr_number: 10, pr_title: "Build digest", pr_body: "## Summary\n\nFull body.")
      ]
    }
    categorizer = Hive::Digest::Categorizer.new(cfg: {}, run_root: Dir.mktmpdir, logger: nil)

    prompt = categorizer.render_prompt(
      grouped,
      date: Date.new(2026, 6, 13),
      output_path: "/tmp/digest-items.json"
    )

    assert_includes prompt, "Hive's daily shipped digest for 2026-06-13"
    assert_includes prompt, "Item id: alpha/10"
    assert_includes prompt, "/tmp/digest-items.json"
    assert_includes prompt, "Full body."
  end

  def test_unknown_category_warns_through_the_logger
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({
        "items" => [ { "id" => "alpha/10", "category" => "mystery", "summary" => "Odd row" } ]
      }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Fallback title") ] }
      logger = CapturingLogger.new

      Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: logger)

      assert(logger.warnings.any? { |m| m.include?("invalid category") && m.include?("alpha/10") },
             "an unknown category must warn — the only operator signal the model misbehaved")
    end
  end

  def test_missing_row_warns_through_the_logger
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({ "items" => [] }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Fallback title") ] }
      logger = CapturingLogger.new

      Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: logger)

      assert(logger.warnings.any? { |m| m.include?("omitted item") && m.include?("alpha/10") },
             "an omitted item must warn so a half-bad model run leaves a trace")
    end
  end

  def test_duplicate_id_warns_and_last_write_wins
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      File.write(path, JSON.dump({
        "items" => [
          { "id" => "alpha/10", "category" => "feature", "summary" => "First." },
          { "id" => "alpha/10", "category" => "fix", "summary" => "Second wins." }
        ]
      }))
      grouped = { "alpha" => [ item(pr_number: 10, pr_title: "Title") ] }
      logger = CapturingLogger.new

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: logger)

      assert_equal "Second wins.", result.fetch("alpha").first.summary
      assert(logger.warnings.any? { |m| m.include?("duplicate id") && m.include?("alpha/10") },
             "a duplicate model id must warn — it is attacker-steerable last-write-wins")
    end
  end

  def test_categorized_item_guard_rejects_unknown_category_and_blank_summary
    shipped = item(pr_number: 10, pr_title: "Title")
    assert_raises(ArgumentError) do
      Hive::Digest::CategorizedItem.new(item: shipped, category: "mystery", summary: "ok")
    end
    assert_raises(ArgumentError) do
      Hive::Digest::CategorizedItem.new(item: shipped, category: "feature", summary: "   ")
    end
  end

  def test_cross_project_pr_number_collision_keeps_summaries_distinct
    with_tmp_dir do |dir|
      path = File.join(dir, "items.json")
      # Two projects shipped PR #10 on the same day. Project-scoped ids keep
      # their model summaries from overwriting each other in the output map.
      File.write(path, JSON.dump({
        "items" => [
          { "id" => "alpha/10", "category" => "feature", "summary" => "Alpha PR 10." },
          { "id" => "beta/10", "category" => "fix", "summary" => "Beta PR 10." }
        ]
      }))
      grouped = {
        "alpha" => [ item(pr_number: 10, pr_title: "Alpha title") ],
        "beta" => [ item(pr_number: 10, pr_title: "Beta title", project_name: "beta") ]
      }

      result = Hive::Digest::Categorizer.map_output_file(path, grouped: grouped, logger: nil)

      assert_equal "Alpha PR 10.", result.fetch("alpha").first.summary
      assert_equal "Beta PR 10.", result.fetch("beta").first.summary
    end
  end

  def test_agent_name_fallback_chain
    assert_equal "codex",
                 Hive::Digest::Categorizer.new(cfg: { "digest" => { "agent" => "codex" } }).send(:agent_name)
    assert_equal "pi",
                 Hive::Digest::Categorizer.new(cfg: { "patrol" => { "agent" => "pi" } }).send(:agent_name)
    assert_equal "claude", Hive::Digest::Categorizer.new(cfg: {}).send(:agent_name)
  end

  def test_budget_and_timeout_fallback_chain
    tuned = Hive::Digest::Categorizer.new(
      cfg: { "budget_usd" => { "digest" => 12 }, "timeout_sec" => { "digest" => 34 } }
    )
    assert_equal 12, tuned.send(:budget_usd)
    assert_equal 34, tuned.send(:timeout_sec)

    defaulted = Hive::Digest::Categorizer.new(cfg: {})
    assert_equal Hive::Digest::Categorizer::DEFAULT_BUDGET_USD, defaulted.send(:budget_usd)
    assert_equal Hive::Digest::Categorizer::DEFAULT_TIMEOUT_SEC, defaulted.send(:timeout_sec)
  end

  private

  def item(pr_number:, pr_title:, pr_body: "body", project_name: "alpha")
    Hive::Digest::ShippedItem.new(
      project_name: project_name,
      slug: "slug-#{pr_number}",
      display_name: "Task #{pr_number}",
      pr_url: "https://example.test/pulls/#{pr_number}",
      pr_number: pr_number,
      pr_title: pr_title,
      pr_body: pr_body,
      shipped_at: Time.utc(2026, 6, 13, 12)
    )
  end
end
