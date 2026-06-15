require "test_helper"
require "hive/bot/format"

class HiveBotFormatTest < Minitest::Test
  def test_html_escape_escapes_text_nodes
    assert_equal "A &amp; B &lt; C &gt; D", Hive::Bot::Format.html_escape("A & B < C > D")
  end

  def test_html_pr_link_renders_valid_http_pull_request_url
    assert_equal '<a href="https://github.com/example/repo/pull/561">#561</a>',
                 Hive::Bot::Format.html_pr_link("https://github.com/example/repo/pull/561")
  end

  def test_html_pr_link_escapes_attributes_and_strips_controls
    link = Hive::Bot::Format.html_pr_link("https://github.com/example/repo/pull/561\n")

    assert_equal '<a href="https://github.com/example/repo/pull/561">#561</a>', link
  end

  def test_html_pr_link_rejects_non_http_and_non_pr_urls
    assert_nil Hive::Bot::Format.html_pr_link("javascript:alert(1)")
    assert_nil Hive::Bot::Format.html_pr_link("https://github.com/example/repo/issues/561")
  end
end
