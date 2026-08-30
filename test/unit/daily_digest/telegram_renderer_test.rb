require "test_helper"
require "hive/daily_digest/telegram_renderer"

class DailyDigestTelegramRendererTest < Minitest::Test
  def test_renders_bounded_incomplete_html_without_questions_or_active_controls
    rendered = Hive::DailyDigest::TelegramRenderer.new(
      web_origin: "https://hive.example/"
    ).render(record)

    assert_equal :html, rendered.parse_mode
    assert_equal "https://hive.example/digests/2026-08-30", rendered.web_url
    assert_match(/Incomplete data/, rendered.text)
    assert_match(/demo&lt;bad&gt;.*waiting-task/m, rendered.text)
    assert_match(/git.*hub.*demo/m, rendered.text)
    assert_match(%r{<a href="https://hive\.example/digests/2026-08-30">}, rendered.text)
    refute_includes rendered.text, "PRIVATE QUESTION"
    refute_includes rendered.text, "SECRET REASON"
    refute_includes rendered.text, "\e]8"
    refute_includes rendered.text, "\nforged"
    assert_operator rendered.text.length, :<=, Hive::DailyDigest::TelegramRenderer::MAX_CHARS
    assert_match(/\A[0-9a-f]{64}\z/, rendered.payload_hash)
    assert_match(/\A[0-9a-f]{64}\z/, rendered.amendment_frontier)
  end

  def test_large_records_remain_one_bounded_payload_with_a_valid_link
    large = record.merge(
      "items" => Array.new(100) do |index|
        item.merge("fact_id" => "fact-#{index}", "summary" => "x" * 1_000)
      end
    )

    rendered = Hive::DailyDigest::TelegramRenderer.new(
      web_origin: "http://127.0.0.1:4567"
    ).render(large)

    assert_operator rendered.text.length, :<=, Hive::DailyDigest::TelegramRenderer::MAX_CHARS
    assert_equal 100, rendered.counts.fetch("items")
    assert_includes rendered.text, "+92 more changes"
    assert_includes rendered.text, "Open the complete digest"
  end

  def test_rejects_an_unsafe_web_origin
    error = assert_raises(Hive::ConfigError) do
      Hive::DailyDigest::TelegramRenderer.new(web_origin: "javascript:alert(1)")
    end
    assert_match(/http\(s\)/, error.message)
  end

  private

  def record
    {
      "local_date" => "2026-08-30", "record_id" => "a" * 64,
      "lifecycle" => "closed", "completeness" => "partial", "content" => "non_empty",
      "effective_completeness" => "partial", "effective_content" => "non_empty",
      "items" => [ item ],
      "attention" => [ {
        "attention_id" => "attention-1", "kind" => "unanswered",
        "project" => "demo<bad>", "task_slug" => "waiting-task", "stage" => "2-brainstorm",
        "state" => "waiting", "waiting_age_seconds" => 3_600,
        "question" => "PRIVATE QUESTION", "binding" => "SECRET BINDING"
      } ],
      "effective_gaps" => [ {
        "gap_id" => "gap-1", "source" => "git\e]8;;bad\a\nhub",
        "scope" => "demo\nforged", "reason" => "SECRET REASON"
      } ],
      "amendments" => [ { "amendment_id" => "late-one" } ]
    }
  end

  def item
    {
      "fact_id" => "fact-one", "kind" => "stage_transition",
      "project" => "demo", "summary" => "advanced\nforged"
    }
  end
end
