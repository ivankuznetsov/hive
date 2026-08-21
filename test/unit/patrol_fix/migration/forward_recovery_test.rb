require "test_helper"
require "tmpdir"
require "hive/patrol_fix/migration/forward_recovery"

class PatrolFixMigrationForwardRecoveryTest < Minitest::Test
  def test_pristine_preflight_rollback_does_not_touch_the_owner_epoch
    state = Object.new
    state.define_singleton_method(:rollback_allowed?) { true }
    state.define_singleton_method(:read) do
      {
        "status" => "preflight", "source_epochs" => { "ordinary_patrol" => 7 },
        "fenced_source_epochs" => nil, "source_ownership" => {}
      }
    end
    state.define_singleton_method(:rollback!) do |source_epochs:, now:|
      [ source_epochs, now ]
    end
    epochs = Object.new
    epochs.define_singleton_method(:rollback!) { |**| raise "must not advance epoch" }
    recovery = Hive::PatrolFix::Migration::ForwardRecovery.new(
      state: state, epoch_port: epochs, applier: -> { flunk },
      clock: -> { Time.utc(2026, 8, 21, 2) }
    )

    assert_equal [ { "ordinary_patrol" => 7 }, Time.utc(2026, 8, 21, 2) ],
                 recovery.rollback!
  end

  def test_rolls_back_only_before_effect_and_recovers_forward_after_effect_arm
    state = Object.new
    state.define_singleton_method(:rollback_allowed?) { true }
    epochs = Object.new
    epochs.define_singleton_method(:rollback!) do |expected:, ownership:|
      raise "missing expected epochs" unless expected == { "ordinary_patrol" => 8 }
      raise "missing ownership" unless ownership.fetch("ordinary_patrol").fetch("admission")
      { "ordinary_patrol" => 9 }
    end
    state.define_singleton_method(:fenced_source_epochs) do
      { "ordinary_patrol" => 8 }
    end
    state.define_singleton_method(:read) do
      { "status" => "fenced", "fenced_source_epochs" => { "ordinary_patrol" => 8 },
        "source_ownership" => {
        "ordinary_patrol" => { "owner" => "legacy", "admission" => true }
      } }
    end
    state.define_singleton_method(:rollback!) do |source_epochs:, now:|
      [ source_epochs, now ]
    end
    applier = Object.new
    applier.define_singleton_method(:call) { flunk "rollback must not apply" }

    recovery = Hive::PatrolFix::Migration::ForwardRecovery.new(
      state: state, epoch_port: epochs, applier: applier,
      clock: -> { Time.utc(2026, 8, 21, 3) }
    )
    assert_equal [ { "ordinary_patrol" => 9 }, Time.utc(2026, 8, 21, 3) ],
                 recovery.rollback!

    state.define_singleton_method(:rollback_allowed?) { false }
    applier.define_singleton_method(:call) { { "status" => "committed" } }
    assert_raises(Hive::PatrolFix::Migration::CutoverState::ForwardOnly) do
      recovery.rollback!
    end
    assert_equal "committed", recovery.call.fetch("status")
  end
end
