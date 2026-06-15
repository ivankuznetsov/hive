require "test_helper"
require "hive/digest"

class HiveDigestE2ETest < Minitest::Test
  include HiveTestHelper

  FakeShipTimes = Struct.new(:times) do
    def shipped_at(hive_state_path:, slug:)
      times.fetch([ hive_state_path, slug ])
    end
  end

  def setup
    missing = %w[HIVE_TELEGRAM_BOT_TOKEN HIVE_DIGEST_TEST_CHAT_ID].select { |key| ENV[key].to_s.strip.empty? }
    flunk "missing required live digest env vars: #{missing.join(', ')}" unless missing.empty?
  end

  def test_live_agent_and_telegram_digest_over_fixture_tasks
    with_tmp_global_config do |home|
      project = create_project(home, "alpha")
      first = create_done_task(project, "feature-260613-abcd", display_name: "Feature: Digest command", pr_number: 10)
      second = create_done_task(project, "fix-260613-abcd", display_name: "Fix: Escaping", pr_number: 11)
      write_global_config(home, [ project ])
      collector = Hive::Digest::Collector.new(
        registry: -> { [ project ] },
        ship_times: FakeShipTimes.new({
          [ project.fetch("hive_state_path"), first ] => Time.utc(2026, 6, 13, 12),
          [ project.fetch("hive_state_path"), second ] => Time.utc(2026, 6, 13, 13)
        })
      )

      result = Hive::Digest.run(
        date: Date.new(2026, 6, 13),
        collector: collector,
        cfg: Hive::Config.load_global_digest_config
      )

      assert_equal :sent, result.status
      assert_message_id result.delivery.responses.first

      # IU6: the live model's categorized output must cover EVERY fixture item.
      # The display_name substring checks below render as the link LABEL
      # regardless of model output, and an empty {"items":[]} still yields
      # status: :sent with fallback summaries — so neither proves the model
      # ran. Inspect the categorizer's raw items.json to prove it did.
      items_files = Dir[File.join(Hive::Paths.state_home, "digest", "runs", "*", "items.json")]
      assert_equal 1, items_files.size, "the categorizer must write exactly one items.json"
      rows = JSON.parse(File.read(items_files.first)).fetch("items")
      ids = rows.map { |row| row["id"] }
      assert_includes ids, "alpha/10", "the model output must cover the first fixture item"
      assert_includes ids, "alpha/11", "the model output must cover the second fixture item"
      rows.each do |row|
        assert Hive::Digest::Categories.valid?(row["category"].to_s),
               "the live model must assign a valid category to #{row['id']}"
        refute row["summary"].to_s.strip.empty?,
               "the live model must write a non-empty summary for #{row['id']}"
      end

      # Prove the rendered digest used the MODEL's summary, not the pr_title
      # fallback, for at least one item — an empty model response would
      # otherwise pass via the default (fallback) summaries.
      fallbacks = collector.for_date(Date.new(2026, 6, 13)).values.flatten.map { |item| item.pr_title.to_s.strip }
      model_summaries = rows.map { |row| row["summary"].to_s.strip }
      assert(model_summaries.any? { |summary| !fallbacks.include?(summary) },
             "at least one rendered summary must be the model's own, not a pr_title fallback")

      assert_includes result.message, "Feature: Digest command"
      assert_includes result.message, "Fix: Escaping"
    end
  end

  # The failed-notice MarkdownV2 path is the exact class of bug the escaping
  # exists to prevent, so exercise it against the REAL Telegram API: force a
  # ModelError (the only realistic trigger we can't summon from a live model
  # deterministically) but let the real Sender render + deliver the notice.
  def test_live_telegram_failed_notice_when_categorizer_raises
    with_tmp_global_config do |home|
      project = create_project(home, "alpha")
      slug = create_done_task(project, "feature-260613-abcd",
                              display_name: "Feature: Digest command", pr_number: 10)
      write_global_config(home, [ project ])
      collector = Hive::Digest::Collector.new(
        registry: -> { [ project ] },
        ship_times: FakeShipTimes.new(
          { [ project.fetch("hive_state_path"), slug ] => Time.utc(2026, 6, 13, 12) }
        )
      )
      failing_categorizer = Object.new
      def failing_categorizer.categorize(_grouped, date:)
        raise Hive::Digest::ModelError, "categorizer unavailable (live failed-notice test)"
      end

      result = Hive::Digest.run(
        date: Date.new(2026, 6, 13),
        collector: collector,
        categorizer: failing_categorizer,
        cfg: Hive::Config.load_global_digest_config
      )

      assert_equal :failed_notice, result.status
      assert_includes result.message, "failed"
      # Telegram accepted the MarkdownV2-escaped failure notice for real.
      assert_message_id result.delivery.responses.first
    end
  end

  def test_live_telegram_empty_digest
    with_tmp_global_config do |home|
      project = create_project(home, "alpha")
      write_global_config(home, [ project ])
      collector = Hive::Digest::Collector.new(
        registry: -> { [ project ] },
        ship_times: FakeShipTimes.new({})
      )

      result = Hive::Digest.run(
        date: Date.new(2026, 6, 13),
        collector: collector,
        cfg: Hive::Config.load_global_digest_config
      )

      assert_equal :empty, result.status
      assert_equal "Nothing shipped today 🌙", result.message
      assert_message_id result.delivery.responses.first
    end
  end

  private

  def write_global_config(home, projects)
    File.write(File.join(home, "config.yml"), {
      "registered_projects" => projects,
      "digest" => {
        "enabled" => true,
        "agent" => ENV["HIVE_DIGEST_TEST_AGENT"],
        "max_catchup_days" => 7
      },
      "bot" => {
        "digest_chat_id" => Integer(ENV.fetch("HIVE_DIGEST_TEST_CHAT_ID")),
        "chat_id_allowlist" => []
      }
    }.to_yaml)
  end

  def create_project(root, name)
    path = File.join(root, name)
    hive_state_path = File.join(path, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state_path, "stages", "9-done"))
    { "name" => name, "path" => path, "hive_state_path" => hive_state_path }
  end

  def create_done_task(entry, slug, display_name:, pr_number:)
    folder = File.join(entry.fetch("hive_state_path"), "stages", "9-done", slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: pr_number, slug: slug, display_name: display_name)
    File.write(File.join(folder, "pr.md"), <<~MD)
      ---
      pr_url: https://example.test/pulls/#{pr_number}
      pr_number: #{pr_number}
      ---

      ## Summary

      #{display_name} ships as part of the daily digest live test.

      ## Details

      This body is intentionally short but complete enough for a real model
      to classify and summarize.
    MD
    slug
  end

  def assert_message_id(response)
    message_id =
      if response.respond_to?(:message_id)
        response.message_id
      elsif response.is_a?(Hash)
        response["message_id"] || response[:message_id]
      end

    assert message_id.to_i.positive?, "Telegram response must include a positive message_id"
  end
end
