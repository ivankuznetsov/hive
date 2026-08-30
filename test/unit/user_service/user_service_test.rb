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

  def test_apply_rejects_a_forged_force_decision
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "operator-owned\n")
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })
      valid = service.plan(autostart: false, force: false)
      forged = Hive::UserService::Plan.new(
        operation: :apply,
        action: :replace,
        definition_fingerprint: valid.definition_fingerprint,
        expected_observation: valid.expected_observation,
        status: valid.status,
        manager_observed: valid.manager_observed,
        autostart: valid.autostart,
        force: valid.force
      )

      error = assert_raises(ArgumentError) { service.apply(forged) }

      assert_match(/decision does not match/, error.message)
      assert_equal "operator-owned\n", File.read(path)
      assert_empty Dir["#{path}.bak-*"]
      assert_empty calls & MUTATING_COMMANDS
    end
  end

  def test_apply_does_not_mutate_an_unavailable_systemd_manager
    with_tmp_dir do |dir|
      calls = []
      service = Hive::UserService.new(
        definition: service_definition(dir),
        runner: ->(argv) { calls << argv; true },
        query_available: true,
        manager_available: false
      )

      result = service.apply(service.plan(autostart: true))

      assert_equal :autostart_unavailable, result.kind
      assert result.success?
      assert_equal "desired\n", File.read(definition_path(dir))
      assert_includes result.diagnostics, :autostart_unavailable
      assert_empty calls & MUTATING_COMMANDS
    end
  end

  def test_failed_replacement_reports_the_completed_backup
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "operator-owned\n")
      writer = Object.new
      writer.define_singleton_method(:write) do |target, content, mode:|
        raise IOError, "target replacement failed" if target == path

        Hive::AtomicFile.write(target, content, mode: mode)
      end
      service = Hive::UserService.new(
        definition: service_definition(dir),
        runner: ->(_argv) { true },
        writer: writer,
        clock: -> { Time.utc(2026, 7, 26, 1, 2, 3) }
      )

      result = service.apply(service.plan(autostart: false, force: true))

      assert_equal :failed, result.kind
      assert_equal "#{path}.bak-20260726T010203Z", result.backup_path
      assert_equal "operator-owned\n", File.read(result.backup_path)
      assert_equal "operator-owned\n", File.read(path)
      assert_includes result.diagnostics, :backup_written
      assert_includes result.diagnostics, :write_failed
      assert_equal "IOError", result.error_class
    end
  end

  def test_manager_failure_restores_and_verifies_the_prior_state
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "custom\n")
      calls = []
      restart_attempts = 0
      running = true
      runner = lambda do |argv|
        calls << argv
        case argv
        when %w[systemctl --user restart hive-test]
          restart_attempts += 1
          running = restart_attempts > 1
        when %w[systemctl --user is-active --quiet hive-test]
          running
        else
          true
        end
      end
      service = build_service(dir, runner: runner)

      result = service.apply(service.plan(autostart: true, force: true))

      assert_equal :failed, result.kind
      refute result.success?
      assert result.restarted
      assert_equal "custom\n", File.read(path)
      assert result.backup_path
      assert_equal 2, restart_attempts
      assert_equal 1, Dir["#{path}.bak-*"].length
      assert_equal :drifted, result.final_status.content_state
      assert_includes result.diagnostics, :systemd_apply_failed
      assert_includes result.diagnostics, :prior_state_restored
      assert_empty pending_journals(dir)
    end
  end

  def test_manager_mutate_then_fail_is_finalized_from_fresh_observation
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "custom\n")
      calls = []
      runner = lambda do |argv|
        calls << argv
        if argv == %w[systemctl --user restart hive-test]
          false
        else
          true
        end
      end
      service = build_service(dir, runner: runner)

      result = service.apply(service.plan(autostart: true, force: true))

      assert_equal :upgraded, result.kind
      assert result.success?
      assert_equal "desired\n", File.read(path)
      assert_equal :matching, result.final_status.content_state
      assert_includes result.diagnostics, :systemd_apply_failed
      assert_includes result.diagnostics, :manager_effect_verified
      assert_empty pending_journals(dir)
    end
  end

  def test_matching_legacy_unit_reconciles_once_then_receipt_makes_reapply_a_noop
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })

      first = service.apply(service.plan(autostart: true))
      mutating_after_first = calls & MUTATING_COMMANDS
      second = build_service(dir, runner: ->(argv) { calls << argv; true })
        .then { |fresh| fresh.apply(fresh.plan(autostart: true)) }

      assert_equal :unchanged, first.kind
      assert first.restarted
      assert_includes mutating_after_first, %w[systemctl --user restart hive-test]
      assert_equal :unchanged, second.kind
      refute second.restarted
      assert_equal mutating_after_first, calls & MUTATING_COMMANDS
      assert_equal 1, applied_receipts(dir).length
      assert_empty pending_journals(dir)
    end
  end

  def test_autostart_disabled_receipt_reconciles_manager_exactly_once_when_enabled_later
    with_tmp_dir do |dir|
      calls = []
      disabled = build_service(dir, runner: ->(argv) { calls << argv; true })

      first = disabled.apply(disabled.plan(autostart: false))
      assert_equal :written, first.kind
      assert_empty calls & MUTATING_COMMANDS

      enabled = build_service(dir, runner: ->(argv) { calls << argv; true })
      second = enabled.apply(enabled.plan(autostart: true))
      mutating_after_second = calls & MUTATING_COMMANDS
      third = build_service(dir, runner: ->(argv) { calls << argv; true })
        .then { |fresh| fresh.apply(fresh.plan(autostart: true)) }

      assert_equal :unchanged, second.kind
      assert_includes mutating_after_second, %w[systemctl --user enable --now hive-test]
      assert_equal :unchanged, third.kind
      assert_equal mutating_after_second, calls & MUTATING_COMMANDS
    end
  end

  def test_fixed_clock_sequential_upgrades_use_distinct_exclusive_backups
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "first\n")
      clock = -> { Time.utc(2026, 7, 26, 1, 2, 3) }
      first = build_service(dir, runner: ->(_argv) { true }, clock: clock)
      first_result = first.apply(first.plan(autostart: false, force: true))

      File.write(path, "second\n")
      second = build_service(dir, runner: ->(_argv) { true }, clock: clock)
      second_result = second.apply(second.plan(autostart: false, force: true))

      refute_equal first_result.backup_path, second_result.backup_path
      assert_equal "first\n", File.read(first_result.backup_path)
      assert_equal "second\n", File.read(second_result.backup_path)
      assert_equal 2, Dir["#{path}.bak-*"].length
    end
  end

  def test_invalid_pending_journal_fails_closed_without_mutation
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "operator-owned\n")
      FileUtils.mkdir_p(coordination_root(dir), mode: 0o700)
      digest = Digest::SHA256.hexdigest(File.expand_path(path))
      journal = File.join(coordination_root(dir), "#{digest}.journal.json")
      File.write(journal, "{not-json")
      File.chmod(0o600, journal)
      calls = []
      service = build_service(dir, runner: ->(argv) { calls << argv; true })

      result = service.apply(service.plan(autostart: true, force: true))

      assert_equal :failed, result.kind
      assert_equal "operator-owned\n", File.read(path)
      assert File.exist?(journal)
      assert_includes result.diagnostics, :invalid_recovery_state
      assert_empty calls & MUTATING_COMMANDS
    end
  end

  def test_impossible_pending_journal_phase_fails_closed_and_is_preserved
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "legacy\n")
      crashing = build_service(
        dir,
        runner: ->(_argv) { true },
        event_handler: lambda do |event, _definition|
          raise "simulated interruption" if event == :after_journal_prepared
        end
      )
      interrupted = crashing.apply(crashing.plan(autostart: true, force: true))
      journal = pending_journals(dir).fetch(0)
      document = JSON.parse(File.read(journal))
      document["phase"] = "removal_verified"
      File.write(journal, JSON.generate(document) + "\n")

      calls = []
      fresh = build_service(dir, runner: ->(argv) { calls << argv; true })
      result = fresh.apply(fresh.plan(autostart: true, force: true))

      assert_equal :failed, interrupted.kind
      assert_equal :failed, result.kind
      assert_includes result.diagnostics, :invalid_recovery_state
      assert_equal "legacy\n", File.read(path)
      assert_equal "removal_verified", JSON.parse(File.read(journal)).fetch("phase")
      assert_empty calls & MUTATING_COMMANDS
    end
  end

  def test_fresh_instance_replays_recorded_restart_without_a_second_backup
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "legacy\n")
      calls = []
      crashing = build_service(
        dir,
        runner: ->(argv) { calls << argv; true },
        event_handler: lambda do |event, _definition|
          raise "simulated interruption" if event == :after_unit_published
        end
      )

      interrupted = crashing.apply(crashing.plan(autostart: true, force: true))
      assert_equal :failed, interrupted.kind
      assert_equal "desired\n", File.read(path)
      assert_equal 1, Dir["#{path}.bak-*"].length
      assert_equal 1, pending_journals(dir).length
      refute_includes calls, %w[systemctl --user restart hive-test]

      fresh = build_service(dir, runner: ->(argv) { calls << argv; true })
      recovered = fresh.apply(fresh.plan(autostart: true))

      assert_equal :upgraded, recovered.kind
      assert recovered.restarted
      assert_equal 1, calls.count { |argv| argv == %w[systemctl --user restart hive-test] }
      assert_equal 1, Dir["#{path}.bak-*"].length
      assert_empty pending_journals(dir)
      assert_equal 1, applied_receipts(dir).length
    end
  end

  def test_fresh_instance_finalizes_verified_activation_without_restarting_again
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "legacy\n")
      calls = []
      crashing = build_service(
        dir,
        runner: ->(argv) { calls << argv; true },
        event_handler: lambda do |event, _definition|
          raise "simulated interruption" if event == :after_activated
        end
      )

      interrupted = crashing.apply(crashing.plan(autostart: true, force: true))
      assert_equal :failed, interrupted.kind
      assert_equal 1, calls.count { |argv| argv == %w[systemctl --user restart hive-test] }
      assert_equal 1, pending_journals(dir).length

      fresh = build_service(dir, runner: ->(argv) { calls << argv; true })
      recovered = fresh.apply(fresh.plan(autostart: true))

      assert_equal :upgraded, recovered.kind
      assert_equal 1, calls.count { |argv| argv == %w[systemctl --user restart hive-test] }
      assert_empty pending_journals(dir)
    end
  end

  def test_live_target_lock_returns_busy_without_unit_or_manager_mutation_then_retries
    with_tmp_dir do |dir|
      calls = []
      holder = build_service(dir, runner: ->(_argv) { true })
      contender = build_service(
        dir,
        runner: ->(argv) { calls << argv; true },
        lock_wait: 0.03
      )
      ready = Queue.new
      release = Queue.new
      holder_transaction = holder.instance_variable_get(:@transaction)
      thread = Thread.new do
        holder_transaction.with_lock do
          ready << true
          release.pop
        end
      end
      ready.pop

      busy = contender.apply(contender.plan(autostart: true))
      assert_equal :failed, busy.kind
      assert_includes busy.diagnostics, :operation_busy
      remove_busy = contender.remove(contender.plan_remove)
      purge_busy = contender.purge(contender.plan_remove)
      start_busy = contender.start
      [ remove_busy, purge_busy, start_busy ].each do |blocked|
        assert_equal :failed, blocked.kind
        assert_includes blocked.diagnostics, :operation_busy
      end
      refute File.exist?(definition_path(dir))
      assert_empty pending_journals(dir)
      assert_empty calls & MUTATING_COMMANDS

      release << true
      thread.join
      retried = contender.apply(contender.plan(autostart: true))
      assert_equal :written, retried.kind
      assert_equal "desired\n", File.read(definition_path(dir))
    ensure
      release << true if thread&.alive?
      thread&.join
    end
  end

  def test_lifecycle_operations_share_the_target_owner_and_verify_running_state
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      running = false
      calls = []
      runner = lambda do |argv|
        calls << argv
        case argv
        when %w[systemctl --user start hive-test], %w[systemctl --user restart hive-test]
          running = true
        when %w[systemctl --user stop hive-test]
          running = false
          true
        when %w[systemctl --user is-active --quiet hive-test]
          running
        else
          true
        end
      end
      service = build_service(dir, runner: runner)

      started = service.start
      restarted = service.restart
      stopped = service.stop

      assert started.success?
      assert started.final_status.running?
      assert restarted.success?
      assert restarted.restarted
      assert stopped.success?
      refute stopped.final_status.running?
      assert_includes calls, %w[systemctl --user start hive-test]
      assert_includes calls, %w[systemctl --user restart hive-test]
      assert_includes calls, %w[systemctl --user stop hive-test]
    end
  end

  def test_removal_replays_after_interruption_without_restoring_the_unit
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      enabled = true
      running = true
      runner = lambda do |argv|
        case argv
        when %w[systemctl --user disable --now hive-test]
          enabled = false
          running = false
          true
        when %w[systemctl --user is-enabled hive-test]
          enabled
        when %w[systemctl --user is-active --quiet hive-test]
          running
        else
          true
        end
      end
      crashing = build_service(
        dir,
        runner: runner,
        event_handler: lambda do |event, _definition|
          raise "simulated removal interruption" if event == :after_unit_removed
        end
      )

      interrupted = crashing.remove(crashing.plan_remove)
      assert_equal :failed, interrupted.kind
      refute File.exist?(path)
      assert_equal 1, pending_journals(dir).length

      fresh = build_service(dir, runner: runner)
      recovered = fresh.remove(fresh.plan_remove)

      assert_equal :absent, recovered.kind
      refute File.exist?(path)
      assert_empty pending_journals(dir)
      assert_empty applied_receipts(dir)
    end
  end

  def test_manager_availability_is_tri_state_and_indeterminate_refuses_before_unit_mutation
    with_tmp_dir do |dir|
      calls = []
      service = Hive::UserService.new(
        definition: service_definition(dir),
        runner: ->(argv) { calls << argv; true },
        query_available: true,
        manager_available: :indeterminate,
        home: dir
      )

      status = service.inspect
      result = service.apply(service.plan(autostart: true))

      assert_equal :indeterminate, status.manager_availability
      assert_equal :failed, result.kind
      assert_includes result.diagnostics, :manager_probe_indeterminate
      refute File.exist?(definition_path(dir))
      assert_empty pending_journals(dir)
      assert_empty calls & MUTATING_COMMANDS
    end
  end

  def test_symlinked_target_lock_fails_closed_and_is_preserved
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })
      transaction = service.instance_variable_get(:@transaction)
      transaction.with_lock { nil }
      external = File.join(dir, "foreign-lock")
      File.write(external, "foreign\n")
      File.unlink(transaction.lock_path)
      File.symlink(external, transaction.lock_path)

      result = service.apply(service.plan(autostart: true))

      assert_equal :failed, result.kind
      assert_includes result.diagnostics, :invalid_recovery_state
      assert File.symlink?(transaction.lock_path)
      assert_equal "foreign\n", File.read(external)
      refute File.exist?(definition_path(dir))
    end
  end

  def test_unprovable_holder_record_fails_closed_and_is_preserved
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })
      transaction = service.instance_variable_get(:@transaction)
      transaction.with_lock { nil }
      holder = {
        "pid" => Process.pid,
        "boot_id" => File.read("/proc/sys/kernel/random/boot_id").strip,
        "process_start" => "unavailable",
        "target_path" => definition_path(dir),
        "acquired_at" => Time.now.utc.iso8601(6)
      }
      File.write(transaction.lock_path, JSON.generate(holder) + "\n")
      File.chmod(0o600, transaction.lock_path)

      result = service.apply(service.plan(autostart: true))

      assert_equal :failed, result.kind
      assert_includes result.diagnostics, :invalid_recovery_state
      assert_equal holder, JSON.parse(File.read(transaction.lock_path))
      refute File.exist?(definition_path(dir))
    end
  end

  def test_dead_holder_record_is_reclaimed_after_identity_proof
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })
      transaction = service.instance_variable_get(:@transaction)
      transaction.with_lock { nil }
      holder = {
        "pid" => 2_147_483_647,
        "boot_id" => File.read("/proc/sys/kernel/random/boot_id").strip,
        "process_start" => "123",
        "target_path" => definition_path(dir),
        "acquired_at" => Time.now.utc.iso8601(6)
      }
      File.write(transaction.lock_path, JSON.generate(holder) + "\n")
      File.chmod(0o600, transaction.lock_path)

      result = service.apply(service.plan(autostart: false))

      assert_equal :written, result.kind
      assert result.success?
      assert_equal "", File.read(transaction.lock_path)
      assert_equal "desired\n", File.read(definition_path(dir))
    end
  end

  def test_durable_rollback_direction_never_flips_back_to_forward_recovery
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "legacy\n")
      running = true
      first_restart = true
      runner = lambda do |argv|
        case argv
        when %w[systemctl --user restart hive-test]
          if first_restart
            first_restart = false
            running = false
            false
          else
            running = true
          end
        when %w[systemctl --user is-active --quiet hive-test]
          running
        else
          true
        end
      end
      crashing = build_service(
        dir,
        runner: runner,
        event_handler: lambda do |event, _definition|
          raise "simulated rollback interruption" if event == :after_rollback_selected
        end
      )

      interrupted = crashing.apply(crashing.plan(autostart: true, force: true))
      assert_equal :failed, interrupted.kind
      document = JSON.parse(File.read(pending_journals(dir).fetch(0)))
      assert_equal "rollback", document.fetch("direction")
      assert_equal "rollback_selected", document.fetch("phase")
      assert_equal "desired\n", File.read(path)

      fresh = build_service(dir, runner: runner)
      recovered = fresh.apply(fresh.plan(autostart: true))

      assert_equal :failed, recovered.kind
      assert_includes recovered.diagnostics, :prior_state_restored
      assert_equal "legacy\n", File.read(path)
      assert_empty pending_journals(dir)
    end
  end

  def test_manager_loss_after_publication_retains_intent_until_a_later_replay
    with_tmp_dir do |dir|
      availability = :available
      calls = []
      service = Hive::UserService.new(
        definition: service_definition(dir),
        runner: ->(argv) { calls << argv; true },
        query_available: true,
        manager_available: -> { availability },
        home: dir,
        event_handler: lambda do |event, _definition|
          availability = :indeterminate if event == :after_unit_published
        end
      )

      pending = service.apply(service.plan(autostart: true))
      assert_equal :failed, pending.kind
      assert_includes pending.diagnostics, :recovery_pending
      assert_equal "desired\n", File.read(definition_path(dir))
      assert_equal 1, pending_journals(dir).length
      assert_empty calls & MUTATING_COMMANDS

      availability = :available
      fresh = Hive::UserService.new(
        definition: service_definition(dir),
        runner: ->(argv) { calls << argv; true },
        query_available: true,
        manager_available: -> { availability },
        home: dir
      )
      recovered = fresh.apply(fresh.plan(autostart: true))

      assert_equal :written, recovered.kind
      assert_includes calls, %w[systemctl --user enable --now hive-test]
      assert_empty pending_journals(dir)
    end
  end

  def test_apply_wraps_writer_failures_without_exposing_the_message
    with_tmp_dir do |dir|
      writer = Object.new
      writer.define_singleton_method(:write) do |*_args|
        raise IOError, "secret=do-not-surface"
      end
      service = Hive::UserService.new(
        definition: service_definition(dir),
        runner: ->(_argv) { true },
        writer: writer
      )

      result = service.apply(service.plan(autostart: false))

      assert_equal :failed, result.kind
      assert_equal "IOError", result.error_class
      assert_equal :absent, result.final_status.content_state
      assert_includes result.diagnostics, :write_failed
      refute_respond_to result, :error_message
    end
  end

  def test_manager_probe_failure_is_a_typed_status_diagnostic
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { raise "probe failed" })

      status = service.inspect

      refute status.manager_available?
      refute status.enabled?
      refute status.running?
      assert_includes status.diagnostics, :manager_probe_failed
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
      pending = reload_failure.remove(reload_failure.plan_remove)
      assert_equal :failed, pending.kind
      refute File.exist?(path)
      assert_includes pending.diagnostics, :daemon_reload_failed
      assert_includes pending.diagnostics, :recovery_pending
      assert_equal :absent, pending.final_status.content_state
    end
  end

  def test_remove_detects_a_file_change_after_manager_disable
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      runner = lambda do |argv|
        File.write(path, "operator changed this\n") if argv == %w[systemctl --user disable --now hive-test]
        true
      end
      service = build_service(dir, runner: runner)

      result = service.remove(service.plan_remove)

      assert_equal :failed, result.kind
      assert_equal "operator changed this\n", File.read(path)
      assert_includes result.diagnostics, :stale_after_manager_change
      assert_includes result.diagnostics, :recovery_pending
      assert_equal :drifted, result.final_status.content_state
    end
  end

  def test_remove_treats_a_concurrently_disappearing_file_as_removed
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      enabled = true
      running = true
      service = build_service(
        dir,
        runner: lambda do |argv|
          if argv == %w[systemctl --user disable --now hive-test]
            enabled = false
            running = false
            true
          elsif argv == %w[systemctl --user is-enabled hive-test]
            enabled
          elsif argv == %w[systemctl --user is-active --quiet hive-test]
            running
          else
            true
          end
        end
      )
      original_unlink = File.method(:unlink)

      result = with_replaced_singleton_method(
        File,
        :unlink,
        lambda do |target|
          original_unlink.call(target)
          raise Errno::ENOENT
        end
      ) do
        service.remove(service.plan_remove)
      end

      assert_equal :removed, result.kind
      assert_equal :absent, result.final_status.content_state
    end
  end

  def test_remove_wraps_boundary_exceptions_as_typed_results
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })
      plan = service.plan_remove

      service.define_singleton_method(:remove_current) { |_candidate, _transaction| raise Errno::ENOENT }
      absent = service.remove(plan)
      assert_equal :absent, absent.kind

      service.define_singleton_method(:remove_current) { |_candidate, _transaction| raise IOError, "hidden" }
      failed = service.remove(plan)
      assert_equal :failed, failed.kind
      assert_equal "IOError", failed.error_class
      assert_includes failed.diagnostics, :remove_failed
    end
  end

  def test_remove_retains_recovery_evidence_after_unlink_failure
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

      assert_equal :failed, result.kind
      assert File.exist?(path)
      refute result.final_status.enabled?
      assert_equal "Errno::EACCES", result.error_class
      refute_respond_to result, :error_message
      assert_includes result.diagnostics, :remove_failed
      assert_includes result.diagnostics, :recovery_pending
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

  def test_apply_refuses_an_unsafe_path_without_following_it
    with_tmp_dir do |dir|
      path = definition_path(dir)
      target = File.join(dir, "operator.service")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(target, "keep\n")
      File.symlink(target, path)
      service = build_service(dir, runner: ->(_argv) { true })

      plan = service.plan(autostart: false)
      result = service.apply(plan)

      assert_equal :unsafe, plan.action
      assert_equal :unsafe_path, result.kind
      assert_equal "keep\n", File.read(target)
      assert File.symlink?(path)
    end
  end

  def test_inspect_classifies_nofollow_and_permission_failures
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      service = build_service(dir, runner: ->(_argv) { true })

      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::ELOOP }) do
        status = service.inspect
        assert_equal :unsafe, status.content_state
        assert_includes status.diagnostics, :unsafe_unit_path
      end

      with_replaced_singleton_method(File, :open, ->(*_args) { raise Errno::EACCES }) do
        status = service.inspect
        assert_equal :unreadable, status.content_state
        assert_includes status.diagnostics, :unit_unreadable
      end
    end
  end

  def test_force_apply_stops_if_the_bound_source_disappears
    with_tmp_dir do |dir|
      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "operator-owned\n")
      service = build_service(dir, runner: ->(_argv) { true })
      original_read = service.method(:read_regular_file)
      reads = 0
      service.define_singleton_method(:read_regular_file) do
        reads += 1
        raise Errno::ENOENT if reads == 3

        original_read.call
      end

      result = service.apply(service.plan(autostart: false, force: true))

      assert_equal :stale, result.kind
      assert_equal "operator-owned\n", File.read(path)
      assert_empty Dir["#{path}.bak-*"]
    end
  end

  def test_safe_inspect_degrades_unexpected_observation_failure_to_nil
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })

      with_replaced_singleton_method(File, :lstat, ->(_path) { raise IOError }) do
        assert_nil service.send(:safe_inspect)
      end
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

  def test_unsupported_manager_actions_are_safe_noops
    definition = Hive::UserService::Definition.new(
      platform: :unsupported,
      service_name: "hive-test",
      target_path: nil,
      content: nil
    )
    manager = Hive::UserService::Manager.new(
      definition: definition,
      runner: ->(_argv) { raise "must not run" },
      query_available: false,
      manager_available: false
    )

    installed = manager.apply_intent(:enable)
    disabled = manager.disable

    assert installed.ok
    refute installed.restarted
    assert disabled.ok
    refute disabled.restarted
  end

  def test_manager_action_timeout_tracks_the_units_slow_stop_contract
    definition = Hive::UserService::Definition.new(
      platform: :linux,
      service_name: "hive-test",
      target_path: "/tmp/hive-test.service",
      content: "[Service]\nTimeoutStopSec=900s\n"
    )
    manager = Hive::UserService::Manager.new(
      definition: definition,
      runner: ->(_argv) { true },
      query_available: true,
      manager_available: true
    )

    assert_equal 905, manager.send(:manager_action_timeout_sec)
  end

  def test_launchd_default_status_reader_handles_success_and_missing_binary
    with_tmp_dir do |dir|
      definition = Hive::UserService::Definition.new(
        platform: :macos,
        service_name: "hive-test",
        target_path: File.join(dir, "local.hive-test.plist"),
        content: "desired\n"
      )
      manager = Hive::UserService::Manager.new(
        definition: definition,
        runner: ->(_argv) { true },
        query_available: true,
        manager_available: true
      )
      successful_status = Data.define(:success?).new(true)

      with_replaced_singleton_method(Open3, :capture2e, ->(*_argv) { [ "state = running\n", successful_status ] }) do
        inspection = manager.inspect
        assert inspection.running
      end

      with_replaced_singleton_method(Open3, :capture2e, ->(*_argv) { raise Errno::ENOENT }) do
        inspection = manager.inspect
        refute inspection.running
        assert_empty inspection.diagnostics
      end
    end
  end

  def test_value_objects_reject_invalid_contracts_and_classify_drift
    assert_raises(ArgumentError) do
      Hive::UserService::Definition.new(
        platform: :linux,
        service_name: "hive-test",
        target_path: nil,
        content: "desired\n"
      )
    end

    assert_raises(ArgumentError) do
      Hive::UserService::Status.new(
        platform: :linux,
        unit_path: "/tmp/hive-test.service",
        content_state: :unknown,
        file_identity: nil,
        manager_available: false,
        enabled: false,
        running: false
      )
    end

    status = status_fixture
    assert_raises(ArgumentError) do
      Hive::UserService::Plan.new(
        operation: :apply,
        action: :write,
        definition_fingerprint: "definition",
        expected_observation: status.observation_key,
        status: Object.new
      )
    end
    assert_raises(ArgumentError) do
      Hive::UserService::Plan.new(
        operation: :apply,
        action: :write,
        definition_fingerprint: "definition",
        expected_observation: "not-the-status-observation",
        status: status
      )
    end

    assert Hive::UserService::Result.new(:drifted).drifted?
    refute Hive::UserService::Result.new(:written).drifted?
  end

  def test_invalid_or_cross_operation_plans_raise_argument_error
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })

      assert_raises(ArgumentError) { service.apply(Object.new) }
      assert_raises(ArgumentError) { service.remove(service.plan(autostart: false)) }
      assert_raises(ArgumentError) { service.apply(service.plan_remove) }

      status = service.inspect
      other_service = Hive::UserService.new(
        definition: Hive::UserService::Definition.new(
          platform: :linux,
          service_name: "other-service",
          target_path: definition_path(dir),
          content: "desired\n"
        )
      )
      assert_raises(ArgumentError) { other_service.apply(service.plan(autostart: false)) }
      assert_raises(ArgumentError) do
        Hive::UserService::Plan.new(
          operation: :apply,
          action: :remove,
          definition_fingerprint: "definition",
          expected_observation: status.observation_key,
          status: status
        )
      end

      path = definition_path(dir)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "desired\n")
      valid_remove = service.plan_remove
      forged_remove = Hive::UserService::Plan.new(
        operation: :remove,
        action: valid_remove.action,
        definition_fingerprint: valid_remove.definition_fingerprint,
        expected_observation: valid_remove.expected_observation,
        status: valid_remove.status,
        manager_observed: false
      )
      assert_raises(ArgumentError) { service.remove(forged_remove) }
      assert File.exist?(path)
    end
  end

  def test_apply_current_defensively_rejects_an_unvalidated_action
    with_tmp_dir do |dir|
      service = build_service(dir, runner: ->(_argv) { true })
      forged_plan = Struct.new(:action, :autostart).new(:bogus, false)

      error = assert_raises(ArgumentError) do
        service.send(:apply_current, forged_plan, service.inspect)
      end

      assert_match(/unsupported user service action :bogus/, error.message)
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

  def build_service(dir, runner:, clock: -> { Time.now.utc }, **kwargs)
    Hive::UserService.new(
      definition: service_definition(dir),
      runner: runner,
      query_available: true,
      manager_available: true,
      home: dir,
      clock: clock,
      **kwargs
    )
  end

  def coordination_root(dir)
    File.join(dir, ".local/state/hive/user-service")
  end

  def pending_journals(dir)
    Dir[File.join(coordination_root(dir), "*.journal.json")]
  end

  def applied_receipts(dir)
    Dir[File.join(coordination_root(dir), "*.receipt.json")]
  end

  def service_definition(dir)
    Hive::UserService::Definition.new(
      platform: :linux,
      service_name: "hive-test",
      target_path: definition_path(dir),
      content: "desired\n"
    )
  end

  def status_fixture
    Hive::UserService::Status.new(
      platform: :linux,
      unit_path: "/tmp/hive-test.service",
      content_state: :absent,
      file_identity: nil,
      manager_available: false,
      enabled: false,
      running: false
    )
  end

  def read_only_command?(argv)
    argv[0, 3] == %w[systemctl --user is-enabled] ||
      argv[0, 4] == %w[systemctl --user is-active --quiet] ||
      argv == %w[systemctl --user show-environment]
  end
end
