require "test_helper"
require "hive/connection_contexts"
require "json"
require "hive/commands/context"
require "json_schemer"
require "hive/remote/client"

class ConnectionContextsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hive-contexts")
    @calls = []
    @verifier = lambda do |context, token|
      @calls << [ context["url"], token ]
      { "instance_id" => "server-1", "api_version" => "v1",
        "token" => { "id" => "public-1", "scopes" => [ "read" ],
                     "projects" => [ "server-project" ], "all_projects" => false,
                     "expires_at" => nil } }
    end
    @store = Hive::ConnectionContexts.new(root: @root, verifier: @verifier)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_default_local_add_verify_select_and_override
    assert_equal "local", @store.resolve.fetch("name")
    add_remote
    assert_equal "local", @store.resolve.fetch("name")
    assert_equal "server-1", @store.use("nas").fetch("instance_id")
    assert_equal "nas", @store.resolve.fetch("name")
    assert_equal "local", @store.resolve(name: "local").fetch("name")
    assert_equal [ "read" ], @store.show.dig("authority", "scopes")
    assert_equal [ "local", "nas" ], @store.list.map { |row| row.fetch("name") }
    refute_includes JSON.generate(@store.list), "secret-bearer"
    refute_includes JSON.generate(@store.show), "secret-bearer"
    assert_equal "secret-bearer", @store.credential(@store.resolve)
  end

  def test_invalid_urls_are_rejected_before_reading_credentials
    [ "http://nas", "https://name:password@nas", "https://nas/?token=oops",
      "https://nas/#fragment", "/tmp/server" ].each do |url|
      error = assert_raises(Hive::UsageError) do
        @store.add("nas", url: url, token_reader: -> { flunk "credentials read for invalid URL" })
      end
      refute_includes error.message, "password"
    end
    assert_empty @calls
  end

  def test_failed_verification_and_installation_change_do_not_change_selection
    add_remote
    failing = Hive::ConnectionContexts.new(root: @root, verifier: ->(*) { raise Hive::ConfigError, "unavailable" })
    assert_raises(Hive::ConfigError) { failing.use("nas") }
    assert_equal "local", @store.resolve.fetch("name")
    changed = Hive::ConnectionContexts.new(root: @root, verifier: ->(*) { { "instance_id" => "other", "api_version" => "v1" } })
    assert_raises(Hive::ConfigError) { changed.use("nas") }
    assert_equal "local", @store.resolve.fetch("name")
  end

  def test_verifier_failures_never_disclose_the_bearer
    failing = Hive::ConnectionContexts.new(
      root: @root, verifier: ->(_context, bearer) { raise Hive::ConfigError, "Authorization: Bearer #{bearer}" }
    )
    error = assert_raises(Hive::ConfigError) do
      failing.add("nas", url: "https://nas.example", token: "secret-bearer")
    end
    refute_includes error.message, "secret-bearer"
    assert_equal "local", @store.resolve.fetch("name")
  end

  def test_only_safe_typed_version_guidance_survives_verifier_failure
    store = Hive::ConnectionContexts.new(root: @root,
      verifier: ->(*) { raise Hive::Remote::Client::UnsupportedVersion.new([ "/api/v2", "/secret-bearer" ]) })
    error = assert_raises(Hive::Remote::Client::UnsupportedVersion) do
      store.add("nas", url: "https://nas.example", token: "secret-bearer")
    end
    assert_includes error.message, "/api/v2"
    refute_includes error.message, "secret-bearer"
    assert_equal "local", store.resolve.fetch("name")
  end

  def test_files_are_versioned_atomic_and_private
    add_remote
    assert_equal 0o700, File.stat(@root).mode & 0o777
    [ @store.contexts_path, @store.credentials_path ].each do |path|
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 1, JSON.parse(File.read(path)).fetch("schema_version")
    end
    refute_includes File.read(@store.contexts_path), "secret-bearer"
    @store.use("nas")
    assert_equal 0o600, File.stat(@store.contexts_path).mode & 0o777
  end

  def test_future_versions_and_corruption_fail_without_local_fallback
    add_remote
    [ @store.contexts_path, @store.credentials_path ].each do |path|
      original = File.read(path)
      data = JSON.parse(original).merge("schema_version" => 2)
      File.write(path, JSON.generate(data))
      error = assert_raises(Hive::ConfigError) { @store.resolve }
      assert_match(/upgrade/i, error.message)
      File.write(path, original)
    end
    File.write(@store.contexts_path, "not json")
    assert_raises(Hive::ConfigError) { @store.resolve }
  end

  def test_concurrent_writes_preserve_every_context_and_credential
    threads = 8.times.map do |index|
      Thread.new { @store.add("host-#{index}", url: "https://host-#{index}.example", token: "token-#{index}") }
    end
    threads.each(&:value)
    assert_equal 9, @store.list.length
    8.times do |index|
      context = @store.resolve(name: "host-#{index}")
      assert_equal "token-#{index}", @store.credential(context)
    end
  end

  def test_command_success_and_usage_errors_follow_the_published_schema
    add_remote
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-context"))))
    %w[list show].each do |action|
      output = StringIO.new
      Hive::Commands::Context.new(action, json: true, contexts: @store, stdout: output).call
      assert_empty schema.validate(JSON.parse(output.string)).to_a
      refute_includes output.string, "secret-bearer"
    end
    output = StringIO.new
    assert_raises(Hive::UsageError) do
      Hive::Commands::Context.new("use", json: true, contexts: @store, stdout: output).call
    end
    assert_empty schema.validate(JSON.parse(output.string)).to_a
    error = Hive::UsageError.new("missing name")
    contract = Hive::CliUsageContracts.contract(%w[--context local context use --json])
    assert_equal "hive-context", contract.fetch(:schema)
    assert_empty schema.validate(Hive::CliUsageContracts.error_payload(contract, error)).to_a
  end

  def test_human_command_output_exposes_verified_authority_and_never_the_bearer
    output = StringIO.new
    created = Hive::Commands::Context.new(
      "add", "nas", url: "https://nas.example/", token_stdin: true,
      contexts: @store, stdin: StringIO.new("secret-bearer\n"), stdout: output
    ).call
    assert_equal "https://nas.example", created.dig("data", "url")
    assert_includes output.string, "nas: https://nas.example"
    assert_includes output.string, "installation: server-1"
    assert_includes output.string, "token: public-1; scopes: read"
    assert_includes output.string, "projects: server-project"
    assert_includes output.string, "expires: never"
    refute_includes output.string, "secret-bearer"
    assert_equal [ "https://nas.example", "secret-bearer" ], @calls.last

    output.truncate(0)
    output.rewind
    Hive::Commands::Context.new("use", "nas", contexts: @store, stdout: output).call
    assert_equal "nas", @store.resolve.fetch("name")
    output.truncate(0)
    output.rewind
    Hive::Commands::Context.new("list", contexts: @store, stdout: output).call
    assert_includes output.string, "nas *: https://nas.example"
    assert_includes output.string, "local: local installation"
    assert_includes output.string, "authority: unrestricted local operator"
    refute_includes output.string, "secret-bearer"
  end

  def test_human_show_refreshes_all_project_grant_and_expiry_without_selecting_it
    add_remote
    all_projects = Hive::ConnectionContexts.new(root: @root, verifier: lambda do |context, token|
      metadata = @verifier.call(context, token)
      metadata.fetch("token").merge!("all_projects" => true, "projects" => [], "expires_at" => "2030-01-01T00:00:00Z")
      metadata
    end)
    output = StringIO.new
    Hive::Commands::Context.new("show", "nas", contexts: all_projects, stdout: output).call
    assert_includes output.string, "projects: all projects"
    assert_includes output.string, "expires: 2030-01-01T00:00:00Z"
    assert_equal "local", @store.resolve.fetch("name")
    assert_equal 2, @calls.length
  end

  def test_command_invalid_options_are_usage_errors_without_consuming_credentials
    cases = [
      [ "unknown", nil, {} ], [ "list", "nas", {} ],
      [ "show", nil, { url: "https://nas.example" } ],
      [ "use", "nas", { token_stdin: true } ],
      [ "add", "nas", { url: "https://nas.example" } ],
      [ "add", "nas", { token_stdin: true } ], [ "add", nil, {} ]
    ]
    cases.each do |action, name, options|
      input = StringIO.new("untouched-bearer")
      output = StringIO.new
      assert_raises(Hive::UsageError) do
        Hive::Commands::Context.new(action, name, **options, json: true, contexts: @store,
                                   stdin: input, stdout: output).call
      end
      assert_equal "usage", JSON.parse(output.string).fetch("error_kind")
      assert_equal 0, input.pos
      refute_includes output.string, "untouched-bearer"
    end
    assert_empty @calls
    refute_path_exists @store.contexts_path
  end

  def test_json_error_reporting_preserves_domain_failure_when_output_pipe_is_closed
    reader, writer = IO.pipe
    reader.close
    error = assert_raises(Hive::UsageError) do
      Hive::Commands::Context.new("unknown", json: true, contexts: @store, stdout: writer).call
    end
    assert_match(/expected context/, error.message)
    refute_path_exists @store.contexts_path
  ensure
    writer&.close
  end

  def test_command_reports_configuration_and_unexpected_storage_failures_with_typed_errors
    add_remote
    File.write(@store.contexts_path, "not json")
    output = StringIO.new
    assert_raises(Hive::ConfigError) do
      Hive::Commands::Context.new("show", json: true, contexts: @store, stdout: output).call
    end
    assert_equal "config", JSON.parse(output.string).fetch("error_kind")

    unavailable = Hive::ConnectionContexts.new(root: File.join(@store.contexts_path, "child"), verifier: @verifier)
    output = StringIO.new
    assert_raises(Hive::InternalError) do
      Hive::Commands::Context.new("add", "nas", url: "https://nas.example", token_stdin: true,
                                 json: true, contexts: unavailable, stdin: StringIO.new("secret-bearer"), stdout: output).call
    end
    assert_equal "internal", JSON.parse(output.string).fetch("error_kind")
    refute_includes output.string, "secret-bearer"
  end

  def test_invalid_names_and_credentials_are_rejected_before_verification_or_persistence
    [ "local", "", "../nas", "name with spaces", "x" * 65 ].each do |name|
      assert_raises(Hive::UsageError) { @store.add(name, url: "https://nas.example", token: "secret-bearer") }
    end
    [ "", " \n", "two tokens", "x" * 4097 ].each do |token|
      assert_raises(Hive::UsageError) { @store.add("nas", url: "https://nas.example", token: token) }
    end
    assert_empty @calls
    refute_path_exists @store.contexts_path
    assert_raises(Hive::UsageError) { @store.use("missing") }
    assert_raises(Hive::UsageError) { @store.show("missing") }
  end

  def test_replacing_context_removes_old_credentials_without_retargeting_a_frozen_invocation
    add_remote
    previous = @store.resolve(name: "nas")
    @store.add("nas", url: "https://new-nas.example", token: "replacement-bearer")
    error = assert_raises(Hive::ConfigError) { @store.credential(previous) }
    assert_match(/missing credentials/, error.message)
    assert_equal "replacement-bearer", @store.credential(@store.resolve(name: "nas"))
    credentials = JSON.parse(File.read(@store.credentials_path)).fetch("credentials")
    assert_equal [ "replacement-bearer" ], credentials.values
    refute_includes File.read(@store.credentials_path), "secret-bearer"
  end

  def test_context_replacement_during_metadata_verification_cannot_change_selection
    add_remote
    racing = Hive::ConnectionContexts.new(root: @root, verifier: lambda do |context, token|
      @store.add("nas", url: "https://replacement.example", token: "replacement-bearer")
      @verifier.call(context, token)
    end)
    error = assert_raises(Hive::ConfigError) { racing.use("nas") }
    assert_match(/context changed while being verified/, error.message)
    assert_equal "local", @store.resolve.fetch("name")
    assert_equal "https://replacement.example", @store.resolve(name: "nas").fetch("url")
  end

  def test_incompatible_and_malformed_metadata_never_pin_a_context
    [ { "instance_id" => "server", "api_version" => "v2" },
      { "instance_id" => "", "api_version" => "v1" },
      { "instance_id" => "server" }, nil ].each do |metadata|
      store = Hive::ConnectionContexts.new(root: @root, verifier: ->(*) { metadata })
      error = assert_raises(Hive::ConfigError) { store.add("nas", url: "https://nas.example", token: "secret-bearer") }
      refute_includes error.message, "secret-bearer"
      assert_equal "local", @store.resolve.fetch("name")
      refute_path_exists @store.contexts_path
    end
  end

  def test_insecure_stored_urls_missing_credentials_and_invalid_credential_shapes_fail_closed
    add_remote
    original = JSON.parse(File.read(@store.contexts_path))
    changed = Marshal.load(Marshal.dump(original))
    changed.fetch("contexts").fetch("nas")["url"] = "http://insecure.example"
    File.write(@store.contexts_path, JSON.generate(changed))
    assert_raises(Hive::ConfigError) { @store.resolve }
    File.write(@store.contexts_path, JSON.generate(original))

    [ {}, { "unused" => 123 }, [] ].each do |credentials|
      File.write(@store.credentials_path, JSON.generate("schema_version" => 1, "credentials" => credentials))
      error = assert_raises(Hive::ConfigError) { @store.resolve }
      assert_match(/credential/, error.message)
    end
  end

  private

  def add_remote
    @store.add("nas", url: "https://nas.example", token: "secret-bearer")
  end
end
