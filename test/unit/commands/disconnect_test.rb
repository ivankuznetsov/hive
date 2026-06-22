require "test_helper"
require "hive/commands/disconnect"

class DisconnectCommandTest < Minitest::Test
  include HiveTestHelper

  class FakeOAuth
    attr_reader :revoked

    def initialize(fail_revoke: false)
      @fail_revoke = fail_revoke
      @revoked = []
    end

    def discover
      Hive::Screenote::OAuthClient::Discovery.new(
        issuer: "https://screenote.test",
        authorization_endpoint: "https://screenote.test/oauth/authorize",
        token_endpoint: "https://screenote.test/oauth/token",
        registration_endpoint: "https://screenote.test/oauth/register",
        revocation_endpoint: "https://screenote.test/oauth/revoke",
        mcp_resource: "https://screenote.test/mcp"
      )
    end

    def revoke(token:, client_id:, metadata:)
      raise Hive::Error, "already revoked" if @fail_revoke

      @revoked << [ token, client_id, metadata.revocation_endpoint ]
      true
    end
  end

  def store_in(dir)
    Hive::Screenote::CredentialStore.new(path: File.join(dir, "screenote.json"))
  end

  def test_disconnect_without_credential_is_idempotent
    with_tmp_dir do |dir|
      output = StringIO.new

      Hive::Commands::Disconnect.new("screenote", output: output, credential_store: store_in(dir)).call

      assert_equal "Screenote is not connected.\n", output.string
    end
  end

  def test_disconnect_without_credential_emits_json
    with_tmp_dir do |dir|
      output = StringIO.new

      Hive::Commands::Disconnect.new("screenote", json: true, output: output, credential_store: store_in(dir)).call

      assert_equal({ "ok" => true, "service" => "screenote", "disconnected" => false,
                     "reason" => "not_connected" }, JSON.parse(output.string))
    end
  end

  def test_disconnect_revokes_then_clears_and_emits_json
    with_tmp_dir do |dir|
      store = store_in(dir)
      store.save("access_token" => "access-123", "client_id" => "client-123", "base_url" => "https://screenote.test")
      oauth = FakeOAuth.new
      output = StringIO.new

      Hive::Commands::Disconnect.new(
        "screenote",
        json: true,
        output: output,
        credential_store: store,
        oauth_client_factory: ->(url) { assert_equal "https://screenote.test", url; oauth }
      ).call

      assert_equal [ [ "access-123", "client-123", "https://screenote.test/oauth/revoke" ] ], oauth.revoked
      refute store.present?
      payload = JSON.parse(output.string)
      assert_equal true, payload["disconnected"]
      assert_equal true, payload["revoked"]
      assert_equal store.path, payload["credential_path"]
    end
  end

  def test_disconnect_clears_when_revoke_fails_or_token_is_absent
    with_tmp_global_config do |home|
      store = store_in(home)
      store.save("access_token" => "access-123", "client_id" => "client-123")
      output = StringIO.new
      oauth = FakeOAuth.new(fail_revoke: true)

      _out, err = capture_io do
        Hive::Commands::Disconnect.new(
          "screenote",
          json: true,
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth }
        ).call
      end

      assert_match(/revoke failed/, err)
      assert_equal false, JSON.parse(output.string)["revoked"]
      refute store.present?

      store.save("client_id" => "client-123")
      output = StringIO.new
      Hive::Commands::Disconnect.new("screenote", output: output, credential_store: store).call
      assert_equal "Disconnected Screenote.\n", output.string
      refute store.present?
    end
  end

  def test_disconnect_rejects_unknown_service
    err = assert_raises(Hive::Error) { Hive::Commands::Disconnect.new("github", output: StringIO.new).call }

    assert_match(/unsupported disconnect service/, err.message)
  end
end
