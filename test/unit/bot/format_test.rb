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

  # Attribute-breakout defense: URI.parse accepts a `"`-bearing href, so the
  # anchor IS built — the injection defense is html_attr_escape turning each
  # `"` into &quot;, which keeps the payload inside the href="" value. No
  # raw double-quote may survive to close the attribute early.
  def test_html_pr_link_escapes_double_quotes_in_href_no_attribute_breakout
    link = Hive::Bot::Format.html_pr_link(
      %q{https://github.com/example/repo/pull/561?x="onmouseover="alert(1)}
    )

    assert_equal(
      %q{<a href="https://github.com/example/repo/pull/561?x=&quot;onmouseover=&quot;alert(1)">#561</a>},
      link
    )
    refute_includes link, %q("onmouseover),
                    "no raw double-quote may survive inside the href attribute value"
  end

  def test_html_attr_escape_escapes_double_quotes
    assert_equal "a &quot;b&quot; c", Hive::Bot::Format.html_attr_escape(%q(a "b" c))
  end
end
