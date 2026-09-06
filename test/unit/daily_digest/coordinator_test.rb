require "test_helper"
require "hive/daily_digest/coordinator"

class DailyDigestCoordinatorTest < Minitest::Test
  include HiveTestHelper

  def test_refresh_opens_closes_catches_up_and_amends_without_rewriting_closed_base
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      facts = [ fact("first", "2026-08-30T10:00:00Z") ]
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = build_coordinator(store, -> { now }, -> { facts })

      first = coordinator.refresh
      assert_equal [ "2026-08-30" ], first.map { |row| row.fetch("local_date") }
      assert_equal "open", store.read("2026-08-30").fetch("lifecycle")

      now = Time.iso8601("2026-09-01T12:00:00Z")
      coordinator.refresh
      assert_equal "closed", store.read("2026-08-30").fetch("lifecycle")
      assert_equal "closed", store.read("2026-08-31").fetch("lifecycle")
      assert_equal "open", store.read("2026-09-01").fetch("lifecycle")
      closed_bytes = File.binread(store.base_path("2026-08-30"))

      facts << fact("late", "2026-08-30T11:00:00Z")
      coordinator.refresh
      historical = store.read("2026-08-30")
      assert_equal closed_bytes, File.binread(store.base_path("2026-08-30"))
      assert_equal [ "fact:first", "fact:late" ],
                   historical.fetch("items").map { |item| item.fetch("fact_id") }.sort
      assert_equal 1, historical.fetch("amendments").size

      coordinator.refresh(date: "2026-08-30")
      assert_equal closed_bytes, File.binread(store.base_path("2026-08-30"))
      assert_equal 1, store.read("2026-08-30").fetch("amendments").size
    end
  end

  def test_explicit_later_date_fills_coverage_holes_chronologically
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-09-01T12:00:00Z")
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = build_coordinator(store, -> { now }, -> { [] })

      result = coordinator.refresh(date: "2026-09-01")

      assert_equal %w[2026-08-30 2026-08-31 2026-09-01],
                   result.map { |row| row.fetch("local_date") }
      assert_equal %w[2026-08-30 2026-08-31 2026-09-01], store.dates
    end
  end

  def test_explicit_later_date_repairs_holes_before_an_existing_record
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-09-01T12:00:00Z")
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      interval = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                              .interval_for("2026-09-01", sequence: 3)
      projected = Hive::DailyDigest::Projector.new(clock: -> { now }).base(
        interval: interval, batch: batch([]), lifecycle: "open"
      )
      store.write_base(projected)
      coordinator = build_coordinator(store, -> { now }, -> { [] })

      coordinator.refresh(date: "2026-09-01")

      assert_equal %w[2026-08-30 2026-08-31 2026-09-01], store.dates
    end
  end

  def test_open_refresh_retains_facts_and_frontiers_during_source_outage
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      healthy = batch([ fact("known", "2026-08-30T10:00:00Z") ])
      outage_gap = {
        "gap_id" => "gap:outage", "source" => "project_state", "scope" => "demo",
        "reason_code" => "source_unavailable", "reason" => "unavailable",
        "observed_at" => now.iso8601(6), "project_id" => "project-1"
      }
      outage = batch([], gaps: [ outage_gap ]).with(frontiers: {})
      batches = [ healthy, outage ]
      coordinator = Hive::DailyDigest::Coordinator.new(
        config_loader: -> { config }, history_loader: -> { [] }, store: store,
        collector_factory: ->(**) { FakeCollector.new(batches.shift) }, clock: -> { now }
      )

      coordinator.refresh
      known_frontiers = store.read("2026-08-30").fetch("effective_source_frontiers")
      coordinator.refresh
      record = store.read("2026-08-30")

      assert_equal [ "fact:known" ], record.fetch("items").map { |row| row.fetch("fact_id") }
      assert_equal known_frontiers, record.fetch("effective_source_frontiers")
      assert_equal [ "gap:outage" ], record.fetch("effective_gaps").map { |row| row.fetch("gap_id") }
    end
  end

  def test_retained_attention_age_tracks_each_open_and_closing_boundary
    with_tmp_dir do |dir|
      interval = config.fetch("first_interval")
      frontier = {
        "project-1" => {
          "source" => "task_journal",
          "fingerprints" => { "task/journal.jsonl" => { "size" => 1 } }
        }
      }
      waiting = {
        "attention_id" => "attention:waiting", "kind" => "unanswered",
        "project_id" => "project-1", "project" => "demo", "task_slug" => "task",
        "waiting_since" => "2026-08-30T10:00:00.000000Z", "waiting_age_seconds" => 7_200
      }
      initial = batch([]).with(attention: [ waiting ], frontiers: frontier)
      unchanged = batch([]).with(frontiers: frontier)
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(
        Hive::DailyDigest::Projector.new(clock: -> { Time.iso8601("2026-08-30T12:00:00Z") })
                                    .base(interval: interval, batch: initial, lifecycle: "open")
      )
      membership = Struct.new(:projects, :gaps).new([ project ], [])
      coverage = Object.new
      coverage.define_singleton_method(:projects_for) { |**| membership }
      coordinator = Hive::DailyDigest::Coordinator.new(
        store: store, collector_factory: ->(**) { FakeCollector.new(unchanged) }
      )

      coordinator.send(
        :materialize, interval, config: config, coverage: coverage,
        now: Time.iso8601("2026-08-30T18:00:00Z")
      )
      assert_equal 28_800, store.read("2026-08-30").dig("attention", 0, "waiting_age_seconds")

      coordinator.send(
        :materialize, interval, config: config, coverage: coverage,
        now: Time.iso8601("2026-08-31T12:00:00Z")
      )
      closed = store.read("2026-08-30")
      assert_equal "closed", closed.fetch("lifecycle")
      assert_equal 50_400, closed.dig("attention", 0, "waiting_age_seconds")
    end
  end

  def test_gap_requires_positive_scoped_recovery_evidence
    coordinator = Hive::DailyDigest::Coordinator.new
    gap = {
      "gap_id" => "gap:missing", "source" => "project_state", "scope" => "demo:task",
      "project_id" => "project-1", "task_slug" => "deleted-task"
    }
    existing = { "effective_gaps" => [ gap ] }
    collected = batch([]).with(
      frontiers: { "project-1" => { "fingerprints" => {} } }
    )

    resolved = coordinator.send(
      :confirmed_resolutions, existing, collected,
      attempted_gap_ids: [ "gap:missing" ], membership_gaps: [],
      membership_recovery_scopes: []
    )

    assert_empty resolved
  end

  def test_registry_gap_requires_the_same_reobserved_scope
    coordinator = Hive::DailyDigest::Coordinator.new
    gap = {
      "gap_id" => "gap:registry", "source" => "project_registry",
      "scope" => "registry:4"
    }
    existing = { "effective_gaps" => [ gap ] }
    collected = batch([])
    arguments = {
      attempted_gap_ids: [ "gap:registry" ], membership_gaps: []
    }

    assert_empty coordinator.send(
      :confirmed_resolutions, existing, collected, **arguments,
      membership_recovery_scopes: []
    )
    assert_equal [ "gap:registry" ], coordinator.send(
      :confirmed_resolutions, existing, collected, **arguments,
      membership_recovery_scopes: [ "registry:4" ]
    )
  end

  def test_crash_before_store_commit_replays_same_fact_once
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      facts = [ fact("first", "2026-08-30T10:00:00Z") ]
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      calls = 0
      collector = lambda do |**|
        calls += 1
        raise "crash after collection" if calls == 1

        FakeCollector.new(batch(facts))
      end
      coordinator = Hive::DailyDigest::Coordinator.new(
        config_loader: -> { config }, history_loader: -> { [] }, store: store,
        collector_factory: collector, clock: -> { now }
      )

      assert_raises(RuntimeError) { coordinator.refresh }
      assert_raises(Hive::DailyDigest::MissingRecord) { store.read("2026-08-30") }
      coordinator.refresh
      assert_equal [ "fact:first" ], store.read("2026-08-30").fetch("items").map { |item| item.fetch("fact_id") }
    end
  end

  def test_pruned_target_records_discard_and_frontier_without_recreation
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-31T12:00:00Z")
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      coordinator = build_coordinator(store, -> { now }, -> { [ fact("first", "2026-08-30T10:00:00Z") ] })
      coordinator.refresh(date: "2026-08-30")
      store.prune("2026-08-30", pruned_at: now, reason: "test")

      coordinator.refresh(date: "2026-08-30")
      tombstone = store.read("2026-08-30")
      assert_equal "pruned", tombstone.fetch("lifecycle")
      assert_equal [ "fact:first" ], tombstone.fetch("discards").map { |row| row.fetch("identity") }
      refute File.exist?(store.base_path("2026-08-30"))
    end
  end

  def test_configuration_and_date_errors_are_typed
    store = Object.new
    store.define_singleton_method(:intervals) { [] }
    [ {}, { "enabled" => true } ].each do |invalid|
      coordinator = Hive::DailyDigest::Coordinator.new(
        config_loader: -> { invalid }, history_loader: -> { [] }, store: store
      )
      assert_raises(Hive::DailyDigest::Error) { coordinator.refresh }
    end

    coordinator = Hive::DailyDigest::Coordinator.new(
      config_loader: -> { config }, history_loader: -> { [] }, store: store
    )
    assert_raises(Hive::DailyDigest::InvalidRecord) { coordinator.refresh(date: "bad-date") }
    assert_raises(Hive::DailyDigest::Coordinator::NotInitialized) do
      coordinator.send(:normalize_first_interval, Object.new)
    end
    assert_equal Hive::ExitCodes::CONFIG, Hive::DailyDigest::Coordinator::Disabled.new.exit_code
    assert_equal Hive::ExitCodes::CONFIG,
                 Hive::DailyDigest::Coordinator::NotInitialized.new.exit_code
    assert_equal Hive::ExitCodes::USAGE, Hive::DailyDigest::Coordinator::FutureDate.new.exit_code
  end

  def test_first_interval_defaults_are_content_identified
    coordinator = Hive::DailyDigest::Coordinator.new
    interval = coordinator.send(:normalize_first_interval, {
      "local_date" => "2026-08-30", "time_zone" => "UTC",
      "starts_at" => "2026-08-30T00:00:00Z", "ends_at" => "2026-08-31T00:00:00Z"
    })

    assert_equal 86_400, interval.fetch("duration_seconds")
    assert_equal "calendar_day", interval.fetch("boundary_kind")
    assert_match(/\A[0-9a-f]{64}\z/, interval.fetch("interval_id"))
    assert_instance_of Hive::DailyDigest::Collector,
                       coordinator.instance_variable_get(:@collector_factory).call(
                         projects: [], starts_at: Time.at(0), ends_at: Time.at(1)
                       )
    assert_instance_of Time, coordinator.instance_variable_get(:@clock).call
  end

  def test_next_interval_records_skipped_labels_and_rejects_discontinuity
    coordinator = Hive::DailyDigest::Coordinator.new(clock: -> { Time.at(0) })
    previous = {
      "local_date" => "2011-12-29", "sequence" => 1, "time_zone" => "Pacific/Apia",
      "starts_at" => "2011-12-29T10:00:00Z", "ends_at" => "2011-12-30T10:00:00Z"
    }
    next_interval = coordinator.send(:next_interval, previous, { "time_zone" => "Pacific/Apia" })
    assert_equal "2011-12-31", next_interval.fetch("local_date")
    assert_equal [ "2011-12-30" ], next_interval.fetch("skipped_labels")

    discontinuous = previous.merge("ends_at" => "2011-12-30T09:00:00Z")
    assert_raises(Hive::DailyDigest::InvalidRecord) do
      coordinator.send(:next_interval, discontinuous, { "time_zone" => "Pacific/Apia" })
    end
  end

  def test_selected_date_skipped_by_interval_sequence_is_missing
    coordinator = Hive::DailyDigest::Coordinator.new(store: Object.new)
    store = coordinator.instance_variable_get(:@store)
    first = config.fetch("first_interval")
    store.define_singleton_method(:intervals) { [ first ] }
    jumped = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                        .interval_for("2026-09-01", sequence: 2)
    coordinator.define_singleton_method(:next_interval) { |_previous, _config| jumped }

    assert_raises(Hive::DailyDigest::MissingRecord) do
      coordinator.send(
        :intervals_through, config, now: Time.iso8601("2026-09-02T00:00:00Z"),
        selected_date: "2026-08-31"
      )
    end
  end

  def test_concurrent_close_and_equivalent_amendment_conflict_are_accepted
    now = Time.iso8601("2026-08-31T12:00:00Z")
    interval = config.fetch("first_interval")
    empty_batch = batch([])
    fact_batch = batch([ fact("late", "2026-08-30T10:00:00Z") ])
    projector = Hive::DailyDigest::Projector.new(clock: -> { now })
    empty_closed = projector.base(interval: interval, batch: empty_batch, lifecycle: "closed")
    latest = projector.base(interval: interval, batch: fact_batch, lifecycle: "closed")
    membership = Struct.new(:projects, :gaps).new([ project ], [])
    coverage = Object.new
    coverage.define_singleton_method(:projects_for) { |**| membership }

    close_store = Object.new
    close_reads = 0
    close_store.define_singleton_method(:read) do |_date|
      close_reads += 1
      raise Hive::DailyDigest::MissingRecord, "missing" if close_reads == 1

      latest
    end
    close_store.define_singleton_method(:write_base) do |_base|
      raise Hive::DailyDigest::Store::ImmutableRecord, "closed concurrently"
    end
    close_store.define_singleton_method(:advance_frontiers) { |_date, frontiers| frontiers }
    close = Hive::DailyDigest::Coordinator.new(
      store: close_store, collector_factory: ->(**) { FakeCollector.new(fact_batch) }, clock: -> { now }
    )
    assert_equal "unchanged",
                 close.send(:materialize, interval, config: config, coverage: coverage, now: now)
                      .fetch("status")

    conflict_store = Object.new
    conflict_reads = [ empty_closed, latest ]
    conflict_store.define_singleton_method(:read) { |_date| conflict_reads.shift }
    conflict_store.define_singleton_method(:append_amendment) do |*_args|
      raise Hive::DailyDigest::Store::Conflict, "same semantic delta"
    end
    conflict = Hive::DailyDigest::Coordinator.new(
      store: conflict_store, collector_factory: ->(**) { FakeCollector.new(fact_batch) },
      clock: -> { now }
    )
    assert_equal "unchanged",
                 conflict.send(:materialize, interval, config: config, coverage: coverage, now: now)
                         .fetch("status")
  end

  def test_pruned_gap_is_recorded_as_a_discard
    now = Time.iso8601("2026-08-31T12:00:00Z")
    interval = config.fetch("first_interval")
    gap = {
      "gap_id" => "gap:github", "source" => "github", "scope" => "demo",
      "reason_code" => "offline", "reason" => "offline", "observed_at" => now.iso8601(6)
    }
    collected = batch([], gaps: [ gap ])
    membership = Struct.new(:projects, :gaps).new([ project ], [])
    coverage = Object.new
    coverage.define_singleton_method(:projects_for) { |**| membership }
    store = Object.new
    store.define_singleton_method(:read) do |_date|
      { "lifecycle" => "pruned", "effective_gaps" => [] }
    end
    discards = nil
    store.define_singleton_method(:discard_pruned) do |_date, entries:, **|
      discards = entries
    end
    coordinator = Hive::DailyDigest::Coordinator.new(
      store: store, collector_factory: ->(**) { FakeCollector.new(collected) }, clock: -> { now }
    )

    result = coordinator.send(:materialize, interval, config: config, coverage: coverage, now: now)
    assert_equal "pruned", result.fetch("status")
    assert_equal [ "gap:github" ], discards.map { |row| row.fetch("identity") }
  end

  def test_pruned_materialization_enters_the_mutation_path_without_new_evidence
    now = Time.iso8601("2026-08-31T12:00:00Z")
    interval = config.fetch("first_interval")
    membership = Struct.new(:projects, :gaps).new([], [])
    coverage = Object.new
    coverage.define_singleton_method(:projects_for) { |**| membership }
    store = Object.new
    store.define_singleton_method(:read) do |_date|
      { "lifecycle" => "pruned", "effective_gaps" => [], "source_frontiers" => {} }
    end
    mutation = nil
    store.define_singleton_method(:discard_pruned) do |_date, entries:, source_frontiers:, **|
      mutation = [ entries, source_frontiers ]
    end
    coordinator = Hive::DailyDigest::Coordinator.new(
      store: store,
      collector_factory: ->(**) { FakeCollector.new(batch([]).with(frontiers: {})) }
    )

    coordinator.send(:materialize, interval, config: config, coverage: coverage, now: now)

    assert_equal [ [], {} ], mutation
  end

  def test_automatic_refresh_rechecks_closed_and_pruned_intervals_for_late_observations
    now = Time.iso8601("2026-09-01T12:00:00Z")
    intervals = (0..2).map do |offset|
      Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                 .interval_for(Date.new(2026, 8, 30) + offset, sequence: offset + 1)
    end
    records = {
      "2026-08-30" => { "lifecycle" => "closed", "effective_gaps" => [] },
      "2026-08-31" => { "lifecycle" => "pruned" },
      "2026-09-01" => { "lifecycle" => "open", "effective_gaps" => [] }
    }
    store = Object.new
    store.define_singleton_method(:intervals) { intervals }
    store.define_singleton_method(:read) { |date| records.fetch(date) }
    coordinator = Hive::DailyDigest::Coordinator.new(
      config_loader: -> { config }, history_loader: -> { [] }, store: store, clock: -> { now }
    )
    materialized = []
    coordinator.define_singleton_method(:materialize) do |interval, **|
      materialized << interval.fetch("local_date")
    end

    coordinator.refresh

    assert_equal [ "2026-08-30", "2026-08-31", "2026-09-01" ], materialized
  end

  def test_pruned_gap_recovery_is_a_stable_discard_without_recreating_base
    now = Time.iso8601("2026-08-31T12:00:00Z")
    interval = config.fetch("first_interval")
    old_gap = {
      "gap_id" => "gap:github", "source" => "github", "scope" => "demo",
      "project_id" => "project-1",
      "reason_code" => "offline", "reason" => "offline",
      "observed_at" => "2026-08-31T00:00:00Z"
    }
    collected = batch([])
    membership = Struct.new(:projects, :gaps).new([ project ], [])
    coverage = Object.new
    coverage.define_singleton_method(:projects_for) { |**| membership }
    store = Object.new
    store.define_singleton_method(:read) do |_date|
      { "lifecycle" => "pruned", "effective_gaps" => [ old_gap ] }
    end
    discards = nil
    store.define_singleton_method(:discard_pruned) do |_date, entries:, **|
      discards = entries
    end
    coordinator = Hive::DailyDigest::Coordinator.new(
      store: store, collector_factory: ->(**) { FakeCollector.new(collected) }, clock: -> { now }
    )

    coordinator.send(
      :materialize, interval, config: config, coverage: coverage, now: now,
      attempted_gap_ids: [ "gap:github" ]
    )

    assert_equal [ [ "gap:github", "gap_resolution" ] ],
                 discards.map { |row| [ row.fetch("identity"), row.fetch("kind") ] }
  end

  def test_pruned_recovery_consumes_retained_frontiers_and_is_acknowledged_once
    with_tmp_dir do |dir|
      interval = config.fetch("first_interval")
      old_gap = {
        "gap_id" => "gap:github", "source" => "github", "scope" => "demo",
        "project_id" => "project-1", "reason_code" => "offline",
        "reason" => "offline", "observed_at" => "2026-08-30T12:00:00.000000Z"
      }
      frontier = {
        "project-1" => {
          "source" => "task_journal",
          "fingerprints" => { "task/journal.jsonl" => { "size" => 1 } }
        }
      }
      partial = batch([], gaps: [ old_gap ]).with(frontiers: frontier)
      recovered = batch([]).with(frontiers: frontier)
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      store.write_base(
        Hive::DailyDigest::Projector.new(clock: -> { Time.iso8601("2026-08-31T00:00:00Z") })
                                    .base(interval: interval, batch: partial, lifecycle: "closed")
      )
      store.prune("2026-08-30", pruned_at: Time.iso8601("2026-08-31T01:00:00Z"), reason: "test")
      membership = Struct.new(:projects, :gaps).new([ project ], [])
      coverage = Object.new
      coverage.define_singleton_method(:projects_for) { |**| membership }
      prior_frontiers = []
      coordinator = Hive::DailyDigest::Coordinator.new(
        store: store,
        collector_factory: lambda do |**options|
          prior_frontiers << options.fetch(:prior_frontiers)
          FakeCollector.new(recovered)
        end
      )

      coordinator.send(
        :materialize, interval, config: config, coverage: coverage,
        now: Time.iso8601("2026-08-31T02:00:00Z")
      )
      first = store.read("2026-08-30")
      first_bytes = File.binread(store.tombstone_path("2026-08-30"))
      coordinator.send(
        :materialize, interval, config: config, coverage: coverage,
        now: Time.iso8601("2026-08-31T03:00:00Z")
      )
      replay = store.read("2026-08-30")

      assert_equal [ frontier, frontier ], prior_frontiers
      assert_empty replay.fetch("effective_gaps")
      assert_equal [ [ "gap:github", "gap_resolution" ] ],
                   replay.fetch("discards").map { |row| [ row.fetch("identity"), row.fetch("kind") ] }
      assert_equal first.fetch("discards"), replay.fetch("discards")
      assert_equal first_bytes, File.binread(store.tombstone_path("2026-08-30"))
    end
  end

  private

  FakeCollector = Struct.new(:result) do
    def collect = result
  end

  def build_coordinator(store, clock, facts)
    Hive::DailyDigest::Coordinator.new(
      config_loader: -> { config }, history_loader: -> { [] }, store: store,
      collector_factory: ->(**) { FakeCollector.new(batch(facts.call)) }, clock: clock
    )
  end

  def config
    calendar = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
    {
      "enabled" => true, "time_zone" => "UTC",
      "coverage_started_at" => "2026-08-30T00:00:00.000000Z",
      "initial_membership" => [ project ],
      "first_interval" => calendar.interval_for("2026-08-30", sequence: 1),
      "freshness_budget_sec" => 900
    }
  end

  def project
    {
      "project_id" => "project-1", "registration_id" => "registration-1",
      "name" => "demo", "path" => "/demo", "hive_state_path" => "/demo/.hive-state"
    }
  end

  def batch(facts, gaps: [])
    Hive::DailyDigest::Collector::Result.new(
      projects: [ project ], facts: facts, attention: [], gaps: gaps,
      frontiers: { "project-1" => { "source" => "task_journal", "fingerprints" => facts.map { |f| f["fact_id"] } } },
      completeness: gaps.empty? ? "complete" : "partial",
      content: facts.empty? ? (gaps.empty? ? "empty" : "unknown") : "non_empty"
    )
  end

  def fact(id, occurred_at)
    {
      "fact_id" => "fact:#{id}", "kind" => "stage_transition",
      "project_id" => "project-1", "project" => "demo", "task_slug" => "task",
      "occurred_at" => Time.iso8601(occurred_at).utc.iso8601(6),
      "observed_at" => Time.iso8601(occurred_at).utc.iso8601(6)
    }
  end
end
