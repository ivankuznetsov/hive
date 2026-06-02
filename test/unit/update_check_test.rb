require "test_helper"
require "net/http"
require "hive/update_check"

class UpdateCheckTest < Minitest::Test
  include HiveTestHelper

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

  def test_non_string_tag_is_swallowed
    # tag_name as a number → tag.empty? raises NoMethodError → outer rescue → nil
    assert_nil Hive::UpdateCheck.latest(current: "0.1.5", http: ->(_url) { '{"tag_name": 123}' })
  end

  def test_real_http_path_parses_success_response
    body = '{"tag_name":"v9.9.9"}'
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_req| response }
    # No `http:` injected → exercises the real Net::HTTP code path in http_get.
    with_replaced_singleton_method(Net::HTTP, :start, ->(*_a, **_k, &blk) { blk.call(fake_http) }) do
      result = Hive::UpdateCheck.latest(current: "0.1.5")
      assert result
      assert_equal "9.9.9", result.latest
      assert result.behind?
    end
  end

  def test_real_http_path_returns_nil_on_non_success
    response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_req| response }
    with_replaced_singleton_method(Net::HTTP, :start, ->(*_a, **_k, &blk) { blk.call(fake_http) }) do
      assert_nil Hive::UpdateCheck.latest(current: "0.1.5"), "a non-2xx response yields no info"
    end
  end

  def test_releases_url_defaults_to_github
    with_env("HIVE_RELEASES_API_URL" => nil) do
      assert_equal Hive::UpdateCheck::API_URL, Hive::UpdateCheck.releases_url
    end
  end

  def test_releases_url_honors_env_override
    with_env("HIVE_RELEASES_API_URL" => "http://127.0.0.1:9999/releases/latest") do
      assert_equal "http://127.0.0.1:9999/releases/latest", Hive::UpdateCheck.releases_url
    end
  end

  def test_releases_url_treats_empty_override_as_unset
    with_env("HIVE_RELEASES_API_URL" => "") do
      assert_equal Hive::UpdateCheck::API_URL, Hive::UpdateCheck.releases_url
    end
  end

  def test_latest_probes_the_overridden_url
    with_env("HIVE_RELEASES_API_URL" => "http://localhost:1234/x") do
      seen = nil
      result = Hive::UpdateCheck.latest(current: "0.1.5", http: ->(url) { seen = url; '{"tag_name":"v0.2.0"}' })
      assert_equal "http://localhost:1234/x", seen, "the probe must hit the overridden URL"
      assert_equal "0.2.0", result.latest
    end
  end

  def test_http_get_use_ssl_follows_the_url_scheme
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"tag_name":"v1.0.0"}')
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_req| response }
    captured = []
    stub = lambda do |*_args, **kwargs, &blk|
      captured << kwargs[:use_ssl]
      blk.call(fake_http)
    end
    with_replaced_singleton_method(Net::HTTP, :start, stub) do
      with_env("HIVE_RELEASES_API_URL" => "https://example.test/x") { Hive::UpdateCheck.latest(current: "0.1.0") }
      with_env("HIVE_RELEASES_API_URL" => "http://127.0.0.1:9/x") { Hive::UpdateCheck.latest(current: "0.1.0") }
    end
    assert_equal [ true, false ], captured, "use_ssl must follow the URL scheme (https→true, http→false)"
  end
end
