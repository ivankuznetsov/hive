require "test_helper"
require "hive/update_check"

class UpdateCheckTest < Minitest::Test
  def stub_http(body)
    ->(_url) { body }
  end

  def test_behind_when_latest_is_newer
    result = Hive::UpdateCheck.latest(current: "0.1.5", http: stub_http('{"tag_name":"v0.1.7"}'))
    assert result
    assert_equal "0.1.7", result.latest
    assert_equal "0.1.5", result.current
    assert result.behind?
  end

  def test_not_behind_when_current_equals_latest
    result = Hive::UpdateCheck.latest(current: "0.1.7", http: stub_http('{"tag_name":"v0.1.7"}'))
    assert result
    refute result.behind?
  end

  def test_not_behind_when_current_is_ahead
    # Local dev build ahead of the latest tag must never be flagged "behind".
    result = Hive::UpdateCheck.latest(current: "0.2.0", http: stub_http('{"tag_name":"v0.1.7"}'))
    assert result
    refute result.behind?
  end

  def test_handles_tag_without_v_prefix
    result = Hive::UpdateCheck.latest(current: "0.1.5", http: stub_http('{"tag_name":"0.1.7"}'))
    assert_equal "0.1.7", result.latest
    assert result.behind?
  end

  def test_returns_nil_when_http_raises
    boom = ->(_url) { raise SocketError, "getaddrinfo: Name or service not known" }
    assert_nil Hive::UpdateCheck.latest(current: "0.1.5", http: boom)
  end

  def test_returns_nil_on_malformed_json
    assert_nil Hive::UpdateCheck.latest(current: "0.1.5", http: stub_http("not json"))
  end

  def test_returns_nil_when_body_nil
    assert_nil Hive::UpdateCheck.latest(current: "0.1.5", http: ->(_url) { nil })
  end

  def test_returns_nil_when_tag_missing
    assert_nil Hive::UpdateCheck.latest(current: "0.1.5", http: stub_http('{"name":"no tag here"}'))
  end

  def test_unparseable_version_is_not_behind
    refute Hive::UpdateCheck.newer?("not.a.version", "0.1.5")
  end
end
