require "test_helper"
require "base64"
require "json"
require "net/http"
require "securerandom"
require "uri"
require "hive/screenote/mcp_client"
require "hive/screenote/oauth_client"

class ScreenoteCaptureLiveTest < Minitest::Test
  BASE_URL_ENV = "HIVE_SCREENOTE_LIVE_BASE_URL".freeze
  TEST_TOKEN_ENDPOINT_ENV = "HIVE_SCREENOTE_TEST_TOKEN_ENDPOINT".freeze
  TEST_TOKEN_SECRET_ENV = "HIVE_SCREENOTE_TEST_TOKEN_SECRET".freeze
  PROJECT_ID_ENV = "HIVE_SCREENOTE_TEST_PROJECT_ID".freeze
  PNG_BYTES = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
  ).freeze

  def setup
    @endpoint = ENV.fetch(TEST_TOKEN_ENDPOINT_ENV, "").strip
    @secret = ENV.fetch(TEST_TOKEN_SECRET_ENV, "").strip
    @project_id = ENV.fetch(PROJECT_ID_ENV, "").strip
    missing = {
      TEST_TOKEN_ENDPOINT_ENV => @endpoint,
      TEST_TOKEN_SECRET_ENV => @secret,
      PROJECT_ID_ENV => @project_id
    }.select { |_key, value| value.empty? }.keys
    skip "blocked until Screenote ships the non-interactive test-token endpoint; set #{missing.join(", ")}" unless missing.empty?
  end

  def test_live_create_screenshot_upload_round_trips_png_bytes
    token = mint_test_token
    base_url = ENV.fetch(BASE_URL_ENV, Hive::Screenote::OAuthClient::DEFAULT_BASE_URL)
    metadata = Hive::Screenote::OAuthClient.discover(base_url)
    result = Hive::Screenote::McpClient.new(
      resource: metadata.mcp_resource,
      access_token: token
    ).call_tool("create_screenshot_upload", upload_arguments)
    upload_url = extract_first(result, "upload_url", "signed_upload_url", "signed_url")
    screenote_url = extract_first(result, "screenote_url", "annotate_url", "view_url", "url")

    assert_match %r{\Ahttps?://}, upload_url
    put_image(upload_url)
    assert_match %r{\Ahttps?://}, screenote_url
  end

  private

  def upload_arguments
    {
      project_id: @project_id,
      title: "Hive live capture #{SecureRandom.hex(4)}",
      filename: "hive-live-capture.png",
      content_type: "image/png"
    }
  end

  def mint_test_token
    uri = URI(@endpoint)
    req = Net::HTTP::Post.new(uri)
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{@secret}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(scope: Hive::Screenote::OAuthClient::SCOPE)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    raise "Screenote test-token endpoint failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body.to_s).fetch("access_token")
  end

  def put_image(upload_url)
    uri = URI(upload_url)
    req = Net::HTTP::Put.new(uri)
    req["Content-Type"] = "image/png"
    req.body = PNG_BYTES
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
    assert response.is_a?(Net::HTTPSuccess), "signed upload failed (HTTP #{response.code})"
  end

  def extract_first(value, *keys)
    case value
    when Hash
      keys.each do |key|
        found = value[key]
        return found.to_s unless found.to_s.empty?
      end
      extract_first(value["structuredContent"], *keys) ||
        extract_first(parse_text_content(value), *keys)
    end
  end

  def parse_text_content(value)
    entry = Array(value["content"]).find { |item| item.is_a?(Hash) && item["text"].to_s.strip.start_with?("{") }
    entry ? JSON.parse(entry["text"]) : nil
  rescue JSON::ParserError
    nil
  end
end
