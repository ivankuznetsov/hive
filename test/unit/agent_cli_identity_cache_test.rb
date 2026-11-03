require "test_helper"
require "hive/agent_profiles"
require "hive/agent_cli_identity"

class AgentCliIdentityCacheTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cli-spawn-identity")
    @bin = executable("bin/codex")
    @profile = Hive::AgentProfiles.lookup(:codex)
    @environment = { "PATH" => File.dirname(@bin) }
    @calls = []
    @runner = ->(**args) { @calls << args; [ "codex 0.156.1", "", true ] }
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def executable(relative, body = "#!/bin/sh\nexit 0\n")
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def observe(**options)
    Hive::AgentCliIdentity.observe_spawn(profile: @profile, argv: [ "codex", "prompt-secret" ],
      environment: @environment, cwd: @root, runner: @runner, **options)
  end

  def test_cache_releases_waiters_when_the_owner_is_interrupted
    cache = Hive::AgentCliIdentity::ObservationCache.new
    entered = Queue.new
    owner = Thread.new do
      cache.fetch(:cancelled, retain: true) { entered << true; sleep 10 }
    rescue Interrupt
      :interrupted
    end
    entered.pop
    waiter = Thread.new { cache.fetch(:cancelled, retain: true) { flunk "concurrent probe repeated" } }
    Thread.pass until waiter.status == "sleep"
    owner.raise(Interrupt)
    assert owner.join(1), "cancelled owner should finish"
    assert waiter.join(1), "cancelled observation must release waiters"
    assert_equal :interrupted, owner.value
    assert_equal "observation_failed", waiter.value.fetch(:reason)
    assert_equal({ version: "1.2.3" }, cache.fetch(:cancelled, retain: true) { { version: "1.2.3" } })
  ensure
    owner&.kill
    waiter&.kill
  end

  def test_cache_is_bounded_and_never_retains_nil_or_failed_values
    cache = Hive::AgentCliIdentity::ObservationCache.new(limit: 1)
    assert_nil cache.fetch(:empty, retain: true) { nil }
    assert_equal "1.2.3", cache.fetch(:first, retain: true) { { version: "1.2.3" } }[:version]
    cache.fetch(:second, retain: true) { { version: "2.3.4" } }
    assert_equal "3.4.5", cache.fetch(:first, retain: true) { { version: "3.4.5" } }[:version]
  end

  def test_private_selection_uses_the_exact_path_before_diagnostic_redaction
    token = "ghp_#{'x' * 36}"
    path = executable("#{token}/codex")
    identity = observe(argv: [ path ])
    assert_equal path, @calls.fetch(0).fetch(:executable)
    assert_includes identity.launch_path, "[REDACTED:github_token]"
    refute_includes identity.to_h.to_s, token
    log = File.join(@root, "redacted-spawn.log")
    Hive::AgentCliIdentity.write_spawn_log(path: log, identity: identity, cwd: @root,
      label: token, argc: 1)
    refute_includes File.read(log), token
  end

  def test_filesystem_version_remains_visible_when_probes_are_skipped
    manifest = File.join(@root, "package.json")
    File.write(manifest, JSON.generate(name: "@openai/codex", version: "0.153.4", bin: { codex: "bin/codex" }))
    identity = Hive::AgentCliIdentity.observe(profile: @profile,
      environment: @environment, cwd: @root, probe: true,
      budget: Hive::AgentCliIdentity::ProbeBudget.new(seconds: 0), runner: @runner)
    assert_equal "0.153.4", identity.version
    assert_equal "probe_budget_exhausted", identity.version_reason
    assert_empty @calls
    assert_equal "0.153.4", observe.version
    assert_empty @calls
  end

  def test_actual_command_wins_and_repeated_observations_reuse_exact_version
    other = executable("other/codex")
    identity = observe(argv: [ other, "prompt-secret" ])
    assert_equal other, identity.launch_path
    assert_equal "0.156.1", identity.version
    assert_equal identity, observe(argv: [ other, "different prompt" ])
    assert_equal 1, @calls.size
    refute_includes identity.to_h.to_s, "prompt-secret"
    assert_predicate identity, :frozen?
  end

  def test_file_replacement_symlink_retarget_and_context_change_invalidate_observation
    other = executable("other/codex")
    observe
    File.utime(Time.now + 1, Time.now + 1, @bin)
    observe
    assert_equal 2, @calls.size
    File.unlink(@bin)
    File.symlink(other, @bin)
    assert_equal other, observe.effective_target
    assert_equal 3, @calls.size
    observe(environment: @environment.merge("HOME" => "/different"))
    observe(cwd: File.dirname(@bin))
    assert_equal 5, @calls.size
  end

  def test_concurrent_probes_coalesce_and_failures_are_not_retained
    started = Queue.new
    release = Queue.new
    runner = ->(**args) { @calls << args; started << true; release.pop; [ "codex 0.156.1", "", true ] }
    first = Thread.new { observe(runner: runner) }
    started.pop
    second = Thread.new { observe(runner: runner) }
    release << true
    assert_equal first.value, second.value
    assert_equal 1, @calls.size
    fail_runner = ->(**args) { @calls << args; [ "", "secret", false ] }
    2.times { assert_equal "probe_failed", observe(cwd: "/", runner: fail_runner).version_reason }
    assert_equal 3, @calls.size
  end

  def test_opaque_launcher_is_context_sensitive_and_its_version_is_not_retained
    File.write(@bin, "#!/bin/sh\nexec mise exec -- codex\n")
    first = observe
    assert_equal "opaque_launcher", first.reason
    assert_nil first.effective_target
    assert_equal "0.156.1", first.version
    observe
    assert_equal 2, @calls.size
  end

  def test_managed_binding_identifies_host_cli_and_omits_sensitive_prefix_options
    prefix = [ "/usr/bin/bwrap", "--setenv", "TOKEN", "private-value", "--ro-bind", File.dirname(@bin), "/agent-runtime" ]
    identity = observe(argv: [ *prefix, "/agent-runtime/codex", "prompt-secret" ],
      regime: :managed, command_prefix: prefix)
    assert_equal @bin, identity.launch_path
    assert_equal "/agent-runtime/codex", identity.sandbox_executable
    assert_equal [ "/usr/bin/bwrap" ], identity.command_prefix
    assert_equal "prepared_runtime_binding", identity.authority
    refute_includes identity.to_h.to_s, "private-value"
    # A host probe cannot reproduce namespace-only PATH/HOME; leave its version unknown.
    assert_nil identity.version
    assert_empty @calls
  end

  def test_managed_exact_file_binding_and_unavailable_binding_are_explicit
    prefix = [ "/usr/bin/bwrap", "--ro-bind", @bin, "/agent/codex" ]
    identity = observe(argv: [ *prefix, "/agent/codex" ], regime: :managed, command_prefix: prefix)
    assert_equal @bin, identity.launch_path
    unknown = observe(argv: [ "/usr/bin/bwrap", "/missing/codex" ],
      regime: :managed, command_prefix: [ "/usr/bin/bwrap" ])
    assert_equal "prepared_binding_unavailable", unknown.reason
    assert_nil unknown.launch_path
  end

  def test_advisory_failure_cannot_prevent_execution_and_invalid_evidence_is_unknown
    profile = Struct.new(:name, :runtime_profile) do
      def observe_version(**) = raise(IOError, "private-value")
    end.new(:codex, @profile.runtime_profile)
    identity = observe(profile: profile)
    assert_equal @bin, identity.launch_path
    assert_equal "observation_failed", identity.version_reason
    missing = Hive::AgentCliIdentity.observe_spawn(profile: Object.new, argv: [], environment: {}, cwd: @root)
    assert_equal "unknown", missing.profile
    assert_equal "observation_failed", missing.reason
  end

  def test_probe_exceptions_are_nonfatal_and_private_log_redacts_identity
    identity = observe(runner: ->(**) { raise IOError, "private-value" })
    assert_equal @bin, identity.launch_path
    assert_equal "probe_failed", identity.version_reason
    path = File.join(@root, "spawn.log")
    Hive::AgentCliIdentity.write_spawn_log(path: path, identity: identity, cwd: @root,
      label: "test", argc: 2)
    event = File.read(path)
    assert_includes event, @bin
    assert_includes event, '"version_reason":"probe_failed"'
    assert_equal 0o600, File.stat(path).mode & 0o777
    refute_includes event, "private-value"
  end
end
