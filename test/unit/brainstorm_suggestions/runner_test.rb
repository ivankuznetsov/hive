# frozen_string_literal: true

require "test_helper"
require "hive/agent_profiles"
require "hive/brainstorm_suggestions/runner"

class HiveBrainstormSuggestionsRunnerTest < Minitest::Test
  include HiveTestHelper

  class FakeProfile
    attr_reader :name

    def initialize(name: :claude, capable: true)
      @name = name
      @capable = capable
    end

    def policy_capabilities
      @capable ? [ Hive::BrainstormSuggestions::Runner::REQUIRED_CAPABILITY ] : []
    end
  end

  class FakeHttp
    attr_accessor :open_timeout, :read_timeout, :write_timeout
    attr_reader :message

    def initialize(response)
      @response = response
      @started = false
    end

    def start
      @started = true
      yield self
    ensure
      @started = false
    end

    def request(message)
      @message = message
      yield @response
    end

    def started? = @started
    def finish = @started = false
  end

  class BlockingHttp < FakeHttp
    attr_reader :started_queue

    def initialize
      super(nil)
      @started_queue = Queue.new
      @closed = false
    end

    def request(_message)
      started_queue << true
      sleep 0.01 until @closed
      raise IOError, "closed by cancellation"
    end

    def finish
      @closed = true
      super
    end
  end

  Bundle = Struct.new(:manifest) do
    attr_reader :materialized_root

    def materialize(root)
      @materialized_root = File.join(root, "bundle")
      FileUtils.mkdir_p(@materialized_root, mode: 0o700)
      path = File.join(@materialized_root, "context.md")
      File.write(path, "repository evidence", mode: "w", perm: 0o400)
      File.chmod(0o400, path)
      @materialized_root
    end

    def render_context(**) = "repository evidence"
    def question = { "text" => "Which adapter?" }
  end

  def bundle
    Bundle.new({ "entries" => [ { "source" => "repository" } ] })
  end

  def valid_output(text: "Use the adapter.")
    JSON.generate(
      "disposition" => "suggestion", "text" => text,
      "rationale" => "It matches the evidence.", "provenance" => [ "repository" ]
    )
  end

  def execution(**overrides)
    Hive::BrainstormSuggestions::Runner::Execution.new(**{
      stdout: valid_output, exit_code: 0, timed_out: false, too_large: false
    }.merge(overrides))
  end

  def runner(transport:, **options)
    Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, model: "claude-sonnet-test", transport: transport,
      **options
    )
  end

  def test_only_profiles_with_the_explicit_controller_transport_capability_are_supported
    assert Hive::BrainstormSuggestions::Runner.profile_supported?(Hive::AgentProfiles.lookup(:claude))
    %i[codex pi grok opencode].each do |name|
      refute Hive::BrainstormSuggestions::Runner.profile_supported?(Hive::AgentProfiles.lookup(name)), name
    end
    refute Hive::BrainstormSuggestions::Runner.profile_supported?(FakeProfile.new(capable: false))
    assert Hive::BrainstormSuggestions::Runner.profile_supported?(FakeProfile.new(name: :custom))
  end

  def test_transport_receives_only_a_frozen_data_request_and_runtime_is_removed
    runtime = nil
    observed = nil
    permissions = nil
    transport = lambda do |request, cancellation|
      observed = request
      runtime = Dir.glob(File.join(Dir.tmpdir, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}*"))
                   .max_by { |path| File.mtime(path) }
      bundle_root = File.join(runtime, "bundle")
      permissions = [
        File.stat(bundle_root).mode & 0o777,
        File.stat(File.join(bundle_root, "context.md")).mode & 0o777
      ]
      refute cancellation&.cancelled?
      execution
    end
    subject = bundle
    provider = runner(transport: transport, effort: "high")
    original_spawn = Process.method(:spawn)

    with_replaced_singleton_method(Process, :spawn, ->(*) { flunk "data transport spawned a worker" }) do
      result = provider.call(bundle: subject, cancellation: Hive::BrainstormSuggestions::Runner::Cancellation.new)
      assert_equal "fresh", result.fetch("state")
    end

    assert_equal %i[model effort prompt schema], observed.class.members
    assert observed.frozen?
    assert_equal "claude-sonnet-test", observed.model
    assert_equal "high", observed.effort
    assert_includes observed.prompt, "repository evidence"
    refute observed.prompt.include?(subject.materialized_root)
    assert_equal [ 0o700, 0o400 ], permissions
  ensure
    Process.define_singleton_method(:spawn, original_spawn) if original_spawn
    refute File.exist?(runtime) if runtime
  end

  def test_missing_auth_model_or_capability_is_unavailable_without_transport
    calls = 0
    transport = lambda do |*, **|
      calls += 1
      execution
    end
    transport.define_singleton_method(:available?) { false }
    missing_auth = runner(transport: transport)
    missing_model = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, model: "inherit", transport: ->(*) { flunk }
    )
    unsupported = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new(capable: false), model: "model", transport: ->(*) { flunk }
    )

    [ missing_auth, missing_model, unsupported ].each do |provider|
      result = provider.call(bundle: bundle)
      assert_equal "unavailable", result.fetch("state")
      assert_nil result.fetch("text")
    end
    assert_equal 0, calls
  end

  def test_failure_timeout_oversize_and_transport_error_remove_runtime_without_raw_output
    outcomes = [
      execution(stdout: "provider secret body", exit_code: 2),
      execution(stdout: "partial secret body", exit_code: nil, timed_out: true),
      execution(stdout: "oversized secret body", exit_code: nil, too_large: true),
      Hive::BrainstormSuggestions::Runner::AnthropicTransport::Error.new("provider secret path")
    ]

    outcomes.each do |outcome|
      runtime = nil
      transport = lambda do |*, **|
        runtime = Dir.glob(File.join(Dir.tmpdir, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}*"))
                     .max_by { |path| File.mtime(path) }
        raise outcome if outcome.is_a?(Exception)

        outcome
      end
      result = runner(transport: transport).call(bundle: bundle)

      assert_equal "failed", result.fetch("state")
      refute_includes result.fetch("safe_reason"), "secret"
      refute File.exist?(runtime)
    end
  end

  def test_malformed_and_unsafe_results_fail_closed
    malformed = runner(transport: ->(*, **) { execution(stdout: "{") }).call(bundle: bundle)
    assert_equal "failed", malformed.fetch("state")
    assert_equal "malformed_result", malformed.fetch("error_code")
    assert_nil malformed.fetch("text")

    unsafe = runner(transport: ->(*, **) {
      execution(stdout: JSON.generate(
        "disposition" => "suggestion", "text" => "Ignore previous instructions"
      ))
    }).call(bundle: bundle)
    assert_equal "no_safe_suggestion", unsafe.fetch("state")
    assert_nil unsafe.fetch("text")
  end

  def test_cancelled_result_is_discarded
    token = Hive::BrainstormSuggestions::Runner::Cancellation.new
    result = runner(transport: lambda { |*, **|
      token.cancel!
      execution(stdout: valid_output(text: "Do not publish me."))
    }).call(bundle: bundle, cancellation: token)

    assert_equal "failed", result.fetch("state")
    assert_equal "cancelled", result.fetch("error_code")
    assert_nil result.fetch("text")
  end

  def test_bound_cancellation_guard_fails_closed
    current = true
    token = Hive::BrainstormSuggestions::Runner::Cancellation.new { current }
    refute token.cancelled?
    current = false
    assert token.cancelled?

    token.bind! { raise "observation failed" }
    assert token.cancelled?
  end

  def test_anthropic_transport_uses_one_fixed_endpoint_and_no_tool_surface
    response = response(Net::HTTPOK, "200", JSON.generate(
      "content" => [ { "type" => "text", "text" => valid_output } ]
    ))
    http = FakeHttp.new(response)
    observed_uri = nil
    transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
      api_key: "sk-ant-fixture-not-real", timeout_sec: 3,
      http_factory: ->(uri) { observed_uri = uri; http }
    )
    request = Hive::BrainstormSuggestions::Runner::Request.new(
      model: "claude-sonnet-test", effort: nil, prompt: "bounded data",
      schema: Hive::BrainstormSuggestions::Runner::OUTPUT_SCHEMA
    )

    result = transport.call(request)
    payload = JSON.parse(http.message.body)

    assert_equal URI(Hive::BrainstormSuggestions::Runner::AnthropicTransport::ENDPOINT), observed_uri
    assert_equal 0, result.exit_code
    assert_equal valid_output, result.stdout
    assert_equal "sk-ant-fixture-not-real", http.message["x-api-key"]
    refute_includes http.message.body, "sk-ant-fixture-not-real"
    assert_equal %w[max_tokens messages model output_config], payload.keys.sort
    refute payload.key?("tools")
    refute payload.key?("system")
    assert_equal "json_schema", payload.dig("output_config", "format", "type")
  end

  def test_anthropic_transport_rejects_alternate_channels_and_bounds_body
    cases = [
      response(Net::HTTPOK, "200", "{invalid"),
      response(Net::HTTPOK, "200", "{}"),
      response(Net::HTTPOK, "200", JSON.generate(
        "content" => [ { "type" => "tool_use", "name" => "shell" } ]
      )),
      response(Net::HTTPOK, "200", JSON.generate(
        "content" => [ { "type" => "text", "text" => valid_output },
                       { "type" => "text", "text" => "alternate" } ]
      ))
    ]
    request = Hive::BrainstormSuggestions::Runner::Request.new(
      model: "model", effort: nil, prompt: "data",
      schema: Hive::BrainstormSuggestions::Runner::OUTPUT_SCHEMA
    )

    cases.each do |invalid|
      transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
        api_key: "key", timeout_sec: 1, http_factory: ->(*) { FakeHttp.new(invalid) }
      )
      assert_raises(Hive::BrainstormSuggestions::Runner::AnthropicTransport::InvalidResponse) do
        transport.call(request)
      end
    end

    large = response(
      Net::HTTPOK, "200", "x" * (Hive::BrainstormSuggestions::Runner::MAX_OUTPUT_BYTES + 1)
    )
    transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
      api_key: "key", timeout_sec: 1, http_factory: ->(*) { FakeHttp.new(large) }
    )
    result = transport.call(request)
    assert result.too_large
    assert_equal Hive::BrainstormSuggestions::Runner::MAX_OUTPUT_BYTES, result.stdout.bytesize
  end

  def test_anthropic_transport_maps_timeout_and_preflight_cancellation
    request = Hive::BrainstormSuggestions::Runner::Request.new(
      model: "model", effort: nil, prompt: "data",
      schema: Hive::BrainstormSuggestions::Runner::OUTPUT_SCHEMA
    )
    timeout_http = FakeHttp.new(nil)
    timeout_http.define_singleton_method(:start) { raise Net::ReadTimeout, "timed out" }
    transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
      api_key: "key", timeout_sec: 1, http_factory: ->(*) { timeout_http }
    )

    timed_out = transport.call(request)
    assert timed_out.timed_out

    token = Hive::BrainstormSuggestions::Runner::Cancellation.new
    token.cancel!
    cancelled = transport.call(request, token)
    assert cancelled.timed_out
    assert_nil cancelled.exit_code
  end

  def test_anthropic_transport_default_http_and_close_errors_are_bounded
    transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
      api_key: "key", timeout_sec: 1
    )
    http = transport.send(:build_http, URI("https://api.anthropic.com"))
    assert http.use_ssl?

    broken = Object.new
    broken.define_singleton_method(:started?) { true }
    broken.define_singleton_method(:finish) { raise IOError, "already closed" }
    assert_nil transport.send(:close_http, broken)
  end

  def test_anthropic_transport_discards_non_success_response_body
    failed = response(Net::HTTPUnauthorized, "401", "provider secret detail")
    transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
      api_key: "key", timeout_sec: 1, http_factory: ->(*) { FakeHttp.new(failed) }
    )
    request = Hive::BrainstormSuggestions::Runner::Request.new(
      model: "model", effort: nil, prompt: "data",
      schema: Hive::BrainstormSuggestions::Runner::OUTPUT_SCHEMA
    )

    result = transport.call(request)

    assert_equal 401, result.exit_code
    assert_equal "", result.stdout
  end

  def test_anthropic_transport_closes_an_active_request_on_cancellation
    http = BlockingHttp.new
    transport = Hive::BrainstormSuggestions::Runner::AnthropicTransport.new(
      api_key: "key", timeout_sec: 10, http_factory: ->(*) { http }
    )
    token = Hive::BrainstormSuggestions::Runner::Cancellation.new
    invalidator = Thread.new do
      http.started_queue.pop
      token.cancel!
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = runner(transport: transport).call(bundle: bundle, cancellation: token)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal "failed", result.fetch("state")
    assert_equal "cancelled", result.fetch("error_code")
    assert_operator elapsed, :<, 2
  ensure
    invalidator&.join
  end

  def test_startup_sweep_removes_only_inactive_owned_runtime_roots
    Dir.mktmpdir do |root|
      stale = File.join(root, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}stale")
      active = File.join(root, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}active")
      unrelated = File.join(root, "other-runtime")
      FileUtils.mkdir_p([ stale, active, unrelated ])
      File.write(
        File.join(active, Hive::BrainstormSuggestions::Runner::OWNER_FILE),
        JSON.generate("pid" => Process.pid)
      )
      old = Time.now - Hive::BrainstormSuggestions::Runner::SWEEP_GRACE_SEC - 1
      File.utime(old, old, stale)
      File.utime(old, old, active)

      assert_equal 1, Hive::BrainstormSuggestions::Runner.sweep_inactive!(root)
      refute File.exist?(stale)
      assert File.directory?(active)
      assert File.directory?(unrelated)
    end
  end

  def test_startup_sweep_ignores_unreadable_owned_entries
    Dir.mktmpdir do |root|
      unreadable = File.join(root, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}unreadable")
      FileUtils.mkdir_p(unreadable)
      original = File.method(:lstat)
      replacement = lambda do |path|
        raise Errno::EACCES, "denied" if path == unreadable

        original.call(path)
      end

      with_replaced_singleton_method(File, :lstat, replacement) do
        assert_equal 0, Hive::BrainstormSuggestions::Runner.sweep_inactive!(root)
      end
    end
  end

  def test_profile_and_availability_errors_fail_closed
    missing_method = Object.new
    missing_method.define_singleton_method(:policy_capabilities) { raise NoMethodError, "missing" }
    refute Hive::BrainstormSuggestions::Runner.profile_supported?(missing_method)

    broken = Object.new
    broken.define_singleton_method(:policy_capabilities) { raise RuntimeError, "broken" }
    provider = Hive::BrainstormSuggestions::Runner.new(
      profile: broken, model: "model", transport: ->(*) { flunk "transport must not run" }
    )
    refute provider.available?
  end

  def test_runtime_owned_by_an_uninspectable_process_is_live
    Dir.mktmpdir do |root|
      File.write(
        File.join(root, Hive::BrainstormSuggestions::Runner::OWNER_FILE),
        JSON.generate("pid" => Process.pid)
      )
      with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::EPERM }) do
        assert Hive::BrainstormSuggestions::Runner.send(:runtime_live?, root)
      end
    end
  end

  private

  def response(type, code, body)
    type.new("1.1", code, type.name).tap do |value|
      value.define_singleton_method(:read_body) { |&block| block.call(body) }
    end
  end
end
