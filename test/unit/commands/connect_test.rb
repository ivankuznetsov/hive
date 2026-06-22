require "test_helper"
require "hive/commands/connect"

class ConnectCommandTest < Minitest::Test
  include HiveTestHelper

  FakeMetadata = Hive::Screenote::OAuthClient::Discovery

  class FakeOAuth
    attr_reader :registered_redirects, :exchanged_codes, :authorize_calls

    def initialize(token:, client_id: "client-new")
      @token = token
      @client_id = client_id
      @registered_redirects = []
      @exchanged_codes = []
      @authorize_calls = []
    end

    def discover
      FakeMetadata.new(
        issuer: "https://screenote.test",
        authorization_endpoint: "https://screenote.test/oauth/authorize",
        token_endpoint: "https://screenote.test/oauth/token",
        registration_endpoint: "https://screenote.test/oauth/register",
        revocation_endpoint: "https://screenote.test/oauth/revoke",
        mcp_resource: "https://screenote.test/mcp"
      )
    end

    def register(redirect_uri, metadata:)
      @registered_redirects << [ redirect_uri, metadata.issuer ]
      { "client_id" => @client_id }
    end

    def authorize_url(**kwargs)
      @authorize_calls << kwargs
      "https://screenote.test/oauth/authorize?state=#{kwargs.fetch(:state)}"
    end

    def exchange_code(code:, verifier:, redirect_uri:, client_id:, metadata:)
      @exchanged_codes << { code: code, verifier: verifier, redirect_uri: redirect_uri,
                            client_id: client_id, issuer: metadata.issuer }
      @token
    end
  end

  class FakeLoopback
    attr_reader :expected_states

    def initialize(code: "code-123")
      @code = code
      @expected_states = []
    end

    def redirect_uri = "http://127.0.0.1:4321/callback"

    def wait_for_callback(expected_state:)
      @expected_states << expected_state
      { "code" => @code, "state" => expected_state }
    end
  end

  class FakeMcp
    def initialize(projects)
      @projects = projects
    end

    def list_projects = @projects
  end

  def token_payload(extra = {})
    {
      "access_token" => "access-123",
      "expires_in" => 3600,
      "token_type" => "Bearer",
      "scope" => "mcp_read mcp_write"
    }.merge(extra)
  end

  def store_in(dir)
    Hive::Screenote::CredentialStore.new(path: File.join(dir, "screenote.json"))
  end

  def test_connect_happy_path_registers_opens_authorizes_selects_project_and_persists
    with_tmp_dir do |dir|
      oauth = FakeOAuth.new(token: token_payload("refresh_token" => "refresh-123"))
      loopback = FakeLoopback.new
      output = StringIO.new
      opened = []
      store = store_in(dir)

      Hive::Commands::Connect.new(
        "screenote",
        base_url: "https://screenote.test",
        output: output,
        credential_store: store,
        oauth_client_factory: ->(url) { assert_equal "https://screenote.test", url; oauth },
        loopback_factory: -> { loopback },
        mcp_client_factory: ->(resource:, access_token:) {
          assert_equal "https://screenote.test/mcp", resource
          assert_equal "access-123", access_token
          FakeMcp.new([ { "id" => "proj_1", "name" => "Project One" } ])
        },
        browser_opener: ->(url) { opened << url; true },
        project_picker: ->(projects) { projects.first.fetch("id") },
        clock: -> { Time.utc(2026, 6, 22, 12, 0, 0) }
      ).call

      credential = store.load
      assert_equal "access-123", credential["access_token"]
      assert_equal "2026-06-22T13:00:00Z", credential["expires_at"]
      assert_equal "client-new", credential["client_id"]
      assert_equal "proj_1", credential["project_id"]
      assert_equal "refresh-123", credential["refresh_token"]
      assert_equal "https://screenote.test/mcp", credential["mcp_resource"]
      assert_equal [ [ "http://127.0.0.1:4321/callback", "https://screenote.test" ] ], oauth.registered_redirects
      assert_equal "code-123", oauth.exchanged_codes.first.fetch(:code)
      assert_equal oauth.authorize_calls.first.fetch(:state), loopback.expected_states.first
      assert_match(%r{https://screenote\.test/oauth/authorize}, opened.first)
      assert_includes output.string, "Connected Screenote project Project One (proj_1)."
    end
  end

  def test_connect_reuses_existing_client_id_and_emits_json
    with_tmp_dir do |dir|
      store = store_in(dir)
      store.save("client_id" => "client-existing")
      oauth = FakeOAuth.new(token: token_payload("expires_at" => "2027-01-01T00:00:00Z"))
      output = StringIO.new

      Hive::Commands::Connect.new(
        "screenote",
        base_url: "https://screenote.test",
        json: true,
        output: output,
        credential_store: store,
        oauth_client_factory: ->(_url) { oauth },
        loopback_factory: -> { FakeLoopback.new },
        mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_2", "name" => "Project Two" } ]) },
        browser_opener: ->(_url) { false },
        project_picker: ->(projects) { projects.first }
      ).call

      payload = JSON.parse(output.string)
      assert_equal true, payload["ok"]
      assert_equal "client-existing", payload["client_id"]
      assert_equal "proj_2", payload["project_id"]
      assert_empty oauth.registered_redirects
      assert_equal "client-existing", store.load["client_id"]
      assert_equal "2027-01-01T00:00:00Z", store.load["expires_at"]
    end
  end

  def test_connect_prompts_and_requires_an_explicit_project_selection
    with_tmp_global_config do |home|
      store = store_in(home)
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          output: output,
          input: StringIO.new("\n"),
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([ { "project_id" => "proj_fallback", "name" => "" } ]) },
          browser_opener: ->(_url) { false }
        ).call
      end

      assert_match(/selection is required/, err.message)
      refute store.present?
      assert_includes output.string, "1. Unnamed project (proj_fallback)"

      Hive::Commands::Connect.new(
        "screenote",
        output: output,
        input: StringIO.new("1\n"),
        credential_store: store,
        oauth_client_factory: ->(_url) { oauth },
        loopback_factory: -> { FakeLoopback.new },
        mcp_client_factory: ->(**) { FakeMcp.new([ { "project_id" => "proj_fallback", "name" => "" } ]) },
        browser_opener: ->(_url) { false }
      ).call
      assert_equal "proj_fallback", store.load["project_id"]
      assert_equal "https://screenote.ai", store.load["base_url"]
    end
  end

  def test_connect_rejects_empty_project_list_and_unknown_service
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          output: StringIO.new,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([]) },
          browser_opener: ->(_url) { false },
          project_picker: ->(projects) { projects.first }
        ).call
      end
      assert_match(/returned no projects/, err.message)
      refute store.present?

      err = assert_raises(Hive::Error) { Hive::Commands::Connect.new("github", output: StringIO.new).call }
      assert_match(/unsupported connect service/, err.message)
    end
  end

  def test_open_browser_honors_browser_env_and_falls_back_to_xdg_open
    calls = []
    with_replaced_singleton_method(Hive::Commands::Connect, :system, lambda { |*args, **kwargs|
      calls << [ args, kwargs ]
      true
    }) do
      with_env("BROWSER" => "browser-bin") do
        assert Hive::Commands::Connect.open_browser("https://screenote.test")
      end
      with_env("BROWSER" => nil) do
        assert Hive::Commands::Connect.open_browser("https://screenote.test")
      end
    end

    assert_equal [ "browser-bin", "https://screenote.test" ], calls.first.first
    assert_equal [ "xdg-open", "https://screenote.test" ], calls.last.first
    assert_equal({ out: File::NULL, err: File::NULL }, calls.first.last)
  end
end
