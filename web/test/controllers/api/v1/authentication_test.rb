# frozen_string_literal: true

require "test_helper"
require "hive/remote/token_store"

class ApiAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    @loopback = ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    @legacy_loopback = ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    configure_owner!(owner: "operator")
    @issued = Hive::Remote::TokenStore.new.create(name: "reader", scopes: ["read"], all_projects: true)
    @headers = { "Authorization" => "Bearer #{@issued.fetch('token')}" }
  end

  teardown do
    @loopback ? ENV["HIVE_WEB_LOCAL_LOOPBACK"] = @loopback : ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    @legacy_loopback ? ENV["HIVEBOX_LOCAL_LOOPBACK"] = @legacy_loopback : ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
  end

  test "bearer only context and immediate revocation" do
    get "/api/v1/context"
    assert_response :unauthorized
    get "/api/v1/context", params: { access_token: @issued.fetch("token") }
    assert_response :unauthorized
    get "/api/v1/context", headers: @headers
    assert_response :success
    payload = response.parsed_body
    assert_equal "hive-remote", payload.fetch("schema")
    assert_equal "v1", payload.dig("data", "api_version")
    assert_equal ["read"], payload.dig("data", "token", "scopes")
    refute_includes response.body, @issued.fetch("token")
    Hive::Remote::TokenStore.new.revoke(@issued.fetch("id"))
    get "/api/v1/context", headers: @headers
    assert_response :unauthorized
  end

  test "an authenticated browser cookie is not API authentication" do
    sign_in!(login: "operator")
    get "/api/v1/context"
    assert_response :unauthorized
    get "/api/v1/context", headers: @headers.merge("Authorization" => "Basic #{@issued.fetch('token')}")
    assert_response :unauthorized
  end

  test "owner and both loopback predicates have identical safe responses" do
    configure_owner!(owner: "")
    get "/api/v1/context", headers: @headers
    assert_response :service_unavailable
    unavailable = response.body
    error = assert_raises(Hive::ConfigError) do
      Hive::Remote::TokenStore.new.create(name: "blocked", scopes: [], all_projects: true)
    end
    assert_includes error.message, "web.github.owner"
    configure_owner!(owner: "operator")
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "1"
    get "/api/v1/context", headers: @headers.merge("HOST" => "localhost")
    assert_response :service_unavailable
    assert_equal unavailable, response.body
    ENV.delete("HIVE_WEB_LOCAL_LOOPBACK")
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    get "/api/v1/context", headers: @headers
    assert_equal unavailable, response.body
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "0"
    get "/api/v1/context", headers: @headers
    assert_response :success
  end

  test "API logs contain fixed audit fields without request credentials or network identity" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original = Rails.logger
    Rails.logger = logger
    get "/api/v1/context", params: { access_token: "secret-query-sentinel" }, headers: @headers.merge("REMOTE_ADDR" => "198.51.100.99")
    assert_response :unauthorized
    log = output.string
    refute_includes log, "secret-query-sentinel"
    refute_includes log, @issued.fetch("token")
    refute_includes log, "198.51.100.99"
    assert_includes log, "invalid_token"
    refute_includes log, "Started GET"
  ensure
    Rails.logger = original if original
  end

  test "oversized bodies are refused before JSON parsing and receipts interlock is identical" do
    with_replaced_singleton_method(Hive::CommandOperation, :receipts_installed?, ->(*) { false }) do
      post "/api/v1/not-a-route", params: "invalid JSON", headers: @headers.merge("CONTENT_TYPE" => "application/json")
      assert_response :service_unavailable
      assert_equal JSON.generate(Hive::Remote::Protocol.unavailable), response.body
    end
    with_replaced_singleton_method(Hive::CommandOperation, :receipts_installed?, ->(*) { true }) do
      post "/api/v1/not-a-route", params: "x" * (256 * 1024 + 1), headers: @headers.merge("CONTENT_TYPE" => "application/json")
      assert_response :content_too_large
      assert_equal "too_large", response.parsed_body.dig("error", "code")
    end
  end
end
