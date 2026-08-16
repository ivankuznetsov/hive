require "test_helper"
require "hive/refactor_patrol/claim_liveness_resolver"

class RefactorPatrolClaimLivenessResolverTest < Minitest::Test
  include HiveTestHelper

  def test_matching_live_child_remains_unresolved_without_termination
    claim = {
      "pid" => 4242,
      "pgid" => 4242,
      "process_start_time" => "boot-live"
    }
    resolver = Hive::RefactorPatrol::ClaimLivenessResolver.new

    with_replaced_singleton_method(
      Hive::ProcessKill, :valid_target_pid?, ->(_pid) { true }
    ) do
      with_replaced_singleton_method(
        Hive::ProcessKill, :pid_alive?, ->(_pid) { true }
      ) do
        with_replaced_singleton_method(
          Hive::ProcessKill, :process_start_time, ->(_pid) { "boot-live" }
        ) do
          with_replaced_singleton_method(Process, :getpgid, ->(_pid) { 4242 }) do
            assert_equal :unresolved, resolver.call(claim)
          end
        end
      end
    end
  end

  def test_missing_identity_is_unresolved_and_reused_identity_is_resolved
    resolver = Hive::RefactorPatrol::ClaimLivenessResolver.new
    assert_equal :unresolved, resolver.call({})

    claim = {
      "pid" => 4242,
      "pgid" => 4242,
      "process_start_time" => "boot-old"
    }
    with_replaced_singleton_method(
      Hive::ProcessKill, :valid_target_pid?, ->(_pid) { true }
    ) do
      with_replaced_singleton_method(
        Hive::ProcessKill, :pid_alive?, ->(_pid) { true }
      ) do
        with_replaced_singleton_method(
          Hive::ProcessKill, :process_start_time, ->(_pid) { "boot-new" }
        ) do
          assert_equal :resolved, resolver.call(claim)
        end
      end
    end
  end

  def test_uninspectable_live_process_group_remains_unresolved
    claim = {
      "pid" => 4242,
      "pgid" => 4242,
      "process_start_time" => "boot-live"
    }
    resolver = Hive::RefactorPatrol::ClaimLivenessResolver.new

    with_replaced_singleton_method(
      Hive::ProcessKill, :valid_target_pid?, ->(_pid) { true }
    ) do
      with_replaced_singleton_method(
        Hive::ProcessKill, :pid_alive?, ->(_pid) { true }
      ) do
        with_replaced_singleton_method(
          Hive::ProcessKill, :process_start_time, ->(_pid) { "boot-live" }
        ) do
          with_replaced_singleton_method(
            Process, :getpgid, ->(_pid) { raise Errno::EPERM }
          ) do
            assert_equal :unresolved, resolver.call(claim)
          end
        end
      end
    end
  end

  def test_invalid_owner_pid_remains_unresolved
    resolver = Hive::RefactorPatrol::ClaimLivenessResolver.new
    claim = {
      "pid" => nil,
      "owner_pid" => 1,
      "owner_process_start_time" => "boot-live"
    }

    assert_equal :unresolved, resolver.call(claim)
  end
end
