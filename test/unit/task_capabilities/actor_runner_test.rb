require "test_helper"
require "hive/task_capabilities/actor_runner"
require "hive/attempts/dispatcher"
require "hive/agent"
require "hive/workflow_package/runtime_policy"
require "socket"
require "hive/stages/base"
require "hive/scripts/workflow_policy_hook"

class TaskCapabilitiesActorRunnerTest < Minitest::Test
  include HiveTestHelper

  def test_parent_scope_clamps_launch_budget_and_deadline_and_never_refills
    session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 0.2)
    first = session.reserve!(budget_usd: 3, timeout_sec: 10)
    assert_equal 2, first.budget_usd
    assert_operator first.timeout_sec, :<=, 0.2
    assert_raises(Hive::TaskCapabilities::Admission::Error) { session.reserve!(budget_usd: 1, timeout_sec: 1) }
    first.close
    assert_raises(Hive::TaskCapabilities::Admission::Error) { session.reserve!(budget_usd: 1, timeout_sec: 1) }
  ensure
    session&.close
  end

  def test_parent_cancel_terminates_and_reaps_every_live_spawn_before_close_returns
    session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 10)
    spawns = 2.times.map { session.reserve!(budget_usd: 1, timeout_sec: 10) }
    pids = spawns.map do |spawn|
      pid = Process.spawn(RbConfig.ruby, "-e", "trap('TERM') {}; sleep 30", pgroup: true, out: File::NULL, err: File::NULL)
      spawn.attach(pid)
      pid
    end
    session.cancel!
    session.close
    pids.each do |pid|
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
    end
    assert spawns.all? { |spawn| spawn.stop_reason == "parent_cancelled" }
    assert_raises(Hive::TaskCapabilities::Admission::Error) { session.reserve!(budget_usd: 1, timeout_sec: 1) }
  ensure
    session&.close
  end

  def test_runtime_timeout_and_observed_budget_kill_live_spawns
    session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5)
    timeout = session.reserve!(budget_usd: 1, timeout_sec: 0.05)
    budget = session.reserve!(budget_usd: 0.1, timeout_sec: 5)
    [ timeout, budget ].each do |spawn|
      spawn.attach(Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true, out: File::NULL, err: File::NULL))
    end
    budget.observe_cost!(0.1)
    sleep 0.1
    assert_equal "timeout", timeout.stop_reason
    assert_equal "budget_exhausted", budget.stop_reason
    session.close
  ensure
    session&.close
  end

  def test_preflight_cannot_launch_after_the_original_deadline_or_parent_cancel
    session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 5)
    timed = session.reserve!(budget_usd: 1, timeout_sec: 0.01)
    sleep 0.02
    assert_raises(Hive::TaskCapabilities::Admission::Error) { timed.launch_timeout! }
    refute timed.started?
    cancelled = session.reserve!(budget_usd: 1, timeout_sec: 5)
    session.cancel!
    assert_raises(Hive::TaskCapabilities::Admission::Error) { cancelled.launch_timeout! }
    refute cancelled.started?
  ensure
    session&.close
  end

  def test_parent_term_signal_reaches_all_subspawns_and_context_close_reaps_them
    context = Hive::Attempts::Context.send(:new, attempt_id: "parent", task_generation: 0)
    sessions = 2.times.map { Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5, parent: context) }
    spawns = sessions.map { |session| session.reserve!(budget_usd: 1, timeout_sec: 5) }
    pids = spawns.map do |spawn|
      pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true, out: File::NULL, err: File::NULL)
      spawn.attach(pid)
      pid
    end
    Process.kill("TERM", Process.pid)
    deadline = Time.now + 2
    sleep 0.01 until spawns.all? { |spawn| spawn.stop_reason } || Time.now >= deadline
    assert spawns.all? { |spawn| spawn.stop_reason == "parent_cancelled" }
    context.close
    pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
  ensure
    context&.close
  end

  def test_failed_process_identity_attachment_reaps_its_child_and_never_signals_a_retired_pid
    session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5)
    child = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
    spawn = session.reserve!(budget_usd: 1, timeout_sec: 5)
    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(*) { nil }) do
      assert_raises(Hive::TaskCapabilities::Admission::Error) { spawn.attach(child) }
      spawn.close
      assert_raises(Errno::ECHILD) { Process.waitpid(child, Process::WNOHANG) }
      retired = session.reserve!(budget_usd: 1, timeout_sec: 5)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { retired.attach(child) }
      test = self
      with_replaced_singleton_method(Process, :kill, ->(*) { test.flunk "retired PID signalled" }) { retired.close }
    end
  ensure
    session&.close
  end

  def test_a_live_parent_reservation_defers_nested_attempt_for_another_stage
    with_actor_attempt do |task, store, dispatcher, parent, launches|
      snapshot = Hive::Attempts::CapacitySnapshot.build(store: store)
      assert snapshot.task_reserved?(project: "demo", task_slug: task.slug)
      nested = dispatcher.dispatch(task: task, project: "demo", intended_stage: "6-review",
        argv: [ "hive", "run", task.slug ], request_id: "nested", provider: "claude")
      assert_equal :deferred, nested.status
      assert_equal "capacity", nested.reason
      assert_equal [ parent.attempt_id ], store.active_attempts.map(&:attempt_id)
      assert_equal 1, launches.size
    end
  end

  def test_fake_actor_stays_in_parent_attempt_without_a_second_reservation_or_lease
    with_actor_attempt do |task, store, _dispatcher, parent, launches|
      cfg = {}
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 10, parent: context)
      launcher = lambda do |actual_task, **arguments|
        assert_same task, actual_task
        assert_equal 1, arguments.fetch(:max_budget_usd)
        assert_operator arguments.fetch(:timeout_sec), :<=, 5
        refute arguments.fetch(:terminate_on_parent_signal)
        assert_equal [ parent.attempt_id ], store.active_attempts.map(&:attempt_id)
        { status: :ok, actual_provider: "anthropic", actual_model: "approved", usage: { cost: 0.1 } }
      end
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: cfg, session: session, context: context, launcher: launcher, store: store)
      binding = pinned_binding(cfg)
      accept_binding(task, binding)
      with_replaced_singleton_method(Hive::Lock, :with_task_lock, ->(*) { flunk "recursive lease acquisition" }) do
        result = runner.run(binding, prompt: "Contribute bounded guidance")
        assert_equal :ok, result.fetch(:status)
        assert_equal parent.attempt_id, result.fetch(:parent_attempt_id)
        refute_equal parent.attempt_id, result.fetch(:capability_spawn_id)
      end
      assert_equal 1, launches.size
      assert_equal 1, Hive::Attempts::CapacitySnapshot.build(store: store).global_count
      incapable = binding.merge("actor" => { "profile" => "codex" })
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(incapable, prompt: "denied") }
      assert_match "cannot enforce", error.message
    ensure
      context&.close
    end
  end

  def test_actual_agent_launcher_cancellation_waits_for_both_launch_threads_and_chains_prior_handler
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      root = task.project_root
      binary = File.join(root, "fixture-claude")
      File.write(binary, "#!/usr/bin/ruby\nFile.write(File.join(Dir.pwd, Process.pid.to_s + '.pid'), Process.pid.to_s)\ntrap('TERM') {}\nsleep 30\n")
      File.chmod(0o755, binary)
      folder = task.folder
      task.define_singleton_method(:log_dir) { File.join(folder, "logs") }
      cfg = { "agents" => { "claude" => { "bin" => binary } } }
      chained = 0
      previous = trap("TERM") { chained += 1 }
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5, parent: context)
      launcher = ->(actual_task, **arguments) { Hive::Agent.new(task: actual_task, **arguments.except(:cfg, :capability_invocation, :cleanup_runtime_policy)).run! }
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: cfg, session: session, context: context, launcher: launcher, store: store)
      binding = pinned_binding(cfg)
      accept_binding(task, binding)
      threads = 2.times.map { Thread.new { runner.run(binding, prompt: "fixture") } }
      deadline = Time.now + 3
      sleep 0.01 until Dir[File.join(folder, "*.pid")].size == 2 || Time.now >= deadline
      assert_equal 2, Dir[File.join(folder, "*.pid")].size
      Process.kill("TERM", Process.pid)
      context.close
      assert_equal 1, chained
      threads.each do |thread|
        assert_equal "parent_cancelled", thread.value.fetch(:error_reason)
      end
      pids = Dir[File.join(folder, "*.pid")].map { |path| Integer(File.read(path)) }
      pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
      # Repeated context/spawn cleanup may never signal the old PID again.
      with_replaced_singleton_method(Hive::ProcessKill, :signal_captured_processes, ->(*) { flunk "repeated cleanup" }) { context.close }
    ensure
      context&.close
      trap("TERM", previous) if previous
    end
  end

  def test_real_compiled_policy_denies_unlisted_commands_and_isolates_an_approved_local_fixture
    with_tmp_dir do |root|
      target = File.join(root, "local")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "input.txt"), "approved local fixture")
      secret = File.join(root, "outside.txt")
      File.write(secret, "outside approval")
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]
      File.write(File.join(target, "check.rb"), <<~SCRIPT)
        require 'socket'
        require 'json'
        checks = { 'fixture' => File.read('input.txt') }
        checks['outside'] = begin; File.read(#{secret.inspect}); 'escaped'; rescue SystemCallError; 'denied'; end
        checks['network'] = begin; Socket.tcp('127.0.0.1', #{port}, connect_timeout: 0.2).close; 'escaped'; rescue SystemCallError; 'denied'; end
        checks['environment'] = ENV.key?('HIVE_UNAPPROVED_SECRET') ? 'escaped' : 'denied'
        puts JSON.generate(checks)
      SCRIPT
      permissions = { "tools" => [ "Read", "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [] }
      policy = Hive::WorkflowPackage::RuntimePolicy.compile(permissions, task_folder: target,
        profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(root, "policy"), isolated_commands: true)
      settings = JSON.parse(File.read(policy.settings_path))
      hook = Shellwords.shellsplit(settings.dig("hooks", "PreToolUse", 0, "hooks", 0, "command"))
      denied = policy_decision(hook, target, "ruby missing.rb")
      assert_equal "deny", denied.fetch("permissionDecision")
      refute denied.key?("updatedInput")
      refute File.exist?(File.join(target, "unlisted-ran"))
      allowed = policy_decision(hook, target, "ruby check.rb")
      assert_equal "allow", allowed.fetch("permissionDecision")
      command = allowed.fetch("updatedInput").fetch("command")
      output, error, status = Open3.capture3({ "HIVE_UNAPPROVED_SECRET" => "must-not-reach-tool" }, "/usr/bin/sh", "-c", command, chdir: target)
      assert status.success?, error
      assert_equal({ "fixture" => "approved local fixture", "outside" => "denied", "network" => "denied", "environment" => "denied" }, JSON.parse(output))
      external = { "tool_name" => "Read", "tool_input" => { "file_path" => secret } }
      out, _error, status = Open3.capture3(policy.environment, *hook, stdin_data: JSON.generate(external), chdir: target, unsetenv_others: true)
      assert status.success?
      assert_equal "deny", JSON.parse(out).dig("hookSpecificOutput", "permissionDecision")
      denied = policy_decision(hook, target, "ruby check.rb https://external.invalid")
      assert_equal "deny", denied.fetch("permissionDecision")
      assert_empty policy.domains
      assert_equal [ target ], policy.directories
    ensure
      listener&.close
      policy&.cleanup!
    end
  end

  def test_isolated_compiler_refuses_network_and_the_exact_hook_fails_closed_on_unreadable_policy
    with_tmp_dir do |root|
      permissions = { "tools" => [ "Bash" ], "commands" => [ "ruby check.rb" ], "domains" => [ "external.invalid" ] }
      assert_raises(Hive::ConfigError) do
        Hive::WorkflowPackage::RuntimePolicy.compile(permissions, task_folder: root,
          profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(root, "denied"), isolated_commands: true)
      end
      refute File.exist?(File.join(root, "denied"))
      policy = Hive::WorkflowPackage::RuntimePolicy.compile({ "tools" => [ "Read" ] }, task_folder: root,
        profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(root, "policy"), isolated_commands: true)
      settings = JSON.parse(File.read(policy.settings_path))
      hook = Shellwords.shellsplit(settings.dig("hooks", "PreToolUse", 0, "hooks", 0, "command"))
      File.unlink(policy.policy_path)
      output, error, status = Open3.capture3(policy.environment, *hook, stdin_data: JSON.generate("tool_name" => "Read", "tool_input" => { "file_path" => "/etc/passwd" }), unsetenv_others: true)
      assert_equal 2, status.exitstatus
      assert_empty output
      assert_includes error, "policy hook failed"
    ensure
      policy&.cleanup!
    end
  end

  def test_own_route_survives_outer_routing_and_usage_is_recorded_once_under_parent
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      binary = File.join(task.project_root, "specialist")
      File.write(binary, <<~SCRIPT)
        #!/usr/bin/ruby
        require 'json'
        puts JSON.generate(type: 'system', subtype: 'init', model: 'approved')
        puts JSON.generate(type: 'result', subtype: 'success', model: 'approved', result: 'Use labelled controls.', total_cost_usd: 0.05,
          usage: { input_tokens: 1, output_tokens: 2 })
      SCRIPT
      File.chmod(0o755, binary)
      cfg = { "agents" => { "claude" => { "bin" => binary } } }
      task.define_singleton_method(:log_dir) { File.join(folder, "logs") }
      outer = { "mode" => "explicit", "route" => { "adapter" => "codex", "model" => "outer-model", "effort" => "low",
        "provider_account_id" => "outer", "launch_binding_id" => "default", "billing_route" => "api", "billing_evidence_source" => "provider_account_config" } }
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0, routing: outer)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 10, parent: context)
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: cfg, session: session, context: context, store: store)
      observed = []
      binding = pinned_binding(cfg)
      accept_binding(task, binding)
      test = self
      probe = lambda do |profile, launch_binding:|
        test.assert_equal "claude", profile.name.to_s
        test.assert_equal "default", launch_binding.id
        Hive::AgentRuntime::ProbeResult.new(provider: :claude, launcher_identity: binary, version: "2.1.316", capability_evidence: [])
      end
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, probe) do
          with_replaced_singleton_method(Hive::UsageDb, :record!, ->(**row) { observed << row }) do
            result = runner.run(binding, prompt: "Contribute UI guidance")
            assert_equal :ok, result.fetch(:status)
            assert_equal "approved", result.fetch(:actual_model)
            assert_equal "anthropic", result.fetch(:actual_provider)
            assert_equal 1, observed.size
            assert_equal parent.attempt_id, observed.first.fetch(:attempt_id)
            assert_equal result.fetch(:capability_spawn_id), observed.first.fetch(:session_id)
            assert_equal "subscription", observed.first.fetch(:billing_route)
            refute_equal "outer-model", observed.first.fetch(:actual_model)
            budget, timeout = session.primary_limits(budget_usd: 2, timeout_sec: 10)
            assert_in_delta 1.95, budget
            assert_operator timeout, :<, 10
          end
        end
      end
      assert_empty store.fetch(parent.attempt_id)["diagnostics"].fetch("capability_spawns")
      assert_equal parent.lease_version, store.fetch(parent.attempt_id).lease_version
    ensure
      context&.close
    end
  end

  def test_settlement_cannot_refill_consumed_budget_or_duplicate_a_refund
    session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 5)
    spawn = session.reserve!(budget_usd: 1, timeout_sec: 2)
    result = { status: :ok, usage: { cost: 0.25 } }
    session.settle!(spawn, result)
    session.settle!(spawn, result)
    assert_equal 1.75, session.remaining_budget
    rest = session.reserve!(budget_usd: 5, timeout_sec: 2)
    assert_equal 1.75, rest.budget_usd
    assert_raises(Hive::TaskCapabilities::Admission::Error) { session.primary_limits(budget_usd: 2, timeout_sec: 5) }
  ensure
    session&.close
  end

  def test_runtime_skill_drift_and_unaccepted_bindings_cannot_launch_or_repin_on_retry
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      cfg = {}
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 10, parent: context)
      calls = []
      launcher = ->(_task, **args) { calls << args; { status: :ok, actual_provider: "anthropic", actual_model: "approved" } }
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: cfg, session: session, context: context, store: store, launcher: launcher)
      binding = pinned_binding(cfg).merge("skill" => "fixture-skill")
      skill = File.join(task.project_root, ".claude/skills/fixture-skill/SKILL.md")
      FileUtils.mkdir_p(File.dirname(skill))
      File.write(skill, "Pinned skill")
      binding["skill_identity"] = Hive::TaskCapabilities::Admission.skill_identity(binding, project_root: task.project_root, cfg: cfg)
      accept_binding(task, binding)
      assert_equal :ok, runner.run(binding, prompt: "first").fetch(:status)
      changed = binding.merge("budget_usd" => 2)
      assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(changed, prompt: "unaccepted") }
      cfg["agents"] = { "claude" => { "bin" => "changed-runtime" } }
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(binding, prompt: "drift") }
      assert_match "runtime identity changed", error.message
      cfg.delete("agents")
      File.write(skill, "Drifted skill")
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(binding, prompt: "drift") }
      assert_equal "task_capability_missing_skill", error.reason
      File.write(skill, "Pinned skill")
      assert_equal :ok, runner.run(binding, prompt: "retry").fetch(:status)
      assert_equal 2, calls.size
      assert_equal calls.first.fetch(:capability_invocation).admitted_route, calls.last.fetch(:capability_invocation).admitted_route
    ensure
      context&.close
    end
  end

  def test_a_changed_accepted_route_and_unverified_runtime_result_fail_closed
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 10, parent: context)
      binding = pinned_binding({})
      accept_binding(task, binding)
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: {}, session: session, context: context, store: store,
        launcher: ->(*) { { status: :ok } })
      result = runner.run(binding, prompt: "identity required")
      assert_equal "capability_actor_identity_unverified", result.fetch(:error_reason)
      account = Hive::ProviderRouting::Account.new(id: "new-default", adapter: "claude", launch_binding: "default", models: [ "approved" ], max_concurrent: 5, cooldown_sec: {})
      cfg = { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => { account.id => account } }
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: cfg, session: session, context: context, store: store, launcher: ->(*) { flunk "route changed" })
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(binding, prompt: "no repinning") }
      assert_match "approved route changed", error.message
    ensure
      context&.close
    end
  end

  def test_scope_failures_are_visible_before_launch_and_cannot_broaden_targets
    [ :symlink, :preset, :missing_command ].each do |failure|
      with_actor_attempt do |task, store, _dispatcher, parent, _launches|
        context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
        session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5, parent: context)
        binding = pinned_binding({})
        case failure
        when :symlink
          File.symlink(task.project_root, File.join(task.folder, "outside"))
          binding["targets"] = [ "outside" ]
        when :preset
          binding["permissions"] = { "preset" => "scoped", "tools" => [ "Read" ] }
        when :missing_command
          binding["permissions"] = { "tools" => [ "Bash" ], "commands" => [ "hive-uninstalled-fixture-command" ], "domains" => [] }
        end
        accept_binding(task, binding)
        runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: {}, session: session, context: context, store: store, launcher: ->(*) { flunk "unsupported scope launched" })
        error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(binding, prompt: "bounded") }
        assert_match(/task-owned local scope|enforceable exact bounded|declared executable/, error.message)
      ensure
        context&.close
      end
    end
  end

  def test_security_actor_rechecks_the_accepted_operator_approval_on_every_launch
    [ true, false ].each do |covered|
      with_actor_attempt(stage: "6-review") do |task, store, _dispatcher, parent, _launches|
        context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
        session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5, parent: context)
        FileUtils.mkdir_p(File.join(task.folder, "local"))
        binding = pinned_binding({}).merge("id" => "security", "kind" => "verification", "stage" => "review", "targets" => [ "local" ],
          "permissions" => { "tools" => [ "Read" ], "commands" => [], "domains" => [] }, "approval_reference" => "local")
        envelope = binding.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security", "budget_usd" => covered ? 1 : 0.5)
        approval = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: envelope).blob(task_identity: { "id" => task.id.to_s, "slug" => task.slug, "workflow" => "coding" })
        accept_binding(task, binding, approvals: [ approval ])
        runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: {}, session: session, context: context, store: store,
          launcher: ->(*) { { status: :ok, actual_provider: "anthropic", actual_model: "approved" } })
        if covered
          assert_equal :ok, runner.run(binding, prompt: "source review").fetch(:status)
        else
          error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(binding, prompt: "outside approval") }
          assert_equal "task_capability_approval_scope", error.reason
        end
      ensure
        context&.close
      end
    end
  end

  def test_prelaunch_runtime_denial_does_not_consume_the_primary_allowance
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      cfg = { "agents" => { "claude" => { "bin" => "ruby" } } }
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 10, parent: context)
      binding = pinned_binding(cfg)
      accept_binding(task, binding)
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: cfg, session: session, context: context, store: store)
      probe = Hive::AgentRuntime::ProbeResult.new(provider: :claude, launcher_identity: "ruby", version: "2.1.0", capability_evidence: [])
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, ->(*) { probe }) do
          result = runner.run(binding, prompt: "unsupported runtime")
          assert_equal "provider_route_preflight_failed", result.fetch(:error_reason)
        end
      end
      assert_equal 2, session.remaining_budget
      assert_equal 2, session.primary_limits(budget_usd: 2, timeout_sec: 10).first
      assert_raises(Hive::TaskCapabilities::Admission::Error) { session.primary_limits(budget_usd: 2, timeout_sec: 10) }
    ensure
      context&.close
    end
  end

  def test_unavailable_security_account_keeps_its_strict_recovery_and_unrelated_allowance
    with_actor_attempt(stage: "6-review") do |task, store, _dispatcher, parent, _launches|
      account = Hive::ProviderRouting::Account.new(id: "approved", adapter: "claude", launch_binding: "default", models: [ "approved" ], max_concurrent: 1, cooldown_sec: {})
      cfg = { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => { account.id => account } }
      actor = { "profile" => "claude", "provider" => "anthropic", "model" => "approved", "provider_account" => account.id, "launch_binding" => "default" }
      binding = pinned_binding(cfg, actor: actor).merge("id" => "security", "kind" => "verification", "stage" => "review", "approval_reference" => "local",
        "permissions" => { "tools" => [ "Read" ] })
      envelope = binding.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => "security")
      approval = Hive::TaskCapabilities::Approval.new(reference: "local", envelope: envelope).blob(task_identity: { "id" => task.id.to_s, "slug" => task.slug, "workflow" => "coding" })
      accept_binding(task, binding, approvals: [ approval ])
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 10, parent: context)
      runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: {}, session: session, context: context, store: store, launcher: ->(*) { flunk "unavailable approved route launched" })
      error = assert_raises(Hive::TaskCapabilities::Admission::Error) { runner.run(binding, prompt: "approved source review") }
      assert_equal "task_capability_route_unavailable", error.reason
      assert_includes error.message, "restore the approved route or archive/cancel"
      refute_includes error.message, "revised execution plan"
      assert_equal 2, session.remaining_budget
    ensure
      context&.close
    end
  end

  def test_live_child_accounts_are_visible_and_atomic_admission_rechecks_a_stale_view
    with_actor_attempt do |task, store, dispatcher, parent, _launches|
      account = Hive::ProviderRouting::Account.new(id: "specialist", adapter: "claude", launch_binding: "approved", models: [ "approved" ], max_concurrent: 1, cooldown_sec: {})
      cfg = { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => { account.id => account } }
      actor = { "profile" => "claude", "provider" => "anthropic", "model" => "approved", "provider_account" => account.id }
      route = Hive::ProviderRouting::Configuration.capability_route(cfg: cfg, actor: actor)
      view = Hive::Attempts::AdmissionView.new(store: store, records: store.active_attempts)
      policy = Hive::ProviderRouting::Configuration.from(cfg: cfg, stage_name: "review", routing: { "pool" => [ { "provider" => account.id, "model" => "approved" } ], "pin" => { "provider" => account.id } }).policy
      next_task = task.dup
      next_task.slug = "unrelated"
      next_task.id = "43"
      next_task.folder = File.join(File.dirname(task.folder), next_task.slug)
      next_task.state_file = File.join(next_task.folder, "state.md")
      FileUtils.mkdir_p(next_task.folder)
      File.write(next_task.state_file, "Task\n<!-- WAITING -->\n")
      store.with_capability_spawn(attempt_id: parent.attempt_id, spawn_id: "child", route: route, accounts: cfg.fetch(Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY)) do
        live = store.active_attempts
        counts = Hive::Attempts::CapacitySnapshot.provider_account_capacity(accounts: cfg.fetch(Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY), records: live, reserved_attempt_ids: live.map(&:attempt_id))
        assert_equal 1, counts.fetch(account.id).fetch("observed")
        assert_equal 1, Hive::Attempts::CapacitySnapshot.build(store: store).global_count
        assert_raises(Hive::Attempts::CapacityExceeded) do
          store.with_capability_spawn(attempt_id: parent.attempt_id, spawn_id: "second-child", route: route, accounts: cfg.fetch(Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY)) { flunk "account overbooked" }
        end
        # The routing snapshot predates the live child. SQL must reject the
        # outer admission even though its precomputed decision selected it.
        result = dispatcher.dispatch(task: next_task, project: "demo", intended_stage: "6-review",
          argv: [ "hive", "run", next_task.slug ], request_id: "outer-concurrent", provider: "claude", routing_policy: policy, admission_view: view)
        assert_equal :deferred, result.status
        assert_equal "capacity", result.reason
      end
      assert_empty store.fetch(parent.attempt_id)["diagnostics"].fetch("capability_spawns")
      assert_equal parent.lease_version, store.fetch(parent.attempt_id).lease_version
      # Unrelated ordinary work retains admission after the child completes.
      admitted = dispatcher.dispatch(task: next_task, project: "demo", intended_stage: "6-review",
        argv: [ "hive", "run", next_task.slug ], request_id: "outer-after", provider: "claude", routing_policy: policy)
      assert_equal :accepted, admitted.status
    end
  end

  def policy_decision(hook, target, command)
    event = { "tool_name" => "Bash", "tool_input" => { "command" => command } }
    output, error, status = Open3.capture3({ "PATH" => "/usr/bin:/bin" }, *hook, stdin_data: JSON.generate(event), chdir: target, unsetenv_others: true)
    assert status.success?, error
    JSON.parse(output).fetch("hookSpecificOutput")
  end

  def pinned_binding(cfg, actor: { "profile" => "claude", "provider" => "anthropic", "model" => "approved" })
    profile = Hive::AgentProfiles.lookup(actor.fetch("profile"), cfg: cfg)
    { "id" => "fixture", "kind" => "guidance", "stage" => "execute", "actor" => actor,
      "actor_fingerprint" => Hive::WorkflowPackage::Configuration.profile_fingerprint(profile),
      "actor_route" => Hive::ProviderRouting::Configuration.capability_route(cfg: cfg, actor: actor),
      "permissions" => "read-only", "targets" => [], "budget_usd" => 1, "timeout_sec" => 5 }
  end

  def accept_binding(task, binding, approvals: [])
    prepare_test_runtime_project(task.project_root)
    task.workflow = Hive::Workflows::Coding::DESCRIPTOR
    definition = binding.slice("id", "kind", "actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("stages" => [ binding.fetch("stage") ])
    catalog = Hive::TaskCapabilities::Catalog.new(workflow: task.workflow, definitions: [ definition ])
    plan = Hive::TaskCapabilities::Plan.minimal(task_identity: { "id" => task.id.to_s, "slug" => task.slug, "workflow" => "coding" }, catalog: catalog, source: {}, policy: {})
    plan = Hive::TaskCapabilities::Plan.new(plan.to_h.merge("bindings" => [ binding ], "approvals" => approvals.map { |approval| { "digest" => Digest::SHA256.hexdigest(Hive::WorkflowPackage::CanonicalJSON.generate(approval)) } }))
    Hive::TaskMeta.write(task.folder, id: task.id, slug: task.slug, display_name: nil, workflow: "coding", task_capabilities: plan.adoption)
    Hive::TaskCapabilities::Store.new(task.folder).activate(plan, expected_version: nil, approvals: approvals)
  end

  def with_actor_attempt(stage: "4-execute")
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3")).migrate!
      folder = File.join(root, "project/.hive-state/stages", stage, "actor-task")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "state.md"), "Task\n<!-- WAITING -->\n")
      prepare_test_runtime_project(File.join(root, "project"))
      task_id = Hive::TaskCounter.next_or_nil
      task = Struct.new(:id, :slug, :folder, :project_root, :state_file, :stage_name, :stage_index, :worktree_path, :workflow, keyword_init: true).new(
        id: task_id.to_s, slug: "actor-task", folder: folder, project_root: File.join(root, "project"), state_file: File.join(folder, "state.md"), stage_name: stage.split("-", 2).last, stage_index: stage.to_i)
      database.transaction do |db|
        installation = db[:installations].get(:installation_id)
        db[:projects].insert(project_id: "project", installation_id: installation, registration_id: "project", name: "demo",
          observed_path: task.project_root, state_root_path: File.join(task.project_root, ".hive-state"), active: 1,
          registered_at: Time.now.utc.iso8601, last_observed_at: Time.now.utc.iso8601)
      end
      store = Hive::Attempts::Repository.new(database: database, root: File.join(root, "payload"))
      launches = []
      launcher = Object.new
      launcher.define_singleton_method(:preflight!) { true }
      launcher.define_singleton_method(:launch) { |record, claim_capability:| launches << record; { "claimed" => true } }
      dispatcher = Hive::Attempts::Dispatcher.new(store: store, launcher: launcher, capability_generator: -> { "c" * 64 })
      parent = dispatcher.dispatch(task: task, project: "demo", intended_stage: stage, argv: [ "hive", "run", task.slug ], request_id: "parent", provider: "claude").attempt
      owner = { "pid" => Process.pid, "start_fingerprint" => Hive::Lock.process_start_time(Process.pid), "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
      parent = store.claim(parent, owner: owner, claim_capability: "c" * 64, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
      parent = store.first_heartbeat(parent, stale_sec: 30, now: Time.now.utc)
      yield task, store, dispatcher, parent, launches
    end
  end
end

class TaskCapabilitiesActorRunnerTest
  def test_graceful_exit_zero_after_enforced_stop_cannot_pass_a_capability
    %w[timeout parent_cancelled budget_exhausted].each do |reason|
      with_actor_attempt do |task, store, _dispatcher, parent, _launches|
        context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
        session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 5, parent: context)
        binding = pinned_binding({}).merge("timeout_sec" => 1)
        accept_binding(task, binding)
        launcher = lambda do |_task, spawn_control:, **|
          reader, writer = IO.pipe
          pid = Process.spawn(RbConfig.ruby, "-e", "$stdout.sync = true; trap('TERM') { exit 0 }; puts 'ready'; sleep 30", pgroup: true, out: writer, err: File::NULL)
          writer.close
          reader.gets
          reader.close
          spawn_control.attach(pid)
          if reason != "timeout"
            sleep 0.05
            reason == "parent_cancelled" ? spawn_control.cancel! : spawn_control.observe_cost!(1)
          end
          _pid, status = Process.wait2(pid)
          { status: :ok, exit_code: status.exitstatus, final_message: "partial guidance after enforced stop", actual_provider: "anthropic", actual_model: "approved" }
        end
        runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: {}, session: session, context: context, store: store, launcher: launcher)
        result = runner.run(binding, prompt: "bounded guidance")
        assert_equal 0, result.fetch(:exit_code)
        assert_equal :error, result.fetch(:status)
        assert_equal reason, result.fetch(:error_reason)
      ensure
        context&.close
      end
    end
  end
end

class TaskCapabilitiesActorRunnerTest
  def test_scalar_and_mapping_read_only_and_yolo_presets_share_the_same_narrow_specialist_scope
    [ "read-only", "yolo" ].each do |preset|
      with_actor_attempt do |task, store, _dispatcher, parent, _launches|
        context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0)
        session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: nil, timeout_sec: 5, parent: context)
        binding = pinned_binding({}).merge("permissions" => { "preset" => preset })
        accept_binding(task, binding)
        scopes = []
        launcher = lambda do |_task, runtime_policy:, **|
          scopes << runtime_policy.allowed_tools
          { status: :ok, actual_provider: "anthropic", actual_model: "approved" }
        end
        runner = Hive::TaskCapabilities::ActorRunner.new(task: task, cfg: {}, session: session, context: context, store: store, launcher: launcher)
        assert_equal :ok, runner.run(binding, prompt: "bounded specialist").fetch(:status)
        assert_equal [ Hive::PermissionScope::READ_ONLY_ALLOWED.sort ], scopes
      ensure
        context&.close
      end
    end
  end

  def test_parent_scope_mismatch_never_registers_or_launches_a_child
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      [ { task_id: "another-task" }, { task_slug: "another-slug" }, { stage: "review" } ].each do |identity|
        error = assert_raises(Hive::Attempts::RepositoryError) do
          store.with_capability_spawn(attempt_id: parent.attempt_id, spawn_id: "wrong-parent", route: {}, accounts: {}, **identity) { flunk "mismatched child launched" }
        end
        assert_includes error.message, "task or stage differs"
      end
      refute store.fetch(parent.attempt_id)["diagnostics"].key?("capability_spawns")
    end
  end

  def test_exact_account_and_launch_binding_cannot_admit_an_incompatible_runtime
    actor = { "profile" => "claude", "provider" => "anthropic", "model" => "approved", "provider_account" => "local" }
    [ [ "codex", [ "approved" ] ], [ "claude", [ "another-model" ] ] ].each do |adapter, models|
      account = Hive::ProviderRouting::Account.new(id: "local", adapter: adapter, launch_binding: "default", models: models, max_concurrent: 1, cooldown_sec: {})
      cfg = { Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY => { account.id => account } }
      error = assert_raises(Hive::ConfigError) { Hive::ProviderRouting::Configuration.capability_route(cfg: cfg, actor: actor) }
      assert_includes error.message, "does not support its pinned profile and model"
    end
    error = assert_raises(Hive::ConfigError) do
      Hive::ProviderRouting::Configuration.capability_route(cfg: {}, actor: actor.except("provider_account").merge("launch_binding" => "another-binding"))
    end
    assert_includes error.message, "launch binding changed or is unavailable"
    envelope = { "capability" => "security", "actor" => actor, "permissions" => { "tools" => [ "Read" ] }, "targets" => [ "local" ], "budget_usd" => 1, "timeout_sec" => 5 }
    error = assert_raises(Hive::ConfigError) do
      Hive::TaskCapabilities::Policy.new({}, catalog: Hive::TaskCapabilities::Catalog.new(workflow: Hive::Workflows::Coding::DESCRIPTOR), approvals: { "local" => envelope })
    end
    assert_includes error.message, "requires its exact launch_binding alongside provider_account"
  end

  def test_hook_rewrite_preserves_tool_options_and_malformed_policy_fails_closed
    with_tmp_dir do |root|
      policy = Hive::WorkflowPackage::RuntimePolicy.compile({ "tools" => [ "Bash" ], "commands" => [ "ruby check.rb" ] }, task_folder: root,
        profile: Hive::AgentProfiles.lookup(:claude), policy_dir: File.join(root, "policy"), isolated_commands: true)
      input = { "tool_name" => "Bash", "tool_input" => { "command" => "ruby check.rb", "timeout" => 100, "description" => "approved check" } }
      output = StringIO.new
      Hive::Scripts::WorkflowPolicyHook.run(policy.policy_path, input: StringIO.new(JSON.generate(input)), output: output)
      response = JSON.parse(output.string).fetch("hookSpecificOutput")
      assert_equal "allow", response.fetch("permissionDecision")
      assert_equal 100, response.dig("updatedInput", "timeout")
      assert_equal "approved check", response.dig("updatedInput", "description")
      assert_equal [ "/usr/bin/sh", "-c", "ruby check.rb" ], Shellwords.split(response.dig("updatedInput", "command")).last(3)
      File.write(policy.policy_path, "malformed")
      _out, error = capture_io do
        failure = assert_raises(SystemExit) { Hive::Scripts::WorkflowPolicyHook.run(policy.policy_path, input: StringIO.new("{}")) }
        assert_equal 2, failure.status
      end
      assert_includes error, "policy hook failed"
    ensure
      policy&.cleanup!
    end
  end

  def test_primary_spawn_receives_remaining_session_limits_and_keeps_ordinary_admitted_route
    with_actor_attempt do |task, store, _dispatcher, parent, _launches|
      binary = File.join(task.project_root, "primary-fixture")
      File.write(binary, <<~SCRIPT)
        #!/usr/bin/ruby
        require 'json'
        File.write('primary-argv.json', JSON.generate(ARGV))
        puts JSON.generate(type: 'result', subtype: 'success', model: 'primary', result: 'complete', total_cost_usd: 0.1)
      SCRIPT
      File.chmod(0o755, binary)
      task.define_singleton_method(:log_dir) { File.join(folder, "logs") }
      cfg = { "agents" => { "claude" => { "bin" => binary } } }
      context = Hive::Attempts::Context.send(:new, attempt_id: parent.attempt_id, task_generation: 0, intended_stage: "4-execute",
        routing: { "mode" => "explicit", "route" => { "adapter" => "claude", "model" => "primary", "effort" => "low", "provider_account_id" => nil,
          "launch_binding_id" => "default", "billing_route" => "subscription", "billing_evidence_source" => "profile" } })
      session = Hive::TaskCapabilities::ActorRunner::Session.new(budget_usd: 2, timeout_sec: 5, parent: context)
      child = session.reserve!(budget_usd: 1, timeout_sec: 5)
      session.settle!(child, { status: :ok, usage: { cost: 0.25 } })
      probe = Hive::AgentRuntime::ProbeResult.new(provider: :claude, launcher_identity: binary, version: "2.1.316", capability_evidence: [])
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        invalid = assert_raises(ArgumentError) do
          Hive::Stages::Base.spawn_agent(task, prompt: "invalid", max_budget_usd: 2, timeout_sec: 5, cfg: cfg, capability_invocation: Object.new)
        end
        assert_includes invalid.message, "does not belong to this parent attempt"
        with_replaced_singleton_method(Hive::AgentRuntime, :prepare!, ->(*) { probe }) do
          with_replaced_singleton_method(Hive::UsageDb, :record!, ->(**) {}) do
            result = Hive::Stages::Base.spawn_agent(task, prompt: "primary", max_budget_usd: 2, timeout_sec: 30,
              profile: Hive::AgentProfiles.lookup(:codex), cfg: cfg, model: "unadmitted", capability_session: session, status_mode: :exit_code_only)
            assert_equal :ok, result.fetch(:status)
            assert_equal "primary", result.fetch(:actual_model)
          end
        end
      end
      argv = JSON.parse(File.read(File.join(task.folder, "primary-argv.json")))
      assert_equal "1.75", argv[argv.index("--max-budget-usd") + 1]
      assert_equal "primary", argv[argv.index("--model") + 1]
      assert_equal "low", argv[argv.index("--effort") + 1]
      assert_equal 0, session.remaining_budget
      assert_raises(Hive::TaskCapabilities::Admission::Error) { session.primary_limits(budget_usd: 2, timeout_sec: 5) }
    ensure
      context&.close
    end
  end
end
