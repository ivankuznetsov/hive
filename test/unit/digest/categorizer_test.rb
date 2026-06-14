require "test_helper"
require "hive/digest/categorizer"

class HiveDigestCategorizerTest < Minitest::Test
  include HiveTestHelper

  FIXTURE = File.expand_path("../../fixtures/digest/items.json", __dir__)

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
          { "id" => "10", "category" => "mystery", "summary" => "Odd row" },
          { "id" => "11", "category" => "patrol", "summary" => "Runs maintenance." }
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
    assert_includes prompt, "Item id: 10"
    assert_includes prompt, "/tmp/digest-items.json"
    assert_includes prompt, "Full body."
  end

  private

  def item(pr_number:, pr_title:, pr_body: "body")
    Hive::Digest::ShippedItem.new(
      project_name: "alpha",
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
