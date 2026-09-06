require "test_helper"
require "hive/agent_profiles"
require "hive/brainstorm_suggestions/runner"
require "socket"

class HiveBrainstormSuggestionsRunnerTest < Minitest::Test
  include HiveTestHelper

  class FakeProfile
    attr_reader :bin

    def initialize(bin: "/bin/true", config_dir: nil)
      @bin = bin
      @config_dir = config_dir
    end

    def policy_capabilities
      [ Hive::BrainstormSuggestions::Runner::REQUIRED_CAPABILITY ]
    end

    def tool_scope_flags
      { allowed: [], disallowed: [] }
    end

    def configuration_directory(environment:)
      environment
      @config_dir.to_s
    end

    def credential_environment_keys
      []
    end
  end

  Bundle = Struct.new(:manifest) do
    def materialize(root)
      path = File.join(root, "bundle")
      FileUtils.mkdir_p(path, mode: 0o700)
      File.write(File.join(path, "context.md"), "repository evidence", mode: "w", perm: 0o400)
      File.chmod(0o400, File.join(path, "context.md"))
      path
    end

    def render_context(**) = "repository evidence"
    def question = { "text" => "Which adapter?" }
  end

  def bundle
    Bundle.new({ "entries" => [ { "source" => "repository" } ] })
  end

  def test_only_profiles_with_explicit_data_only_capability_are_supported
    assert Hive::BrainstormSuggestions::Runner.profile_supported?(Hive::AgentProfiles.lookup(:claude))
    %i[codex pi grok opencode].each do |name|
      refute Hive::BrainstormSuggestions::Runner.profile_supported?(Hive::AgentProfiles.lookup(name)), name
    end
  end

  def test_runner_uses_toolless_bubblewrap_launch_and_always_removes_runtime
    runtime = nil
    executor = lambda do |launch|
      runtime = launch.runtime_root
      assert File.directory?(runtime)
      assert_equal "/bin/true", launch.argv.first
      tools_index = launch.argv.index("--tools")
      assert_equal "", launch.argv.fetch(tools_index + 1)
      assert_equal "", launch.argv.fetch(launch.argv.index("--allowedTools") + 1)
      refute_includes launch.argv, "--disallowedTools"
      refute_includes launch.argv, "--unshare-net"
      assert_equal "", launch.argv.fetch(launch.argv.index("--setting-sources") + 1)
      assert_equal "{}", launch.argv.fetch(launch.argv.index("--settings") + 1)
      assert_equal "{}", launch.argv.fetch(launch.argv.index("--mcp-config") + 1)
      assert_includes launch.argv, "--strict-mcp-config"
      assert_includes launch.argv, "--disable-slash-commands"
      assert_includes launch.argv, "--no-session-persistence"
      assert_equal "dontAsk", launch.argv.fetch(launch.argv.index("--permission-mode") + 1)
      assert_equal "/bundle", launch.argv.fetch(launch.argv.index("--chdir") + 1)
      refute_includes launch.argv, "--bind"
      refute launch.environment.key?("HOME")
      refute launch.environment.key?("PATH")
      refute launch.argv.any? { |value| value.include?(Dir.pwd) }
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: JSON.generate("structured_output" => {
          "disposition" => "suggestion", "text" => "Use the adapter.",
          "rationale" => "It matches the evidence.", "provenance" => [ "repository" ]
        }),
        exit_code: 0, timed_out: false
      )
    end
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: Hive::AgentProfiles.lookup(:claude), executor: executor,
      bwrap_path: "/bin/true", executable_resolver: ->(*) { "/bin/true" }
    )

    result = runner.call(bundle: bundle)

    assert_equal "fresh", result.fetch("state")
    refute File.exist?(runtime)
  end

  def test_unsupported_route_is_unavailable_and_never_executes
    executed = false
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: Hive::AgentProfiles.lookup(:codex), executor: ->(*) { executed = true },
      bwrap_path: "/bin/true"
    )

    result = runner.call(bundle: bundle)

    assert_equal "unavailable", result.fetch("state")
    assert_equal false, executed
  end

  def test_failure_timeout_and_spawn_error_remove_runtime_without_raw_output
    outcomes = [
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: "provider secret body", exit_code: 2, timed_out: false
      ),
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: "partial secret body", exit_code: nil, timed_out: true
      ),
      Errno::ENOENT.new("provider secret path")
    ]

    outcomes.each do |outcome|
      runtime = nil
      executor = lambda do |launch|
        runtime = launch.runtime_root
        raise outcome if outcome.is_a?(Exception)

        outcome
      end
      runner = Hive::BrainstormSuggestions::Runner.new(
        profile: Hive::AgentProfiles.lookup(:claude), executor: executor,
        bwrap_path: "/bin/true", executable_resolver: ->(*) { "/bin/true" }
      )

      result = runner.call(bundle: bundle)
      assert_equal "failed", result.fetch("state")
      refute_includes result.fetch("safe_reason"), "secret"
      refute File.exist?(runtime)
    end
  end

  def test_startup_sweep_removes_only_owned_prefixed_directories
    Dir.mktmpdir do |root|
      stale = File.join(root, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}stale")
      unrelated = File.join(root, "other-runtime")
      FileUtils.mkdir_p(stale)
      FileUtils.mkdir_p(unrelated)
      old = Time.now - Hive::BrainstormSuggestions::Runner::SWEEP_GRACE_SEC - 1
      File.utime(old, old, stale)

      assert_equal 1, Hive::BrainstormSuggestions::Runner.sweep_inactive!(root)
      refute File.exist?(stale)
      assert File.directory?(unrelated)
    end
  end


  def test_startup_sweep_preserves_another_live_process_runtime
    Dir.mktmpdir do |root|
      active = File.join(root, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}active")
      FileUtils.mkdir_p(active)
      File.write(
        File.join(active, Hive::BrainstormSuggestions::Runner::OWNER_FILE),
        JSON.generate("pid" => Process.pid)
      )
      old = Time.now - Hive::BrainstormSuggestions::Runner::SWEEP_GRACE_SEC - 1
      File.utime(old, old, active)

      assert_equal 0, Hive::BrainstormSuggestions::Runner.sweep_inactive!(root)
      assert File.directory?(active)
    end
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

  def test_supported_profile_live_isolation_matrix
    skip "Bubblewrap is unavailable" unless File.executable?("/usr/bin/bwrap")
    skip "curl is unavailable" unless File.executable?("/usr/bin/curl")

    Dir.mktmpdir do |root|
      repository = File.join(root, "repository-secret")
      task = File.join(root, "task-secret")
      alternate = File.join(root, "alternate-output")
      File.write(repository, "repository")
      File.write(task, "task")
      server = TCPServer.new("127.0.0.1", 0)
      server_thread = Thread.new do
        client = server.accept
        client.readpartial(1024)
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        client.close
      end
      probes = [ repository, task, alternate, server.local_address.ip_port ].join("\n") + "\n"
      probe_bundle = Class.new(Bundle) do
        define_method(:initialize) do |manifest, probes|
          super(manifest)
          @probes = probes
        end

        define_method(:materialize) do |runtime|
          path = super(runtime)
          File.write(File.join(path, "probes.txt"), @probes, mode: "w", perm: 0o400)
          File.chmod(0o400, File.join(path, "probes.txt"))
          path
        end
      end.new(bundle.manifest, probes)
      worker = File.expand_path("../../fixtures/brainstorm_suggestions/sandbox-probe-worker", __dir__)
      runner = Hive::BrainstormSuggestions::Runner.new(
        profile: FakeProfile.new(bin: worker), bwrap_path: "/usr/bin/bwrap",
        executable_resolver: ->(*) { worker }
      )

      result = runner.call(bundle: probe_bundle)

      assert_equal "fresh", result.fetch("state"), result.inspect
      assert_equal "repository=false task=false shell=false network=true escape=false alternate=false",
                   result.fetch("text")
      refute File.exist?(alternate)
    ensure
      server&.close
      server_thread&.join(1)
    end
  end

  def test_large_stdin_and_eager_stdout_cannot_deadlock_before_timeout
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, timeout_sec: 1, bwrap_path: "/bin/true"
    )
    command = [ "/bin/sh", "-c", "dd if=/dev/zero bs=65536 count=2 2>/dev/null; cat >/dev/null" ]
    execution = Timeout.timeout(2) do
      runner.send(:execute, launch(command, "x" * (128 * 1024)))
    end

    assert_equal 0, execution.exit_code
    refute execution.timed_out
  end

  def test_closed_worker_stdin_is_a_bounded_execution_result
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, timeout_sec: 1, bwrap_path: "/bin/true"
    )
    command = [ "/bin/sh", "-c", "exec 0<&-; sleep 0.1" ]

    execution = runner.send(:execute, launch(command, "x" * (4 * 1024 * 1024)))

    assert_equal 0, execution.exit_code
    refute execution.timed_out
  end

  def test_cancelled_execution_discards_output_and_removes_runtime
    token = Hive::BrainstormSuggestions::Runner::Cancellation.new
    runtime = nil
    executor = lambda do |launch, cancellation|
      runtime = launch.runtime_root
      cancellation.cancel!
      Hive::BrainstormSuggestions::Runner::Execution.new(
        stdout: JSON.generate("structured_output" => {
          "disposition" => "suggestion", "text" => "Do not publish me.",
          "rationale" => "Cancellation won.", "provenance" => [ "repository" ]
        }),
        exit_code: 0, timed_out: false
      )
    end
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: Hive::AgentProfiles.lookup(:claude), executor: executor,
      bwrap_path: "/bin/true", executable_resolver: ->(*) { "/bin/true" }
    )

    result = runner.call(bundle: bundle, cancellation: token)

    assert_equal "failed", result.fetch("state")
    assert_equal "cancelled", result.fetch("error_code")
    refute File.exist?(runtime)
  end

  def test_malformed_result_and_executable_resolution_error_fail_closed
    malformed = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new,
      executor: ->(*) {
        Hive::BrainstormSuggestions::Runner::Execution.new(
          stdout: "{", exit_code: 0, timed_out: false
        )
      },
      bwrap_path: "/bin/true", executable_resolver: ->(*) { "/bin/true" }
    )
    assert_equal "malformed_result", malformed.call(bundle: bundle).fetch("error_code")

    unavailable = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new,
      bwrap_path: "/bin/true",
      executable_resolver: ->(*) { raise Errno::EACCES, "blocked" }
    )
    assert_nil unavailable.send(:available_executable)
  end

  def test_auth_copy_is_private_and_read_errors_leave_an_empty_auth_root
    Dir.mktmpdir do |root|
      config = File.join(root, "config")
      runtime = File.join(root, "runtime")
      FileUtils.mkdir_p([ config, runtime ])
      credentials = File.join(config, ".credentials.json")
      File.write(credentials, "{\"token\":\"fixture\"}\n", mode: "w", perm: 0o600)
      runner = Hive::BrainstormSuggestions::Runner.new(
        profile: FakeProfile.new(config_dir: config), bwrap_path: "/bin/true"
      )

      auth = runner.send(:prepare_auth, runtime)
      copied = File.join(auth, ".credentials.json")
      assert_equal File.read(credentials), File.read(copied)
      assert_equal 0o400, File.stat(copied).mode & 0o777

      FileUtils.rm_rf(auth)
      original_open = File.method(:open)
      replacement = lambda do |path, *args, **kwargs, &block|
        raise Errno::EACCES, "blocked" if path == credentials

        original_open.call(path, *args, **kwargs, &block)
      end
      with_replaced_singleton_method(File, :open, replacement) do
        auth = runner.send(:prepare_auth, runtime)
        assert File.directory?(auth)
        refute File.exist?(File.join(auth, ".credentials.json"))
      end
    end
  end

  def test_compatibility_mount_and_structured_output_variants
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, bwrap_path: "/bin/true"
    )
    argv = []
    with_replaced_singleton_method(File, :exist?, ->(path) { path == "/bin" }) do
      with_replaced_singleton_method(File, :symlink?, ->(*) { false }) do
        runner.send(:append_compatibility_mounts, argv)
      end
    end
    assert_equal [ "--ro-bind", "/bin", "/bin" ], argv

    nested = { "disposition" => "no_safe_suggestion", "reason_code" => "insufficient_evidence" }
    assert_equal nested, runner.send(:extract_structured_output, JSON.generate("result" => JSON.generate(nested)))
    assert_equal [ "plain" ], runner.send(:extract_structured_output, JSON.generate([ "plain" ]))
  end

  def test_execute_covers_success_cancellation_timeout_and_process_group_kill
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, timeout_sec: 0.02, bwrap_path: "/bin/true"
    )
    success = launch([ "/bin/sh", "-c", "read value; printf '%s' \"$value\"" ], "hello\n")
    execution = runner.send(:execute, success)
    assert_equal "hello", execution.stdout
    assert_equal 0, execution.exit_code
    refute execution.timed_out

    cancellation = Hive::BrainstormSuggestions::Runner::Cancellation.new
    cancellation.cancel!
    cancelled = runner.send(:execute, launch([ "/bin/sh", "-c", "sleep 10" ]), cancellation)
    assert cancelled.timed_out

    timed_out = runner.send(
      :execute,
      launch([ "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done" ])
    )
    assert timed_out.timed_out
    assert_nil runner.send(:terminate, 999_999_999)
  end

  def test_executable_resolution_supports_absolute_and_path_commands
    runner = Hive::BrainstormSuggestions::Runner.new(
      profile: FakeProfile.new, bwrap_path: "/bin/true"
    )

    assert_equal File.realpath("/bin/true"),
                 runner.send(:resolve_executable, FakeProfile.new(bin: "/bin/true"))
    assert_equal File.realpath("/bin/true"),
                 runner.send(:resolve_executable, FakeProfile.new(bin: "true"))
    assert_nil runner.send(
      :resolve_executable, FakeProfile.new(bin: "hive-missing-suggestion-worker")
    )
    assert_kind_of Numeric, runner.send(:monotonic_now)
  end

  def test_sweep_ignores_prefixed_entries_that_disappear_during_inspection
    Dir.mktmpdir do |root|
      broken = File.join(root, "#{Hive::BrainstormSuggestions::Runner::RUNTIME_PREFIX}gone")
      FileUtils.mkdir_p(broken)
      original_lstat = File.method(:lstat)

      replacement = lambda do |path|
        raise Errno::ENOENT, "gone" if path == broken

        original_lstat.call(path)
      end
      with_replaced_singleton_method(File, :lstat, replacement) do
        assert_equal 0, Hive::BrainstormSuggestions::Runner.sweep_inactive!(root)
      end
    end
  end

  private

  def launch(argv, stdin = "")
    Hive::BrainstormSuggestions::Runner::Launch.new(
      argv: argv, environment: {}, stdin: stdin,
      runtime_root: nil, bundle_root: nil
    )
  end
end
