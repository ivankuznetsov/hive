require "test_helper"
require "hive/screenote/oauth_client"

class ScreenoteOAuthLiveTest < Minitest::Test
  BASE_URL_ENV = "HIVE_SCREENOTE_LIVE_BASE_URL".freeze
  REGISTER_ENV = "HIVE_SCREENOTE_LIVE_REGISTER".freeze
  CLIENT_ID_ENV = "HIVE_SCREENOTE_LIVE_CLIENT_ID".freeze
  AUTH_CODE_ENV = "HIVE_SCREENOTE_LIVE_AUTH_CODE".freeze
  CODE_VERIFIER_ENV = "HIVE_SCREENOTE_LIVE_CODE_VERIFIER".freeze
  REDIRECT_URI_ENV = "HIVE_SCREENOTE_LIVE_REDIRECT_URI".freeze

  def setup
    @base_url = ENV.fetch(BASE_URL_ENV, "").strip
    skip "set #{BASE_URL_ENV}=https://screenote.ai to run live Screenote OAuth tests" if @base_url.empty?

    @client = Hive::Screenote::OAuthClient.new(base_url: @base_url)
    @metadata = @client.discover
  end

  def test_live_discovery_exposes_oauth_and_mcp_metadata
    assert_match %r{\Ahttps?://}, @metadata.issuer
    assert_match %r{/oauth/authorize}, @metadata.authorization_endpoint
    assert_match %r{/oauth/token}, @metadata.token_endpoint
    assert_match %r{/oauth/register}, @metadata.registration_endpoint
    assert_match %r{/oauth/revoke}, @metadata.revocation_endpoint
    assert_match %r{\Ahttps?://}, @metadata.mcp_resource
  end

  def test_live_dynamic_client_registration_when_enabled
    skip "set #{REGISTER_ENV}=1 to exercise rate-limited Screenote dynamic registration" unless ENV[REGISTER_ENV] == "1"

    payload = @client.register("http://127.0.0.1:47391/callback", metadata: @metadata)

    assert_match(/\S+/, payload["client_id"].to_s)
    assert_includes Array(payload["redirect_uris"]), "http://127.0.0.1:47391/callback"
    assert_includes Array(payload["grant_types"]), "authorization_code"
    assert_equal "none", payload["token_endpoint_auth_method"]
  end

  def test_live_auth_code_exchange_when_preseeded
    client_id = ENV.fetch(CLIENT_ID_ENV, "").strip
    code = ENV.fetch(AUTH_CODE_ENV, "").strip
    verifier = ENV.fetch(CODE_VERIFIER_ENV, "").strip
    redirect_uri = ENV.fetch(REDIRECT_URI_ENV, "").strip
    missing = {
      CLIENT_ID_ENV => client_id,
      AUTH_CODE_ENV => code,
      CODE_VERIFIER_ENV => verifier,
      REDIRECT_URI_ENV => redirect_uri
    }.select { |_key, value| value.empty? }.keys
    skip "set #{missing.join(", ")} to run live Screenote auth-code exchange" unless missing.empty?

    payload = @client.exchange_code(
      code: code,
      verifier: verifier,
      redirect_uri: redirect_uri,
      client_id: client_id,
      metadata: @metadata
    )

    assert_match(/\S+/, payload["access_token"].to_s)
    assert_equal "Bearer", payload["token_type"] if payload.key?("token_type")
  end
end
