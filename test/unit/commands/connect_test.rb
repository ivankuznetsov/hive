require "test_helper"
require "net/http"
require "hive/commands/connect"

class ConnectCommandTest < Minitest::Test
  include HiveTestHelper

  FakeMetadata = Hive::Screenote::OAuthClient::Discovery

  class FakeOAuth
    attr_reader :registered_redirects, :exchanged_codes, :authorize_calls, :revoked_tokens

    def initialize(token:, client_id: "client-new")
      @token = token
      @client_id = client_id
      @registered_redirects = []
      @exchanged_codes = []
      @authorize_calls = []
      @revoked_tokens = []
    end

    def revoke(token:, client_id:, metadata:)
      @revoked_tokens << { token: token, client_id: client_id, issuer: metadata.issuer }
      true
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

      lines = output.string.each_line.map { |line| JSON.parse(line) }
      authorize, payload = lines
      assert_equal "authorize", authorize["stage"]
      assert_match(%r{https://screenote\.test/oauth/authorize}, authorize["authorize_url"])
      assert_equal false, authorize["browser_opened"]
      assert_equal true, payload["ok"]
      assert_equal "client-existing", payload["client_id"]
      assert_equal "proj_2", payload["project_id"]
      assert_equal "https://screenote.test", payload["issuer"]
      assert_equal "https://screenote.test", payload["base_url"]
      refute payload.key?("connected")
      refute payload.key?("expires_at")
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
          mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_fallback", "name" => "" } ]) },
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
        mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_fallback", "name" => "" } ]) },
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

  def test_best_effort_revoke_warns_when_revocation_raises
    cmd = Hive::Commands::Connect.new("screenote", output: StringIO.new)
    oauth = Object.new
    oauth.define_singleton_method(:revoke) { |**| raise StandardError, "revoke boom" }

    _out, err = capture_io do
      cmd.send(:best_effort_revoke, oauth, nil, { "access_token" => "tok-1" }, "client-1")
    end

    assert_match(/could not revoke the abandoned Screenote token/, err)
  end

  def test_json_error_envelope_swallows_a_broken_pipe
    # A closed stdout (EPIPE) while writing the failure envelope must not
    # mask the original error with a secondary crash.
    output = Object.new
    output.define_singleton_method(:puts) { |*| raise Errno::EPIPE }
    cmd = Hive::Commands::Connect.new("github", json: true, output: output)

    err = assert_raises(Hive::Error) { cmd.call }
    assert_match(/unsupported connect service/, err.message)
  end

  def test_connect_revokes_token_when_a_post_exchange_step_fails
    # After exchange mints a live bearer, a failure before `save` (here an
    # empty project list) must best-effort revoke it so the next connect does
    # not re-register and burn the DCR limit, and the grant does not linger.
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
          browser_opener: ->(_url) { false }
        ).call
      end

      assert_match(/returned no projects/, err.message)
      assert_equal [ "access-123" ], oauth.revoked_tokens.map { |entry| entry[:token] }
      refute store.present?
    end
  end

  def test_connect_maps_oslevel_save_failure_to_typed_error_and_revokes
    with_tmp_dir do |dir|
      oauth = FakeOAuth.new(token: token_payload)
      path = File.join(dir, "screenote.json")
      failing_store = Object.new
      failing_store.define_singleton_method(:load) { nil }
      failing_store.define_singleton_method(:present?) { false }
      failing_store.define_singleton_method(:path) { path }
      failing_store.define_singleton_method(:save) { |_cred| raise Errno::EACCES, "screenote.json" }

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          output: StringIO.new,
          credential_store: failing_store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_1", "name" => "One" } ]) },
          browser_opener: ->(_url) { false },
          project_picker: ->(projects) { projects.first }
        ).call
      end

      assert_match(/could not write Screenote credential/, err.message)
      assert_match(/screenote\.json/, err.message)
      assert_equal [ "access-123" ], oauth.revoked_tokens.map { |entry| entry[:token] }
    end
  end

  def test_connect_json_failure_emits_error_envelope
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          json: true,
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([]) },
          browser_opener: ->(_url) { false }
        ).call
      end

      assert_match(/returned no projects/, err.message)
      lines = output.string.each_line.map { |line| JSON.parse(line) }
      envelope = lines.last
      assert_equal false, envelope["ok"]
      assert_equal "screenote", envelope["service"]
      assert_equal "error", envelope["error_kind"]
      assert_match(/returned no projects/, envelope["message"])
      assert_equal [ "access-123" ], oauth.revoked_tokens.map { |entry| entry[:token] }
    end
  end

  def test_connect_json_auto_selects_a_lone_project_without_prompting
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new

      Hive::Commands::Connect.new(
        "screenote",
        base_url: "https://screenote.test",
        json: true,
        output: output,
        credential_store: store,
        oauth_client_factory: ->(_url) { oauth },
        loopback_factory: -> { FakeLoopback.new },
        mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_only", "name" => "Only" } ]) },
        browser_opener: ->(_url) { false }
      ).call

      assert_equal "proj_only", store.load["project_id"]
      # Every stdout line must be valid JSON — no human "Select a project"
      # prose leaked onto the --json stream.
      output.string.each_line { |line| JSON.parse(line) }
    end
  end

  def test_connect_json_emits_needs_project_selection_for_multiple_projects
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          json: true,
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) {
            FakeMcp.new([ { "id" => "proj_one", "name" => "One" }, { "id" => "proj_two", "name" => "Two" } ])
          },
          browser_opener: ->(_url) { false }
        ).call
      end

      assert_match(/multiple projects/, err.message)
      lines = output.string.each_line.map { |line| JSON.parse(line) }
      needs = lines.find { |line| line["stage"] == "needs_project_selection" }
      refute_nil needs, "expected a needs_project_selection envelope under --json"
      assert_equal false, needs["ok"]
      assert_equal %w[proj_one proj_two], needs["projects"].map { |project| project["id"] }
      refute store.present?
      assert_equal [ "access-123" ], oauth.revoked_tokens.map { |entry| entry[:token] }
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

  def test_default_mcp_client_factory_lists_projects_through_call
    # Exercise the DEFAULT mcp_client_factory end-to-end (no factory
    # injected) with an http seam, instead of reaching into the private
    # @mcp_client_factory ivar.
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new
      response = http_ok(JSON.generate("result" => { "projects" => [ { "id" => "proj_http", "name" => "HTTP Project" } ] }))
      conn = Object.new
      conn.define_singleton_method(:request) { |_req| response }

      with_replaced_singleton_method(Net::HTTP, :start, ->(_host, _port, **_opts, &blk) { blk.call(conn) }) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          browser_opener: ->(_url) { false },
          project_picker: ->(projects) { projects.first }
        ).call
      end

      assert_equal "proj_http", store.load["project_id"]
    end
  end

  def test_prompt_rejects_zero_and_out_of_range_numbers
    [ "0\n", "2\n", "-1\n" ].each do |answer|
      with_tmp_global_config do |home|
        store = store_in(home)
        oauth = FakeOAuth.new(token: token_payload)
        err = assert_raises(Hive::Error) do
          Hive::Commands::Connect.new(
            "screenote",
            output: StringIO.new,
            input: StringIO.new(answer),
            credential_store: store,
            oauth_client_factory: ->(_url) { oauth },
            loopback_factory: -> { FakeLoopback.new },
            mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_only", "name" => "Only" } ]) },
            browser_opener: ->(_url) { false }
          ).call
        end
        assert_match(/selection is required/, err.message, "input #{answer.inspect} must not select a project")
        refute store.present?
      end
    end
  end

  def test_prompt_accepts_a_literal_project_id_string
    with_tmp_global_config do |home|
      store = store_in(home)
      oauth = FakeOAuth.new(token: token_payload)

      Hive::Commands::Connect.new(
        "screenote",
        output: StringIO.new,
        input: StringIO.new("proj_two\n"),
        credential_store: store,
        oauth_client_factory: ->(_url) { oauth },
        loopback_factory: -> { FakeLoopback.new },
        mcp_client_factory: ->(**) {
          FakeMcp.new([ { "id" => "proj_one", "name" => "One" }, { "id" => "proj_two", "name" => "Two" } ])
        },
        browser_opener: ->(_url) { false }
      ).call

      assert_equal "proj_two", store.load["project_id"]
    end
  end

  def test_prompt_rejects_a_nonmatching_id_string
    with_tmp_global_config do |home|
      store = store_in(home)
      oauth = FakeOAuth.new(token: token_payload)

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          output: StringIO.new,
          input: StringIO.new("nope\n"),
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_one", "name" => "One" } ]) },
          browser_opener: ->(_url) { false }
        ).call
      end

      assert_match(/selection is required/, err.message)
      refute store.present?
    end
  end

  def test_credential_payload_raises_typed_error_when_expiry_is_absent
    with_tmp_dir do |dir|
      store = store_in(dir)
      # Token response with neither expires_at nor expires_in.
      oauth = FakeOAuth.new(token: { "access_token" => "access-123", "token_type" => "Bearer" })

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          output: StringIO.new,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_1", "name" => "One" } ]) },
          browser_opener: ->(_url) { false },
          project_picker: ->(projects) { projects.first }
        ).call
      end

      assert_match(/omitted both expires_at and expires_in/, err.message)
      refute store.present?
      # credential_payload raised INSIDE the revoke-protected region, so the
      # freshly-minted bearer must be best-effort revoked, not abandoned live.
      assert_equal [ "access-123" ], oauth.revoked_tokens.map { |entry| entry[:token] }
    end
  end

  def test_connect_recovers_from_a_corrupt_existing_credential
    with_tmp_dir do |dir|
      store = store_in(dir)
      File.write(store.path, "{ not json")
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new

      _out, err = capture_io do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_1", "name" => "One" } ]) },
          browser_opener: ->(_url) { false },
          project_picker: ->(projects) { projects.first }
        ).call
      end

      assert_match(/ignoring unreadable screenote credential/, err)
      # A corrupt file did not register a client_id, so registration runs.
      refute_empty oauth.registered_redirects
      assert_equal "access-123", store.load["access_token"]
    end
  end

  # Succeeds on the first `puts` (the authorize line) then raises Errno::EPIPE
  # on every later one — mimicking `hive connect screenote --json | head -1`
  # closing the pipe after the authorize line.
  class PipeBreaksAfterFirstLine
    attr_reader :string

    def initialize
      @count = 0
      @string = +""
    end

    def puts(*args)
      @count += 1
      raise Errno::EPIPE, "Broken pipe" if @count > 1

      @string << "#{args.join(" ")}\n"
    end
  end

  def test_connect_does_not_revoke_a_saved_credential_when_the_success_line_pipe_breaks
    # Regression: emit_success used to run inside the revoke-scoped region, so
    # a closed stdout pipe (Errno::EPIPE from its puts) AFTER save revoked the
    # persisted bearer, leaving screenote.json advertising a server-revoked
    # token. The credential must stay connected and the bearer must NOT be
    # revoked.
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      output = PipeBreaksAfterFirstLine.new

      Hive::Commands::Connect.new(
        "screenote",
        base_url: "https://screenote.test",
        json: true,
        output: output,
        credential_store: store,
        oauth_client_factory: ->(_url) { oauth },
        loopback_factory: -> { FakeLoopback.new },
        mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_only", "name" => "Only" } ]) },
        browser_opener: ->(_url) { false }
      ).call

      assert_equal "access-123", store.load["access_token"]
      assert_empty oauth.revoked_tokens
    end
  end

  def test_connect_maps_a_nonsave_oslevel_failure_to_a_typed_error_envelope
    # A SystemCallError raised OUTSIDE the save path (here ENOSPC during
    # discovery) is not a Hive::Error, so it would escape bin/hive as a raw
    # backtrace; `call` maps it to a typed error and still emits an envelope.
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = Object.new
      oauth.define_singleton_method(:discover) { raise Errno::ENOSPC, "no space left" }
      output = StringIO.new

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          json: true,
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          browser_opener: ->(_url) { false }
        ).call
      end

      assert_match(/Screenote connect failed/, err.message)
      assert_match(/no space left/, err.message)
      envelope = JSON.parse(output.string.each_line.to_a.last)
      assert_equal false, envelope["ok"]
      assert_match(/Screenote connect failed/, envelope["message"])
    end
  end

  def test_connect_json_needs_project_selection_carries_kind_exit_and_emits_one_failure
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload)
      output = StringIO.new

      assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          json: true,
          output: output,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) {
            FakeMcp.new([ { "id" => "proj_one", "name" => "One" }, { "id" => "proj_two", "name" => "Two" } ])
          },
          browser_opener: ->(_url) { false }
        ).call
      end

      lines = output.string.each_line.map { |line| JSON.parse(line) }
      failures = lines.select { |line| line["ok"] == false }
      # The @error_emitted guard must suppress a duplicate envelope from
      # call's rescue: exactly one ok:false line.
      assert_equal 1, failures.length
      needs = failures.first
      assert_equal "needs_project_selection", needs["stage"]
      assert_equal "needs_selection", needs["error_kind"]
      assert_equal Hive::ExitCodes::GENERIC, needs["exit_code"]
    end
  end

  def test_connect_normalizes_an_epoch_expires_at_to_iso8601
    with_tmp_dir do |dir|
      store = store_in(dir)
      # A server that returns expires_at as a Unix-epoch integer (a common
      # OAuth shape) must be coerced to ISO8601 — storing the epoch verbatim
      # made expired? read a fresh token as already-expired.
      epoch = Time.utc(2027, 1, 1, 0, 0, 0).to_i
      oauth = FakeOAuth.new(token: token_payload("expires_at" => epoch))

      Hive::Commands::Connect.new(
        "screenote",
        base_url: "https://screenote.test",
        output: StringIO.new,
        credential_store: store,
        oauth_client_factory: ->(_url) { oauth },
        loopback_factory: -> { FakeLoopback.new },
        mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_1", "name" => "One" } ]) },
        browser_opener: ->(_url) { false },
        project_picker: ->(projects) { projects.first }
      ).call

      assert_equal "2027-01-01T00:00:00Z", store.load["expires_at"]
      refute store.expired?(now: Time.utc(2026, 1, 1, 0, 0, 0)),
             "a normalized epoch expiry must parse, not read as already-expired"
    end
  end

  def test_connect_raises_typed_error_on_an_unparseable_expires_at
    with_tmp_dir do |dir|
      store = store_in(dir)
      oauth = FakeOAuth.new(token: token_payload("expires_at" => "not-a-timestamp"))

      err = assert_raises(Hive::Error) do
        Hive::Commands::Connect.new(
          "screenote",
          base_url: "https://screenote.test",
          output: StringIO.new,
          credential_store: store,
          oauth_client_factory: ->(_url) { oauth },
          loopback_factory: -> { FakeLoopback.new },
          mcp_client_factory: ->(**) { FakeMcp.new([ { "id" => "proj_1", "name" => "One" } ]) },
          browser_opener: ->(_url) { false },
          project_picker: ->(projects) { projects.first }
        ).call
      end

      assert_match(/unparseable expires_at/, err.message)
      refute store.present?
      # Raised inside the revoke-protected region → bearer revoked, not left live.
      assert_equal [ "access-123" ], oauth.revoked_tokens.map { |entry| entry[:token] }
    end
  end

  def http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end
end
