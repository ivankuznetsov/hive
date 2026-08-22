require_relative "../../test_helper"
require "hive/refactor_patrol/discovery_transitions"

class RefactorPatrolDiscoveryTransitionsTest < Minitest::Test
  NOW = Time.utc(2026, 8, 21, 12)

  class RecordingStore
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(name, *arguments, **options)
      @calls << [ name, arguments, options ]
      name
    end

    def respond_to_missing?(*, **) = true
  end

  def setup
    @store = RecordingStore.new
    @subject = Hive::RefactorPatrol::DiscoveryTransitions.new(
      owner: "daemon-1", owner_pid: 42, owner_process_start_time: "start",
      lease_sec: 120, claim_resolver: ->(*) { :resolved },
      claim_liveness_resolver: ->(*) { :resolved }
    )
  end

  def test_claims_directly
    aggregate = { "job_id" => "job-1", "attempts" => [] }
    assert_equal :claim_discovery!, @subject.claim(
      entry: {}, store: @store, aggregate: aggregate,
      analysis_sha: "a" * 40, now: NOW
    )
    name, arguments, options = @store.calls.fetch(0)
    assert_equal :claim_discovery!, name
    assert_equal [ "job-1" ], arguments
    assert_equal "daemon-1", options.fetch(:owner)
    assert_equal false, options.fetch(:allow_unexpired_recovery)
  end

  def test_resolves_inactive_unexpired_claim
    aggregate = {
      "job_id" => "job-1",
      "attempts" => [
        { "kind" => "discovery_claim", "state" => "running",
          "expires_at" => (NOW + 60).iso8601 }
      ]
    }
    assert_equal :claim_discovery!, @subject.claim(
      store: @store, aggregate: aggregate, analysis_sha: "a" * 40, now: NOW
    )
    assert @store.calls.fetch(0).fetch(2).fetch(:allow_unexpired_recovery)
  end

  def test_unresolved_claim_is_not_replaced
    subject = Hive::RefactorPatrol::DiscoveryTransitions.new(
      owner: "daemon-1", owner_pid: 42, owner_process_start_time: "start",
      lease_sec: 120, claim_resolver: ->(*) { :unresolved },
      claim_liveness_resolver: ->(*) { raise "probe failed" }
    )
    aggregate = {
      "job_id" => "job-1",
      "attempts" => [
        { "kind" => "discovery_claim", "state" => "claimed",
          "expires_at" => (NOW + 60).iso8601 }
      ]
    }

    assert_nil subject.claim(
      store: @store, aggregate: aggregate, analysis_sha: "a" * 40, now: NOW
    )
  end

  def test_forwards_completion_and_block_transitions
    token = { job_id: "job-1" }
    aggregate = { "job_id" => "job-1" }
    assert_equal :release_discovery!, @subject.release(store: @store, token: token, reason: "failed", now: NOW, backoff_sec: 60)
    assert_equal :checkpoint_discovery!, @subject.checkpoint(store: @store, token: token, envelope: {}, now: NOW, backoff_sec: 60)
    assert_equal :checkpoint_discovery_progress!, @subject.checkpoint_progress(store: @store, token: token, envelope: {}, now: NOW, lease_sec: 120)
    assert_equal :block_discovery!, @subject.block(store: @store, aggregate: aggregate, phase: :discovery, reason: "bad", evidence: {}, now: NOW, backoff_sec: 60)
    assert_equal :block_actions!, @subject.block(store: @store, aggregate: aggregate, phase: :action, reason: "bad", evidence: {}, now: NOW, backoff_sec: 60)
    assert_equal :retire_obsolete_source!, @subject.retire(store: @store, aggregate: aggregate, merge_sha: "a", trunk_sha: "b", now: NOW)
    assert_equal %i[
      release_discovery! checkpoint_discovery!
      checkpoint_discovery_progress! block_discovery! block_actions!
      retire_obsolete_source!
    ], @store.calls.map(&:first)
  end
end
