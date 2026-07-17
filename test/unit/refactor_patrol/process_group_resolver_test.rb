require "test_helper"
require "hive/refactor_patrol/process_group_resolver"

class RefactorPatrolProcessGroupResolverTest < Minitest::Test
  include HiveTestHelper

  Result = Struct.new(:killed, :skipped_reason, keyword_init: true)

  def setup
    @resolver = Hive::RefactorPatrol::ProcessGroupResolver.new
  end

  def test_resolves_a_verified_live_process_group_after_termination
    test = self
    stub_process_identity(alive: true, start_time: "123", pgid: 456) do
      replacement = ->(_pid, recorded_start_time:) do
        test.assert_equal "123", recorded_start_time
        Result.new(killed: true)
      end
      with_replaced_singleton_method(Hive::ProcessKill, :terminate_process_group, replacement) do
        assert_equal :resolved, @resolver.call(child_claim)
      end
    end
  end

  def test_treats_a_group_that_disappears_during_termination_as_resolved
    stub_process_identity(alive: true, start_time: "123", pgid: 456) do
      replacement = ->(*) { Result.new(killed: false, skipped_reason: "not_alive") }
      with_replaced_singleton_method(Hive::ProcessKill, :terminate_process_group, replacement) do
        assert_equal :resolved, @resolver.call(child_claim)
      end
    end
  end

  def test_failed_termination_remains_unresolved
    stub_process_identity(alive: true, start_time: "123", pgid: 456) do
      replacement = ->(*) { Result.new(killed: false, skipped_reason: "permission_denied") }
      with_replaced_singleton_method(Hive::ProcessKill, :terminate_process_group, replacement) do
        assert_equal :unresolved, @resolver.call(child_claim)
      end
    end
  end

  def test_child_identity_checks_fail_closed_and_detect_pid_reuse
    assert_equal :unresolved, @resolver.call("pid" => "bad")

    stub_process_identity(alive: false, start_time: nil, pgid: nil) do
      assert_equal :resolved, @resolver.call(child_claim)
    end
    stub_process_identity(alive: true, start_time: nil, pgid: nil) do
      assert_equal :unresolved, @resolver.call(child_claim)
    end
    stub_process_identity(alive: true, start_time: "reused", pgid: nil) do
      assert_equal :resolved, @resolver.call(child_claim)
    end
    stub_process_identity(alive: true, start_time: "123", pgid: 999) do
      assert_equal :unresolved, @resolver.call(child_claim)
    end
  end

  def test_child_lookup_permission_and_disappearance_are_handled
    stub_process_identity(alive: true, start_time: "123", pgid_error: Errno::EPERM) do
      assert_equal :unresolved, @resolver.call(child_claim)
    end
    stub_process_identity(alive: true, start_time: "123", pgid_error: Errno::ESRCH) do
      assert_equal :resolved, @resolver.call(child_claim)
    end
  end

  def test_owner_only_claim_requires_a_matching_live_process_identity
    assert_equal :unresolved, @resolver.call("pid" => nil)

    stub_process_identity(alive: false, start_time: nil, pgid: nil) do
      assert_equal :resolved, @resolver.call(owner_claim)
    end
    stub_process_identity(alive: true, start_time: nil, pgid: nil) do
      assert_equal :unresolved, @resolver.call(owner_claim)
    end
    stub_process_identity(alive: true, start_time: "reused", pgid: nil) do
      assert_equal :resolved, @resolver.call(owner_claim)
    end
    stub_process_identity(alive: true, start_time: "123", pgid: nil) do
      assert_equal :unresolved, @resolver.call(owner_claim)
    end
  end

  private

  def child_claim
    { "pid" => 123, "pgid" => 456, "process_start_time" => "123" }
  end

  def owner_claim
    { "pid" => nil, "owner_pid" => 123, "owner_process_start_time" => "123" }
  end

  def stub_process_identity(alive:, start_time:, pgid: nil, pgid_error: nil)
    test = self
    valid = ->(pid) { pid == 123 }
    alive_check = ->(pid) { test.assert_equal 123, pid; alive }
    start_check = ->(pid) { test.assert_equal 123, pid; start_time }
    pgid_check = lambda do |pid|
      test.assert_equal 123, pid
      raise pgid_error if pgid_error

      pgid
    end
    with_replaced_singleton_method(Hive::ProcessKill, :valid_target_pid?, valid) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, alive_check) do
        with_replaced_singleton_method(Hive::ProcessKill, :process_start_time, start_check) do
          with_replaced_singleton_method(Process, :getpgid, pgid_check) { yield }
        end
      end
    end
  end
end
