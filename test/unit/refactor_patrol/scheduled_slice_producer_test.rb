require "test_helper"
require "hive/refactor_patrol/scheduled_slice_producer"

class RefactorPatrolScheduledSliceProducerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 20, 12)
  SHA1 = "1" * 40
  SHA2 = "2" * 40

  class Snapshots
    attr_reader :calls

    def initialize(*snapshots)
      @snapshots = snapshots
      @calls = 0
    end

    def call(entry:, cfg:)
      raise "missing project" unless entry.fetch("project_id") == "project-1"
      raise "missing config" unless cfg.is_a?(Hash)

      value = @snapshots.fetch([ @calls, @snapshots.size - 1 ].min)
      @calls += 1
      value
    end
  end

  class AdmissionAdapter
    attr_reader :published

    def initialize
      @published = []
    end

    def publish_disposition!(aggregate, disposition)
      @published << [ aggregate, disposition ]
    end
  end

  class FlakyAdmissionAdapter < AdmissionAdapter
    def initialize
      super
      @failures = 1
    end

    def publish_disposition!(aggregate, disposition)
      if @failures.positive?
        @failures -= 1
        raise "admission unavailable"
      end

      super
    end
  end

  def entry(dir)
    {
      "name" => "demo", "project_id" => "project-1", "path" => dir,
      "hive_state_path" => File.join(dir, ".hive-state")
    }
  end

  def snapshot(sha, ids)
    Hive::RefactorPatrol::ScheduledSliceProducer::Snapshot.new(
      analysis_sha: sha, feature_ids: ids
    )
  end

  def producer(dir, snapshots:, admission: AdmissionAdapter.new, ids: nil,
               pid: 101, starts: nil)
    generated = Array(ids || %w[claim-1 claim-2 claim-3]).dup
    starts ||= ->(candidate) { candidate == pid ? "start-#{pid}" : nil }
    [
      Hive::RefactorPatrol::ScheduledSliceProducer.new(
        entry: entry(dir), cfg: {}, snapshotter: snapshots,
        process_start_reader: starts, pid: pid,
        id_generator: -> { generated.shift || "claim-fallback" },
        admission_adapter: admission
      ),
      admission
    ]
  end

  def result(claim, route: "fix")
    disposition = {
      "id" => "thesis-#{claim.fetch('feature_id')}",
      "feature_id" => claim.fetch("feature_id"), "fingerprint" => "fingerprint",
      "route" => route, "admissible" => true, "reasons" => [],
      "thesis" => {
        "id" => "thesis-#{claim.fetch('feature_id')}",
        "feature_id" => claim.fetch("feature_id"),
        "problem" => "duplicated authority", "cost" => "drift",
        "proposed_refactor" => "unify it", "evidence" => [ "lib/a.rb:1" ],
        "feature_boundary" => { "owned_files" => [ "lib/a.rb" ] },
        "required_validation" => { "commands" => [ "bin/test" ] }
      }
    }
    dispositions = { "fix" => [], "discuss" => [], "dismiss" => [] }
    dispositions.fetch(route) << disposition
    {
      "schema" => "hive-refactor-patrol", "schema_version" => 4, "ok" => true,
      "review_complete" => true, "review_errors" => [], "features_mapped" => 1,
      "last_scanned_sha" => claim.fetch("analysis_sha"),
      "feature_results" => [ {
        "feature_id" => claim.fetch("feature_id"), "complete" => true,
        "thesis_ids" => [ disposition.fetch("id") ], "errors" => []
      } ]
    }.merge(dispositions)
  end

  def test_repins_each_claim_and_advances_stable_id_cursor_across_remaps
    with_tmp_dir do |dir|
      snapshots = Snapshots.new(
        snapshot(SHA1, %w[a b]), snapshot(SHA2, %w[b c]),
        snapshot(SHA2, %w[a c])
      )
      subject, = producer(dir, snapshots: snapshots)

      first = subject.claim(now: NOW)
      assert_equal [ SHA1, "a" ], first.values_at("analysis_sha", "feature_id")
      assert_equal 0, first.fetch("sweep_generation")
      assert subject.complete(claim_id: first.fetch("id"), result: result(first), now: NOW)

      second = subject.claim(now: NOW + 60)
      assert_equal [ SHA2, "b" ], second.values_at("analysis_sha", "feature_id")
      assert_equal 0, second.fetch("sweep_generation")
      assert subject.complete(claim_id: second.fetch("id"), result: result(second), now: NOW + 60)

      third = subject.claim(now: NOW + 120)
      assert_equal "c", third.fetch("feature_id"), "removed ids are skipped without resetting"
      assert_equal 0, third.fetch("sweep_generation")
      assert_equal 3, snapshots.calls
    end
  end

  def test_result_is_durable_and_admission_is_published_before_cursor_advances
    with_tmp_dir do |dir|
      snapshots = Snapshots.new(snapshot(SHA1, %w[a]))
      subject, admission = producer(dir, snapshots: snapshots)
      claim = subject.claim(now: NOW)

      assert subject.complete(claim_id: claim.fetch("id"), result: result(claim), now: NOW)
      records = subject.each_result.to_a
      assert_equal 1, records.size
      record = records.fetch(0)
      assert_equal "scheduled", record.dig("source", "lane")
      assert_equal SHA1, record.fetch("analysis_sha")
      assert_equal NOW.iso8601(6), record.fetch("consumed_at")
      assert_equal [ "thesis-a" ], admission.published.map { |_aggregate, item| item.fetch("id") }

      next_claim = subject.claim(now: NOW + 60)
      assert_equal "a", next_claim.fetch("feature_id"), "one-slice maps wrap after completion"
      assert_equal 1, next_claim.fetch("sweep_generation")
      assert subject.complete(
        claim_id: next_claim.fetch("id"), result: result(next_claim), now: NOW + 60
      )
      assert_equal 2, subject.each_result.to_a.size,
                   "a repeated same-SHA slice has a distinct coverage-pass occurrence"
    end
  end

  def test_incomplete_result_cannot_advance_or_publish
    with_tmp_dir do |dir|
      snapshots = Snapshots.new(snapshot(SHA1, %w[a]))
      subject, admission = producer(dir, snapshots: snapshots)
      claim = subject.claim(now: NOW)
      invalid = result(claim).merge("review_complete" => false)

      assert_raises(Hive::ConfigError) do
        subject.complete(claim_id: claim.fetch("id"), result: invalid, now: NOW)
      end
      assert_empty subject.each_result.to_a
      assert_empty admission.published
      refute subject.claim(now: NOW + 1), "the still-live owner retains the failed claim"
    end
  end

  def test_unconsumed_result_replays_before_a_fresh_revision_is_claimed
    with_tmp_dir do |dir|
      admission = FlakyAdmissionAdapter.new
      first, = producer(
        dir, snapshots: Snapshots.new(snapshot(SHA1, %w[a])),
        admission: admission, ids: [ "first" ]
      )
      first_claim = first.claim(now: NOW)

      assert_raises(RuntimeError) do
        first.complete(
          claim_id: first_claim.fetch("id"), result: result(first_claim), now: NOW
        )
      end
      assert_equal 1, first.each_result.to_a.size, "result bytes precede admission"
      assert first.release(claim_id: first_claim.fetch("id"), now: NOW + 1)

      replay, = producer(
        dir, snapshots: Snapshots.new(snapshot(SHA2, %w[b])),
        admission: admission, ids: [ "second" ]
      )
      replay_claim = replay.claim(now: NOW + 60)
      assert_equal [ SHA2, "b" ], replay_claim.values_at("analysis_sha", "feature_id")
      assert_equal [ "thesis-a" ], admission.published.map { |_aggregate, item| item.fetch("id") }
      assert replay.complete(
        claim_id: replay_claim.fetch("id"), result: result(replay_claim), now: NOW + 60
      )

      records = replay.each_result.to_a
      assert_equal 2, records.size
      original = records.find { |record| record.fetch("analysis_sha") == SHA1 }
      assert_equal NOW.iso8601(6), original.fetch("created_at")
      assert_equal NOW.iso8601(6), original.dig("source", "claimed_at")
      assert_equal [ "thesis-a", "thesis-b" ],
                   admission.published.map { |_aggregate, item| item.fetch("id") }
    end
  end

  def test_dead_owner_claim_is_recovered_against_fresh_main
    with_tmp_dir do |dir|
      live = { 101 => "start-101", 202 => "start-202" }
      starts = ->(pid) { live[pid] }
      first, = producer(
        dir, snapshots: Snapshots.new(snapshot(SHA1, %w[a])),
        pid: 101, starts: starts, ids: [ "first" ]
      )
      assert_equal SHA1, first.claim(now: NOW).fetch("analysis_sha")
      live.delete(101)

      recovered, = producer(
        dir, snapshots: Snapshots.new(snapshot(SHA2, %w[b])),
        pid: 202, starts: starts, ids: [ "second" ]
      )
      claim = recovered.claim(now: NOW + 60)
      assert_equal [ SHA2, "b" ], claim.values_at("analysis_sha", "feature_id")
    end
  end

  def test_active_claim_prevents_a_second_provider_slice
    with_tmp_dir do |dir|
      starts = ->(pid) { { 101 => "one", 202 => "two" }[pid] }
      first, = producer(
        dir, snapshots: Snapshots.new(snapshot(SHA1, %w[a])),
        pid: 101, starts: starts
      )
      second, = producer(
        dir, snapshots: Snapshots.new(snapshot(SHA2, %w[b])),
        pid: 202, starts: starts
      )
      assert first.claim(now: NOW)
      refute second.claim(now: NOW + 1)
    end
  end

  def test_completed_results_are_compacted_to_the_bounded_inventory
    with_max_results(1) do
      with_tmp_dir do |dir|
        subject, = producer(dir, snapshots: Snapshots.new(snapshot(SHA1, %w[a])))
        first = subject.claim(now: NOW)
        assert subject.complete(claim_id: first.fetch("id"), result: result(first), now: NOW)

        second = subject.claim(now: NOW + 60)
        assert subject.complete(
          claim_id: second.fetch("id"), result: result(second), now: NOW + 60
        )

        retained = subject.each_result.to_a
        assert_equal 1, retained.size
        assert_equal 1, retained.fetch(0).fetch("sweep_generation")
      end
    end
  end

  def test_replayed_result_becomes_eligible_for_bounded_compaction
    with_max_results(1) do
      with_tmp_dir do |dir|
        subject, = producer(
          dir, snapshots: Snapshots.new(
            snapshot(SHA1, %w[a]), snapshot(SHA2, %w[b])
          ),
          admission: FlakyAdmissionAdapter.new
        )
        first = subject.claim(now: NOW)
        assert_raises(RuntimeError) do
          subject.complete(claim_id: first.fetch("id"), result: result(first), now: NOW)
        end
        assert subject.release(claim_id: first.fetch("id"), now: NOW + 1)

        second = subject.claim(now: NOW + 60)
        assert subject.complete(
          claim_id: second.fetch("id"), result: result(second), now: NOW + 60
        )
        retained = subject.each_result.to_a
        assert_equal 1, retained.size
        assert_equal SHA2, retained.fetch(0).fetch("analysis_sha")
        refute_nil retained.fetch(0).fetch("consumed_at")
      end
    end
  end

  private

  def with_max_results(limit)
    original = Hive::RefactorPatrol::ScheduledSliceProducer::MAX_RESULTS
    Hive::RefactorPatrol::ScheduledSliceProducer.send(:remove_const, :MAX_RESULTS)
    Hive::RefactorPatrol::ScheduledSliceProducer.const_set(:MAX_RESULTS, limit)
    yield
  ensure
    Hive::RefactorPatrol::ScheduledSliceProducer.send(:remove_const, :MAX_RESULTS)
    Hive::RefactorPatrol::ScheduledSliceProducer.const_set(:MAX_RESULTS, original)
  end
end
