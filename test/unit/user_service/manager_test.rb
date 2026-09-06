require "test_helper"
require "hive/user_service/definition"
require "hive/user_service/manager"

class UserServiceManagerTest < Minitest::Test
  def test_inspection_rejects_unknown_availability
    error = assert_raises(ArgumentError) do
      Hive::UserService::Manager::Inspection.new(
        availability: :maybe,
        enabled: false,
        running: false
      )
    end

    assert_match(/unknown manager availability/, error.message)
  end

  def test_restore_covers_enabled_stopped_and_unsupported_endpoints
    calls = []
    manager = build_manager(:linux, runner: ->(argv) { calls << argv; true })

    restored = manager.restore(prior_enabled: true, prior_running: false)

    assert restored.ok
    assert_equal [
      %w[systemctl --user daemon-reload],
      %w[systemctl --user enable hive-test],
      %w[systemctl --user stop hive-test]
    ], calls

    calls.clear
    disabled = manager.restore(prior_enabled: false, prior_running: false)
    assert disabled.ok
    assert_equal [
      %w[systemctl --user daemon-reload],
      %w[systemctl --user disable --now hive-test]
    ], calls

    launchd_calls = []
    launchd = build_manager(:macos, runner: ->(argv) { launchd_calls << argv; true })
      .restore(prior_enabled: true, prior_running: false)
    assert launchd.ok
    assert_equal [
      [ "launchctl", "unload", "/tmp/hive-test.plist" ],
      [ "launchctl", "load", "/tmp/hive-test.plist" ]
    ], launchd_calls

    unsupported = build_manager(:unsupported, query_available: false, manager_available: false)
      .restore(prior_enabled: false, prior_running: false)
    assert unsupported.ok
    refute unsupported.restarted
  end

  def test_unavailable_apply_and_lifecycle_actions_fail_without_a_command
    calls = []
    manager = build_manager(
      :linux,
      runner: ->(argv) { calls << argv; true },
      manager_available: false
    )

    apply = manager.apply_intent(:enable)
    start = manager.start

    refute apply.ok
    assert_includes apply.diagnostics, :autostart_unavailable
    refute start.ok
    assert_includes start.diagnostics, :manager_action_unavailable
    assert_empty calls
  end

  def test_macos_and_unsupported_lifecycle_commands
    calls = []
    manager = build_manager(:macos, runner: ->(argv) { calls << argv; true })

    assert manager.start.ok
    assert manager.stop.ok
    assert manager.disable.ok
    assert_equal [
      [ "launchctl", "load", "/tmp/hive-test.plist" ],
      [ "launchctl", "unload", "/tmp/hive-test.plist" ],
      [ "launchctl", "unload", "/tmp/hive-test.plist" ]
    ], calls

    unsupported = build_manager(:unsupported)
    assert unsupported.start.ok
  end

  def test_unknown_manager_state_is_indeterminate
    manager = build_manager(:linux, manager_available: :unknown)

    inspection = manager.inspect

    assert_equal :indeterminate, inspection.availability
    assert_includes inspection.diagnostics, :manager_probe_failed
  end

  def test_systemd_inspection_captures_loaded_definition_and_process_identity
    calls = []
    manager = build_manager(
      :linux,
      status_reader: lambda do |argv|
        calls << argv
        [ systemd_status, true ]
      end
    )

    inspection = manager.inspect

    assert_equal :available, inspection.availability
    assert inspection.enabled
    assert inspection.running
    assert_equal :loaded, inspection.load_state
    assert_equal "/tmp/hive-test.service", inspection.fragment_path
    refute inspection.need_daemon_reload
    assert_equal 42, inspection.main_pid
    assert_equal "123456", inspection.process_start
    assert inspection.loaded_definition?("/tmp/hive-test.service")
    assert_empty inspection.diagnostics
    assert_equal 1, calls.length
    assert_equal %w[systemctl --user show], calls.first.first(3)
    assert_includes calls.first, "--no-pager"
    assert_includes calls.first, "hive-test"

    stale = build_manager(
      :linux,
      status_reader: ->(_argv) { [ systemd_status(need_daemon_reload: "yes"), true ] }
    ).inspect
    refute stale.loaded_definition?("/tmp/hive-test.service")
  end

  def test_systemd_inspection_preserves_deactivating_state_and_live_main_pid
    manager = build_manager(
      :linux,
      status_reader: lambda do |_argv|
        [
          systemd_status(
            active_state: "deactivating",
            main_pid: "123",
            process_start: "draining"
          ),
          true
        ]
      end
    )

    inspection = manager.inspect

    refute inspection.running
    assert_equal :deactivating, inspection.active_state
    assert_equal 123, inspection.main_pid
  end

  def test_systemd_inspection_propagates_query_failures_as_indeterminate
    manager = build_manager(
      :linux,
      status_reader: ->(_argv) { [ "Failed to connect to bus\n", false ] }
    )

    inspection = manager.inspect

    assert_equal :indeterminate, inspection.availability
    refute inspection.enabled
    refute inspection.running
    assert_includes inspection.diagnostics, :manager_probe_failed
  end

  def test_systemd_inspection_treats_missing_command_as_conclusively_absent
    manager = build_manager(
      :linux,
      status_reader: ->(_argv) { raise Errno::ENOENT }
    )

    inspection = manager.inspect

    assert_equal :conclusively_absent, inspection.availability
    refute inspection.enabled
    refute inspection.running
  end

  def test_systemd_inspection_accepts_a_conclusive_missing_unit
    manager = build_manager(
      :linux,
      status_reader: lambda do |_argv|
        [ systemd_status(
          load_state: "not-found",
          fragment_path: "",
          need_daemon_reload: "no",
          unit_file_state: "",
          active_state: "inactive",
          main_pid: "0",
          process_start: "0"
        ), false ]
      end
    )

    inspection = manager.inspect

    assert_equal :available, inspection.availability
    refute inspection.enabled
    refute inspection.running
    assert_equal :not_found, inspection.load_state
    assert_nil inspection.fragment_path
    assert_empty inspection.diagnostics
  end

  def test_reload_and_activation_are_separate_and_restart_enables_first
    calls = []
    manager = build_manager(:linux, runner: ->(argv) { calls << argv; true })

    reload = manager.reload
    activation = manager.activate(:restart)

    assert reload.ok
    assert activation.ok
    assert activation.restarted
    assert_equal [
      %w[systemctl --user daemon-reload],
      %w[systemctl --user enable hive-test],
      %w[systemctl --user restart hive-test]
    ], calls
  end

  def test_apply_intent_does_not_activate_when_reload_fails
    calls = []
    manager = build_manager(
      :linux,
      runner: lambda do |argv|
        calls << argv
        argv != %w[systemctl --user daemon-reload]
      end
    )

    action = manager.apply_intent(:enable)

    refute action.ok
    assert_includes action.diagnostics, :systemd_apply_failed
    assert_equal [ %w[systemctl --user daemon-reload] ], calls
  end

  def test_apply_intent_compatibility_wrapper_covers_each_platform
    linux_calls = []
    linux = build_manager(:linux, runner: ->(argv) { linux_calls << argv; true })
    assert linux.apply_intent(:enable).ok
    assert_equal [
      %w[systemctl --user daemon-reload],
      %w[systemctl --user enable --now hive-test]
    ], linux_calls

    macos_calls = []
    macos = build_manager(:macos, runner: ->(argv) { macos_calls << argv; true })
    assert macos.apply_intent(:enable).ok
    assert_equal [ [ "launchctl", "load", "/tmp/hive-test.plist" ] ], macos_calls

    assert build_manager(:unsupported).apply_intent(:enable).ok
    assert build_manager(:unsupported).activate(:enable).ok
    unavailable = build_manager(
      :linux,
      manager_available: -> { raise "probe failed" }
    ).activate(:restart)
    refute unavailable.ok
    assert unavailable.restarted
    assert_includes unavailable.diagnostics, :autostart_unavailable
  end

  def test_inspection_rescues_missing_probe_and_rejects_invalid_systemd_properties
    missing = build_manager(
      :linux,
      query_available: -> { raise Errno::ENOENT }
    ).inspect
    assert_equal :conclusively_absent, missing.availability

    invalid = build_manager(
      :linux,
      status_reader: ->(_argv) { [ systemd_status(need_daemon_reload: "maybe"), true ] }
    ).inspect
    assert_equal :indeterminate, invalid.availability
    assert_includes invalid.diagnostics, :manager_probe_failed
  end

  def test_multi_command_actions_stop_after_the_first_failure
    calls = []
    manager = build_manager(
      :macos,
      runner: lambda do |argv|
        calls << argv
        false
      end
    )

    action = manager.restart

    refute action.ok
    assert_includes action.diagnostics, :manager_action_failed
    assert_equal [ [ "launchctl", "unload", "/tmp/hive-test.plist" ] ], calls
  end

  def test_production_runner_terminates_and_reaps_a_timed_out_child
    manager = build_manager(:linux, runner: nil)
    command = manager.send(
      :run_production,
      [ "/bin/sh", "-c", "echo $$; exec sleep 30" ],
      timeout: 0.2
    )

    refute command.ok
    assert_equal :timeout, command.failure
    pid = Integer(command.output.lines.first)
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_production_runner_classifies_missing_and_internal_failures
    manager = build_manager(:linux, runner: nil)

    missing = manager.send(:run_production, [ "/definitely/missing/hive-command" ], timeout: 0.1)
    refute missing.ok
    assert_equal :missing, missing.failure

    failed = manager.send(:run_production, [ "/bin/true" ], timeout: Object.new)
    refute failed.ok
    assert_equal :failed, failed.failure

    assert manager.send(:run_injected_or_production_query, [ "/bin/true" ]).ok
    assert manager.send(:run_launchd_status_command, [ "/bin/true" ]).ok
    assert manager.send(:run_query_command, [ "/bin/true" ]).ok
    assert manager.send(:run_action_command, [ "/bin/true" ]).ok

    injected = build_manager(:linux, runner: ->(_argv) { true })
    assert injected.send(:run_query_command, [ "ignored" ]).ok
  end

  def test_production_cleanup_escalates_and_tolerates_already_reaped_processes
    manager = build_manager(:linux, runner: nil)
    reader, writer = IO.pipe
    pid = Process.spawn(
      "/bin/sh", "-c", 'trap "" TERM; echo ready; exec sleep 30',
      out: writer,
      pgroup: true
    )
    writer.close
    assert_equal "ready\n", reader.gets

    status = manager.send(:terminate_and_reap, pid)
    assert status.signaled?
    assert_equal Signal.list.fetch("KILL"), status.termsig
    assert_nil manager.send(:terminate_and_reap, pid)
    assert_nil manager.send(:signal_process_group, 999_999_999, "TERM")
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    begin
      Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid) if pid
    rescue Errno::ECHILD
      nil
    end
  end

  def test_command_diagnostics_distinguish_timeout_and_failed_commands
    manager = build_manager(:linux)
    timeout = Hive::UserService::Manager::Command.new(ok: false, failure: :timeout)
    failed = Hive::UserService::Manager::Command.new(ok: false, failure: :failed)

    assert_equal [ :manager_action_timeout ], manager.send(:command_diagnostics, timeout)
    assert_equal [ :manager_command_failed ], manager.send(:command_diagnostics, failed)
  end

  def test_system_call_failures_are_observed_for_queries_and_actions
    manager = build_manager(:linux, runner: ->(_argv) { raise Errno::ENOENT })

    inspection = manager.inspect
    action = manager.start

    refute inspection.enabled
    refute inspection.running
    refute action.ok
    assert_includes action.diagnostics, :manager_action_failed
  end

  def test_invalid_timeout_falls_back_to_the_declared_default
    definition = definition_for(:linux, content: "[Service]\nTimeoutStopSec=forever\n")
    manager = Hive::UserService::Manager.new(
      definition: definition,
      runner: ->(_argv) { true },
      query_available: true,
      manager_available: true
    )

    assert_equal Hive::UserService::Manager::DEFAULT_ACTION_TIMEOUT_SEC,
                 manager.send(:manager_action_timeout_sec)
  end

  def test_action_timeout_uses_the_current_target_being_stopped
    Dir.mktmpdir("hive-manager-timeout") do |dir|
      target = File.join(dir, "hive-test.service")
      File.write(target, "[Service]\nTimeoutStopSec=900s\n")
      definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-test",
        target_path: target,
        content: "[Service]\nTimeoutStopSec=30s\n"
      )
      manager = Hive::UserService::Manager.new(
        definition: definition,
        runner: ->(_argv) { true },
        query_available: true,
        manager_available: true
      )

      assert_equal 905, manager.send(:manager_action_timeout_sec)
    end
  end

  private

  def build_manager(platform, runner: ->(_argv) { true }, query_available: true,
                    manager_available: true, status_reader: nil)
    Hive::UserService::Manager.new(
      definition: definition_for(platform),
      runner: runner,
      query_available: query_available,
      manager_available: manager_available,
      status_reader: status_reader,
      launchd_running_via_list: true
    )
  end

  def systemd_status(load_state: "loaded", fragment_path: "/tmp/hive-test.service",
                     need_daemon_reload: "no", unit_file_state: "enabled",
                     active_state: "active", main_pid: "42", process_start: "123456")
    <<~STATUS
      LoadState=#{load_state}
      FragmentPath=#{fragment_path}
      NeedDaemonReload=#{need_daemon_reload}
      UnitFileState=#{unit_file_state}
      ActiveState=#{active_state}
      MainPID=#{main_pid}
      ExecMainStartTimestampMonotonic=#{process_start}
    STATUS
  end

  def definition_for(platform, content: "desired\n")
    Hive::UserService::Definition.new(
      platform: platform,
      service_name: "hive-test",
      launchd_label: "local.hive-test",
      target_path: case platform
                   when :linux then "/tmp/hive-test.service"
                   when :macos then "/tmp/hive-test.plist"
                   end,
      content: platform == :unsupported ? nil : content
    )
  end
end
