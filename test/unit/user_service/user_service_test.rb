require "test_helper"
require "hive/user_service"

class UserServiceTest < Minitest::Test
  include HiveTestHelper

  MUTATING_COMMANDS = [
    %w[systemctl --user daemon-reload],
    %w[systemctl --user enable --now hive-test],
    %w[systemctl --user restart hive-test],
    %w[systemctl --user disable --now hive-test]
  ].freeze

  def test_inspect_and_plan_are_side_effect_free
    with_tmp_dir do |dir|
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; false })

      status = service.inspect
      plan = service.plan(autostart: true)

      assert_equal :absent, status.content_state
      assert_equal :write, plan.action
      refute File.exist?(definition_path(dir))
      assert_empty calls & MUTATING_COMMANDS
      assert calls.all? { |argv| read_only_command?(argv) },
             "inspect/plan issued a mutating manager call: #{calls.inspect}"
    end
  end

  def test_inspect_distinguishes_matching_drifted_and_manager_state
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      calls = []
      runner = lambda do |argv|
        calls << argv
        argv == %w[systemctl --user is-enabled hive-test]
      end
      service = build_service(dir, runner: runner)

      File.write(path, "desired\n")
      matching = service.inspect
      assert_equal :matching, matching.content_state
      assert matching.installed?
      assert matching.enabled?
      refute matching.running?
      assert matching.manager_available?

      File.write(path, "custom\n")
      drifted = service.inspect
      assert_equal :drifted, drifted.content_state
      refute_equal matching.observation_key, drifted.observation_key
      assert calls.all? { |argv| read_only_command?(argv) }
    end
  end

  def test_apply_writes_and_enables_from_a_revalidated_plan
    with_tmp_dir do |dir|
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })

      result = service.apply(service.plan(autostart: true))

      assert_equal :written, result.kind
      assert result.success?
      assert_equal "desired\n", File.read(definition_path(dir))
      assert_includes calls, %w[systemctl --user daemon-reload]
      assert_includes calls, %w[systemctl --user enable --now hive-test]
      assert_equal :matching, result.final_status.content_state
    end
  end

  def test_drift_is_refused_without_force
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "operator-owned\n")
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })

      plan = service.plan(autostart: true)
      result = service.apply(plan)

      assert_equal :refuse_drift, plan.action
      assert_equal :drifted, result.kind
      refute result.success?
      assert_equal "operator-owned\n", File.read(path)
      assert_empty calls & MUTATING_COMMANDS
      assert_includes result.diagnostics, :drift_detected
    end
  end

  def test_apply_refuses_a_stale_plan_before_mutation
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "first-customization\n")
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })
      plan = service.plan(autostart: true, force: true)

      File.write(path, "changed-after-plan\n")
      result = service.apply(plan)

      assert_equal :stale, result.kind
      refute result.success?
      assert_equal "changed-after-plan\n", File.read(path)
      assert_empty Dir["#{path}.bak-*"]
      assert_empty calls & MUTATING_COMMANDS
      assert_includes result.diagnostics, :stale_plan
    end
  end

  def test_apply_refuses_a_stale_manager_observation_before_mutation
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      enabled = true
      calls = []
      runner = lambda do |argv|
        calls << argv
        if argv == %w[systemctl --user is-enabled hive-test]
          enabled
        elsif read_only_command?(argv)
          false
        else
          true
        end
      end
      service = build_service(dir, runner: runner)
      plan = service.plan(autostart: true)

      enabled = false
      result = service.apply(plan)

      assert_equal :stale, result.kind
      assert_equal "desired\n", File.read(path)
      assert_empty calls & MUTATING_COMMANDS
      assert_includes result.diagnostics, :stale_plan
    end
  end

  def test_force_apply_backs_up_and_atomically_replaces_drift
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "operator-owned\n")
      calls = []
      service = build_service(
        dir,
        runner: ->(argv) { calls << argv; true },
        clock: -> { Time.utc(2026, 7, 26, 1, 2, 3) }
      )

      result = service.apply(service.plan(autostart: true, force: true))

      assert_equal :upgraded, result.kind
      assert result.success?
      assert result.restarted
      assert_equal "desired\n", File.read(path)
      assert_equal "#{path}.bak-20260726T010203Z", result.backup_path
      assert_equal "operator-owned\n", File.read(result.backup_path)
      assert_empty Dir["#{path}.tmp.*"]
      assert_includes calls, %w[systemctl --user restart hive-test]
    end
  end

  def test_partial_manager_failure_returns_typed_final_observed_state
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "custom\n")
      calls = []
      runner = lambda do |argv|
        calls << argv
        argv != %w[systemctl --user restart hive-test]
      end
      service = build_service(dir, runner: runner)

      result = service.apply(service.plan(autostart: true, force: true))

      assert_equal :partial, result.kind
      refute result.success?
      assert result.restarted
      assert_equal "desired\n", File.read(path)
      assert result.backup_path
      assert_equal :matching, result.final_status.content_state
      assert_includes result.diagnostics, :systemd_apply_failed
    end
  end

  def test_manager_system_call_failure_stays_a_typed_partial_result
    with_tmp_dir do |dir|
      path = definition_path(dir)
      service = build_service(
        dir,
        runner: lambda do |argv|
          raise Errno::EACCES, "blocked" if argv == %w[systemctl --user enable --now hive-test]

          true
        end
      )

      result = service.apply(service.plan(autostart: true))

      assert_equal :partial, result.kind
      assert_equal "desired\n", File.read(path)
      assert_equal :matching, result.final_status.content_state
      assert_includes result.diagnostics, :systemd_apply_failed
      refute_includes result.diagnostics, :write_failed
    end
  end

  def test_remove_is_idempotent_and_reports_manager_and_reload_failures
    with_tmp_dir do |dir|
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })

      absent = service.remove(service.plan_remove)
      assert_equal :absent, absent.kind
      assert absent.success?
      assert_empty calls & MUTATING_COMMANDS

      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      failing = build_service(
        dir,
        runner: lambda do |argv|
          calls << argv
          argv != %w[systemctl --user disable --now hive-test]
        end
      )
      manager_failure = failing.remove(failing.plan_remove)
      assert_equal :failed, manager_failure.kind
      assert File.exist?(path)
      assert_includes manager_failure.diagnostics, :manager_disable_failed

      reload_failure = build_service(
        dir,
        runner: lambda do |argv|
          calls << argv
          argv != %w[systemctl --user daemon-reload]
        end
      )
      partial = reload_failure.remove(reload_failure.plan_remove)
      assert_equal :partial, partial.kind
      refute File.exist?(path)
      assert_includes partial.diagnostics, :daemon_reload_failed
      assert_equal :absent, partial.final_status.content_state
    end
  end

  def test_remove_reports_unlink_failure_as_partial_after_manager_disable
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      enabled = true
      calls = []
      runner = lambda do |argv|
        calls << argv
        if argv == %w[systemctl --user is-enabled hive-test]
          enabled
        elsif argv == %w[systemctl --user disable --now hive-test]
          enabled = false
          true
        else
          true
        end
      end
      service = build_service(dir, runner: runner)

      result = with_replaced_singleton_method(
        File,
        :unlink,
        ->(_path) { raise Errno::EACCES, "secret=do-not-surface" }
      ) do
        service.remove(service.plan_remove)
      end

      assert_equal :partial, result.kind
      assert File.exist?(path)
      refute result.final_status.enabled?
      assert_equal "Errno::EACCES", result.error_class
      refute_respond_to result, :error_message
      assert_includes result.diagnostics, :remove_failed
      assert_includes calls, %w[systemctl --user disable --now hive-test]
    end
  end

  def test_remove_refuses_a_symlink_without_following_it
    with_tmp_dir do |dir|
      path = definition_path(dir)
      target = File.join(dir, "operator.service")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(target, "keep\n")
      File.symlink(target, path)
      service = build_service(dir, runner: ->(_argv) { true })

      result = service.remove(service.plan_remove)

      assert_equal :unsafe_path, result.kind
      assert File.symlink?(path)
      assert_equal "keep\n", File.read(target)
      assert_includes result.diagnostics, :unsafe_unit_path
    end
  end

  def test_unsupported_platform_never_writes_or_invokes_a_manager
    calls = []
    definition = Hive::UserService::Definition.new(
      platform: :unsupported,
      service_name: "hive-test",
      target_path: nil,
      content: nil
    )
    service = Hive::UserService.new(
      definition: definition,
      runner: ->(argv) { calls << argv; true }
    )

    status = service.inspect
    result = service.apply(service.plan(autostart: true))

    assert_equal :unsupported, status.platform
    assert_equal :unsupported, result.kind
    assert result.success?
    assert_empty calls
  end

  def test_invalid_or_cross_operation_plans_raise_argument_error
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })

      assert_raises(ArgumentError) { service.apply(Object.new) }
      assert_raises(ArgumentError) { service.remove(service.plan(autostart: false)) }
      assert_raises(ArgumentError) { service.apply(service.plan_remove) }

      status = service.inspect
      assert_raises(ArgumentError) do
        Hive::UserService::Plan.new(
          operation: :apply,
          action: :remove,
          definition_fingerprint: "definition",
          expected_observation: status.observation_key,
          status: status
        )
      end
    end
  end

  def test_remove_only_definition_rejects_apply_planning
    with_tmp_dir do |dir|
      definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-test",
        target_path: definition_path(dir),
        content: nil
      )
      service = Hive::UserService.new(definition: definition)

      assert_raises(ArgumentError) { service.plan(autostart: false) }
      assert_equal :absent, service.remove(service.plan_remove).kind
    end
  end

  private

  def definition_path(dir)
    File.join(dir, ".config/systemd/user/hive-test.service")
  end

  def build_service(dir, runner:, clock: -> { Time.now.utc })
    definition = Hive::UserService::Definition.new(
      platform: :linux,
      service_name: "hive-test",
      target_path: definition_path(dir),
      content: "desired\n"
    )
    Hive::UserService.new(
      definition: definition,
      runner: runner,
      query_available: true,
      manager_available: true,
      clock: clock
    )
  end

  def read_only_command?(argv)
    argv[0, 3] == %w[systemctl --user is-enabled] ||
      argv[0, 4] == %w[systemctl --user is-active --quiet] ||
      argv == %w[systemctl --user show-environment]
  end
end
