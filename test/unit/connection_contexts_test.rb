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

  private

  def add_remote
    @store.add("nas", url: "https://nas.example", token: "secret-bearer")
  end
end
