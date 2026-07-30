require "test_helper"
require "hive/refactor_patrol/claim_maintenance_transitions"

class HiveRefactorPatrolClaimMaintenanceTransitionsTest < Minitest::Test
  class RecordingStore
    attr_reader :calls

    def initialize
      @calls = []
    end

    def attach_discovery_process!(token, **options)
      @calls << [ :attach_discovery, token, options ]
      :attached
    end

    def renew_discovery_claim!(token, **options)
      @calls << [ :renew_discovery, token, options ]
      :discovery
    end

    def renew_action_claim!(token, **options)
      @calls << [ :renew_action, token, options ]
      :action
    end
  end

  def setup
    @transitions = Hive::RefactorPatrol::ClaimMaintenanceTransitions.new
    @store = RecordingStore.new
    @now = Time.utc(2026, 7, 28, 12, 0, 0)
  end

  def test_attaches_discovery_process_through_the_operational_port
    token = { kind: :discovery, generation: 2 }

    result = @transitions.attach_discovery(
      store: @store,
      token: token,
      pid: 123,
      process_start_time: "start",
      pgid: 123,
      now: @now,
      lease_sec: 600
    )

    assert_equal :attached, result
    assert_equal(
      [
        :attach_discovery,
        token,
        {
          pid: 123,
          process_start_time: "start",
          pgid: 123,
          now: @now,
          lease_sec: 600
        }
      ],
      @store.calls.fetch(0)
    )
  end

  def test_renews_each_supported_claim_kind
    resolver = ->(_claim) { :unresolved }

    discovery = @transitions.renew(
      store: @store,
      token: { kind: :discovery, generation: 2 },
      now: @now,
      lease_sec: 600,
      claim_resolver: resolver
    )
    action = @transitions.renew(
      store: @store,
      token: { kind: :action, generation: 4 },
      now: @now,
      lease_sec: 600,
      claim_resolver: resolver
    )

    assert_equal :discovery, discovery
    assert_equal :action, action
    assert_equal %i[renew_discovery renew_action],
                 @store.calls.map(&:first)
  end

  def test_rejects_unknown_claim_kind_without_mutating_the_store
    assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      @transitions.renew(
        store: @store,
        token: { kind: :unknown, generation: 1 },
        now: @now,
        lease_sec: 600,
        claim_resolver: nil
      )
    end

    assert_empty @store.calls
  end
end
