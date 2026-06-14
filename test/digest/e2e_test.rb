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
      assert_includes result.message, "Feature: Digest command"
      assert_includes result.message, "Fix: Escaping"
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
