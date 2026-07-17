require "test_helper"
require "json_schemer"
require "hive/refactor_patrol/job_query"

class HiveRefactorPatrolJobQueryTest < Minitest::Test
  class FakeStore
    attr_reader :jobs_calls, :read_calls, :page_calls

    def initialize(records)
      @records = records
      @jobs_calls = 0
      @read_calls = []
      @page_calls = []
      @generation = "a" * 32
    end

    def jobs
      @jobs_calls += 1
      @records
    end

    def read_job(job_id)
      @read_calls << job_id
      @records.find { |record| record.fetch("job_id") == job_id } ||
        raise(Hive::RefactorPatrol::JobStore::RecordNotFound, "missing")
    end

    def job_query_page(limit:, cursor: nil)
      @page_calls << { limit: limit, cursor: cursor }
      after = cursor ? cursor.fetch("after_sequence") : 0
      through = cursor ? cursor.fetch("through_sequence") : @records.size
      raise Hive::RefactorPatrol::JobQueryIndex::CursorError unless !cursor || cursor["generation"] == @generation

      window = @records.slice(after, limit + 1).to_a.first([ through - after, 0 ].max)
      selected = window.first(limit)
      next_after = selected.empty? ? after : after + selected.size
      {
        "generation" => through.zero? ? nil : @generation,
        "after_sequence" => after,
        "through_sequence" => through,
        "next_after_sequence" => next_after,
        "total" => through,
        "has_more" => window.size > limit,
        "job_ids" => selected.map { |record| record.fetch("job_id") },
        "jobs" => selected
      }
    end

    def add(record)
      @records << record
    end
  end

  def test_list_is_a_schema_valid_summary_without_mutation
    record = aggregate
    before = Marshal.dump(record)
    store = FakeStore.new([ record ])

    payload = Hive::RefactorPatrol::JobQuery.new(store).list_envelope(
      project: "demo", project_root: "/repo"
    )

    assert_empty schemer.validate(payload).to_a
    assert_equal "list", payload.fetch("action")
    assert_equal 1, payload.fetch("count")
    assert_equal 1, payload.dig("page", "returned")
    assert_equal false, payload.dig("page", "has_more")
    assert_nil payload.dig("page", "next_cursor")
    summary = payload.fetch("jobs").fetch(0)
    assert_equal "blocked", summary.fetch("state")
    assert_equal 1, summary.dig("counts", "pending_actions")
    assert_equal "checkout_changed", summary.fetch("blockers").fetch(0).fetch("reason")
    assert_equal "action", summary.fetch("blockers").fetch(0).fetch("scope")
    assert_equal before, Marshal.dump(record)
    assert_equal 0, store.jobs_calls
    assert_equal 1, store.page_calls.size
    assert_empty store.read_calls
  end

  def test_show_returns_authoritative_attempts_actions_and_detached_copies
    record = aggregate
    store = FakeStore.new([ record ])
    payload = Hive::RefactorPatrol::JobQuery.new(store).show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7"
    )

    assert_empty schemer.validate(payload).to_a
    assert_equal [ "job-7" ], store.read_calls
    assert_equal "action_block", payload.dig("job", "attempts", 0, "kind")
    assert_equal "fix-fp", payload.dig("job", "actions", 0, "canonical_action_id")

    payload.dig("job", "actions", 0, "receipts")["changed"] = true
    refute record.dig("actions", 0, "receipts").key?("changed")
  end

  def test_list_uses_durable_sequence_even_when_timestamps_move_backwards
    first = aggregate(job_id: "first", created_at: "2026-07-12T10:00:00Z")
    rollback = aggregate(job_id: "rollback", created_at: "2026-07-12T09:00:00Z")

    payload = Hive::RefactorPatrol::JobQuery.new(
      FakeStore.new([ first, rollback ])
    ).list_envelope(project: "demo", project_root: "/repo")

    assert_equal %w[first rollback], payload.fetch("jobs").map { |job| job.fetch("job_id") }
  end

  def test_list_is_bounded_and_resumes_from_an_opaque_cursor
    records = [
      aggregate(job_id: "job-1", created_at: "2026-07-12T08:00:00Z"),
      aggregate(job_id: "job-2", created_at: "2026-07-12T09:00:00Z"),
      aggregate(job_id: "job-3", created_at: "2026-07-12T10:00:00Z")
    ]
    query = Hive::RefactorPatrol::JobQuery.new(FakeStore.new(records))

    first = query.list_envelope(project: "demo", project_root: "/repo", limit: 2)
    assert_equal 3, first.fetch("count")
    assert_equal %w[job-1 job-2], first.fetch("jobs").map { |job| job.fetch("job_id") }
    assert_equal true, first.dig("page", "has_more")
    refute_nil first.dig("page", "next_cursor")
    assert_includes query.text(first), "next_cursor=#{first.dig('page', 'next_cursor')}"
    assert_empty schemer.validate(first).to_a

    second = query.list_envelope(
      project: "demo", project_root: "/repo", limit: 2,
      cursor: first.dig("page", "next_cursor")
    )
    assert_equal [ "job-3" ], second.fetch("jobs").map { |job| job.fetch("job_id") }
    assert_equal false, second.dig("page", "has_more")
    assert_nil second.dig("page", "next_cursor")
    assert_empty schemer.validate(second).to_a
  end

  def test_list_cursor_freezes_membership_at_the_first_page_high_water
    store = FakeStore.new([
      aggregate(job_id: "job-1"),
      aggregate(job_id: "job-2")
    ])
    query = Hive::RefactorPatrol::JobQuery.new(store)
    first = query.list_envelope(project: "demo", project_root: "/repo", limit: 1)
    store.add(aggregate(job_id: "job-3", created_at: "2026-07-11T00:00:00Z"))

    second = query.list_envelope(
      project: "demo", project_root: "/repo", limit: 1,
      cursor: first.dig("page", "next_cursor")
    )

    assert_equal [ "job-2" ], second.fetch("jobs").map { |job| job.fetch("job_id") }
    assert_equal 2, second.dig("page", "total")
    assert_equal false, second.dig("page", "has_more")
  end

  def test_list_default_page_never_exceeds_one_hundred_jobs
    start = Time.utc(2026, 7, 12, 8, 0, 0)
    records = 101.times.map do |index|
      aggregate(
        job_id: format("job-%03d", index),
        created_at: (start + index).iso8601
      )
    end

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new(records)).list_envelope(
      project: "demo", project_root: "/repo"
    )

    assert_equal 101, payload.fetch("count")
    assert_equal 100, payload.fetch("jobs").size
    assert_equal 100, payload.dig("page", "limit")
    assert_equal true, payload.dig("page", "has_more")
    refute_nil payload.dig("page", "next_cursor")
    assert_empty schemer.validate(payload).to_a
  end

  def test_list_rejects_invalid_limits_and_cursors_as_usage
    query = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([]))

    [ 0, 101, 1.5, "many" ].each do |limit|
      assert_raises(Hive::RefactorPatrol::JobQuery::UsageError) do
        query.list_envelope(project: "demo", project_root: "/repo", limit: limit)
      end
    end
    assert_raises(Hive::RefactorPatrol::JobQuery::UsageError) do
      query.list_envelope(project: "demo", project_root: "/repo", cursor: "not-a-cursor")
    end
  end

  def test_show_bounds_unbounded_histories_and_full_is_explicit
    record = aggregate
    record["attempts"] = 101.times.map do |index|
      { "kind" => "attempt-#{index + 1}", "state" => "released", "outcome" => "retry" }
    end
    action = record.fetch("actions").first
    action["claims"] = 3.times.map do |index|
      { "generation" => index + 1, "state" => "released" }
    end
    action["receipts"]["publication_attempts"] = 3.times.to_h do |index|
      id = "attempt-#{index + 1}"
      [ id, { "descriptor" => { "recorded_at" => "2026-07-12T10:0#{index}:00Z" } } ]
    end
    query = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ]))

    default = query.show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7"
    )
    assert_equal 100, default.dig("job", "attempts").size
    assert_equal "attempt-2", default.dig("job", "attempts", 0, "kind")
    assert_equal({ "total" => 101, "returned" => 100, "truncated" => true },
                 default.dig("job", "history", "attempts"))
    assert_empty schemer.validate(default).to_a

    bounded = query.show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7", limit: 1
    )
    assert_equal [ "attempt-101" ], bounded.dig("job", "attempts").map { |item| item.fetch("kind") }
    assert_equal [ 3 ], bounded.dig("job", "actions", 0, "claims").map { |item| item.fetch("generation") }
    assert_equal [ "attempt-3" ], bounded.dig("job", "actions", 0, "receipts", "publication_attempts").keys
    assert_equal({ "total" => 101, "returned" => 1, "truncated" => true },
                 bounded.dig("job", "history", "attempts"))
    assert_empty schemer.validate(bounded).to_a

    full = query.show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7", full: true
    )
    assert_equal 101, full.dig("job", "attempts").size
    assert_equal 3, full.dig("job", "actions", 0, "claims").size
    assert_equal 3, full.dig("job", "actions", 0, "receipts", "publication_attempts").size
    assert_equal true, full.dig("job", "history", "full")
    assert_nil full.dig("job", "history", "limit")
    assert_includes query.text(full), "history=full"
    assert_empty schemer.validate(full).to_a
  end

  def test_bounded_show_prunes_flat_patch_history_to_selected_namespaced_attempts
    record = aggregate
    action = record.fetch("actions").first
    receipts = {}
    3.times do |index|
      base = format("%040x", index + 1)
      commit = format("%040x", index + 11)
      patch = {
        "branch" => "hive-refactor/fix-fp",
        "publication_base_sha" => base,
        "commit_sha" => commit
      }
      receipts = Hive::RefactorPatrol::PublicationAttempt.ensure_for_patch(
        receipts: receipts,
        patch_receipt: patch,
        recorded_at: "2026-07-12T10:0#{index}:00Z"
      )
      attempt_id = Hive::RefactorPatrol::PublicationAttempt.id_for(
        publication_base_sha: base, commit_sha: commit
      )
      next if index == 2

      receipts = Hive::RefactorPatrol::PublicationAttempt.supersede(
        receipts: receipts,
        attempt_id: attempt_id,
        observed_head_sha: format("%040x", index + 21),
        recorded_at: "2026-07-12T10:0#{index}:30Z"
      )
      receipts["patch_superseded_#{Digest::SHA256.hexdigest(commit)}"] = {
        "reason" => "trunk_drift_retry", "commit_sha" => commit
      }
    end
    action["receipts"] = receipts
    query = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ]))

    bounded = query.show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7", limit: 1
    )
    bounded_receipts = bounded.dig("job", "actions", 0, "receipts")
    assert_equal [ "patch_3" ], bounded_receipts.keys.grep(/\Apatch(?:_\d+)?\z/)
    assert_empty bounded_receipts.keys.grep(/\Apatch_superseded_/)
    assert_equal 1, bounded_receipts.fetch("publication_attempts").size

    full = query.show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7", full: true
    )
    full_receipts = full.dig("job", "actions", 0, "receipts")
    assert_equal %w[patch patch_2 patch_3], full_receipts.keys.grep(/\Apatch(?:_\d+)?\z/)
    assert_equal 2, full_receipts.keys.grep(/\Apatch_superseded_/).size
    assert_equal 3, full_receipts.fetch("publication_attempts").size
  end

  def test_bounded_show_retains_only_active_legacy_patch
    record = aggregate
    action = record.fetch("actions").first
    old_commit = "b" * 40
    current_commit = "c" * 40
    action["receipts"] = {
      "patch" => { "branch" => "hive-refactor/fix-fp", "commit_sha" => old_commit },
      "patch_2" => { "branch" => "hive-refactor/fix-fp", "commit_sha" => current_commit },
      "patch_superseded_#{Digest::SHA256.hexdigest(old_commit)}" => {
        "reason" => "trunk_drift_retry", "commit_sha" => old_commit
      }
    }

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7", limit: 1
    )
    receipts = payload.dig("job", "actions", 0, "receipts")
    publication_history = payload.dig(
      "job", "history", "actions", 0, "publication_attempts"
    )

    assert_equal [ "patch_2" ], receipts.keys.grep(/\Apatch(?:_\d+)?\z/)
    assert_empty receipts.keys.grep(/\Apatch_superseded_/)
    assert_equal({ "total" => 2, "returned" => 1, "truncated" => true }, publication_history)
    assert_includes Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).text(payload),
                    "truncated=true"

    full = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).show_envelope(
      project: "demo", project_root: "/repo", job_id: "job-7", full: true
    )
    assert_equal({ "total" => 2, "returned" => 2, "truncated" => false },
                 full.dig("job", "history", "actions", 0, "publication_attempts"))
  end

  def test_show_rejects_invalid_ids_without_masking_valid_record_corruption
    store = FakeStore.new([])
    query = Hive::RefactorPatrol::JobQuery.new(store)
    error = assert_raises(Hive::RefactorPatrol::JobQuery::UsageError) do
      query.show_envelope(project: "demo", project_root: "/repo", job_id: "../bad")
    end
    assert_match(/valid job id/, error.message)
    assert_empty store.read_calls

    corrupt_store = Object.new
    corrupt_store.define_singleton_method(:read_job) do |_job_id|
      raise Hive::RefactorPatrol::JobStore::InconsistentRecord, "corrupt durable record"
    end
    error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
      Hive::RefactorPatrol::JobQuery.new(corrupt_store).show_envelope(
        project: "demo", project_root: "/repo", job_id: "job-7"
      )
    end
    assert_match(/corrupt durable record/, error.message)
  end

  def test_list_does_not_report_superseded_discovery_failures_as_current_blockers
    record = aggregate
    record["state"] = "complete"
    record["complete"] = true
    record["attempts"] << {
      "kind" => "discovery_claim", "state" => "completed", "outcome" => "classified"
    }
    record.fetch("actions").first["terminal"] = true

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    assert_empty payload.dig("jobs", 0, "blockers")
  end

  def test_list_classifies_current_discovery_and_unclaimed_action_blocks
    discovery = aggregate
    discovery["actions"] = []
    discovery["attempts"] = [ {
      "kind" => "discovery_block", "state" => "blocked",
      "reason" => "checkout_changed"
    } ]
    discovery_payload = Hive::RefactorPatrol::JobQuery.new(
      FakeStore.new([ discovery ])
    ).list_envelope(project: "demo", project_root: "/repo")
    assert_equal "discovery", discovery_payload.dig("jobs", 0, "blockers", 0, "scope")

    action = aggregate
    action["attempts"] = []
    action.dig("actions", 0)["claims"] = []
    action.dig("actions", 0)["outcome"] = "authority_revoked"
    action_payload = Hive::RefactorPatrol::JobQuery.new(
      FakeStore.new([ action ])
    ).list_envelope(project: "demo", project_root: "/repo")
    assert_equal "action", action_payload.dig("jobs", 0, "blockers", 0, "scope")
    assert_equal "fix-fp", action_payload.dig(
      "jobs", 0, "blockers", 0, "canonical_action_id"
    )
  end

  def test_list_drops_superseded_action_block_after_a_new_claim_starts
    record = aggregate
    record["state"] = "acting"
    record.dig("attempts", 0)["action_claim_generations"] = { "fix-fp" => 1 }
    record.dig("actions", 0, "claims") << {
      "state" => "running", "generation" => 2,
      "claimed_at" => "2026-07-12T10:02:00Z"
    }

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    assert_empty payload.dig("jobs", 0, "blockers")
    assert_empty schemer.validate(payload).to_a
  end

  def test_same_second_claim_does_not_hide_a_current_legacy_action_block
    record = aggregate
    record.dig("actions", 0, "claims") << {
      "state" => "running", "generation" => 2,
      "claimed_at" => record.dig("attempts", 0, "finished_at")
    }

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    assert_equal "checkout_changed", payload.dig("jobs", 0, "blockers", 0, "reason")
    assert_empty schemer.validate(payload).to_a
  end

  def test_action_claim_generation_snapshot_orders_blocks_without_wall_clock_order
    record = aggregate
    record.dig("attempts", 0)["action_claim_generations"] = { "fix-fp" => 2 }
    record.dig("actions", 0, "claims") << {
      "state" => "running", "generation" => 2,
      "claimed_at" => "2026-07-12T09:59:00Z"
    }
    query = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ]))

    current = query.list_envelope(project: "demo", project_root: "/repo")
    assert_equal "checkout_changed", current.dig("jobs", 0, "blockers", 0, "reason")

    record.dig("actions", 0, "claims") << {
      "state" => "running", "generation" => 3,
      "claimed_at" => "2026-07-12T09:58:00Z"
    }
    superseded = query.list_envelope(project: "demo", project_root: "/repo")
    assert_empty superseded.dig("jobs", 0, "blockers")
  end

  def test_released_new_action_claim_does_not_resurrect_old_lifecycle_block
    record = aggregate
    record.dig("actions", 0, "claims") << {
      "state" => "released", "generation" => 2,
      "claimed_at" => "2026-07-12T10:02:00Z",
      "outcome" => "new_retry", "next_eligible_at" => "2026-07-12T10:03:00Z"
    }

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    blockers = payload.dig("jobs", 0, "blockers")
    assert_equal 1, blockers.size
    assert_equal "fix-fp", blockers.dig(0, "canonical_action_id")
    assert_equal "new_retry", blockers.dig(0, "reason")
    assert_empty schemer.validate(payload).to_a
  end

  def test_unparseable_legacy_action_block_time_remains_visible
    record = aggregate
    record.dig("attempts", 0)["finished_at"] = "legacy"
    record.dig("actions", 0, "claims") << {
      "state" => "running", "claimed_at" => "2026-07-12T10:02:00Z"
    }

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    assert_equal "checkout_changed", payload.dig("jobs", 0, "blockers", 0, "reason")
  end

  def test_list_keeps_nullable_reason_for_legacy_block_attempt
    record = aggregate
    record["actions"] = []
    record["attempts"] = [ { "kind" => "discovery_block", "state" => "blocked" } ]

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    blocker = payload.dig("jobs", 0, "blockers", 0)
    assert blocker.key?("reason")
    assert_nil blocker.fetch("reason")
    assert_empty schemer.validate(payload).to_a
  end

  def test_list_normalizes_wrong_typed_legacy_blocker_fields_to_schema
    record = aggregate
    record["state"] = "classified"
    record["actions"] = []
    record["attempts"] = [ {
      "kind" => "action_block", "state" => "blocked",
      "reason" => [], "next_eligible_at" => 123
    } ]

    payload = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([ record ])).list_envelope(
      project: "demo", project_root: "/repo"
    )

    blocker = payload.dig("jobs", 0, "blockers", 0)
    assert_nil blocker.fetch("reason")
    refute blocker.key?("next_eligible_at")
    assert_empty schemer.validate(payload).to_a
  end

  def test_missing_show_uses_versioned_not_found_error
    query = Hive::RefactorPatrol::JobQuery.new(FakeStore.new([]))
    error = assert_raises(Hive::RefactorPatrol::JobQuery::NotFound) do
      query.show_envelope(project: "demo", project_root: "/repo", job_id: "missing")
    end
    payload = Hive::RefactorPatrol::JobQuery.error_envelope(error, action: "show")

    assert_empty schemer.validate(payload).to_a
    assert_equal false, payload.fetch("ok")
    assert_equal "not_found", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
  end

  def test_usage_error_uses_versioned_usage_kind
    error = Hive::RefactorPatrol::JobQuery::UsageError.new("bad query")
    payload = Hive::RefactorPatrol::JobQuery.error_envelope(error, action: "show")

    assert_empty schemer.validate(payload).to_a
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
  end

  def test_query_utility_error_and_text_branches_are_versioned
    assert_equal 7, Hive::RefactorPatrol::JobQuery.normalize_limit("7")
    assert_raises(Hive::RefactorPatrol::JobQuery::UsageError) do
      Hive::RefactorPatrol::JobQuery.decode_cursor("x" * 513)
    end
    invalid_payload = Base64.urlsafe_encode64(
      JSON.generate(
        "generation" => "a" * 32,
        "after_sequence" => 0,
        "through_sequence" => 1
      ),
      padding: false
    )
    assert_raises(Hive::RefactorPatrol::JobQuery::UsageError) do
      Hive::RefactorPatrol::JobQuery.decode_cursor(invalid_payload)
    end

    store = FakeStore.new([ aggregate ])
    mismatched_cursor = Base64.urlsafe_encode64(
      JSON.generate(
        "generation" => "b" * 32,
        "after_sequence" => 1,
        "through_sequence" => 1
      ),
      padding: false
    )
    assert_raises(Hive::RefactorPatrol::JobQuery::UsageError) do
      Hive::RefactorPatrol::JobQuery.new(store).list_envelope(
        project: "demo", project_root: "/repo", cursor: mismatched_cursor
      )
    end

    query = Hive::RefactorPatrol::JobQuery.new(store)
    show = query.show_envelope(project: "demo", project_root: "/repo", job_id: "job-7")
    assert_includes query.text(show), "hive refactor-patrol job: job-7"
    assert_includes query.text(show), "truncated=false"

    config = Hive::RefactorPatrol::JobQuery.error_envelope(
      Hive::ConfigError.new("bad config"), action: "list"
    )
    generic = Hive::RefactorPatrol::JobQuery.error_envelope(
      RuntimeError.new("bad state"), action: "show"
    )
    assert_equal "config", config.fetch("error_kind")
    assert_equal "error", generic.fetch("error_kind")
    assert_empty schemer.validate(config).to_a
    assert_empty schemer.validate(generic).to_a
  end

  private

  def schemer
    @schemer ||= JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol-jobs")))
    )
  end

  def aggregate(job_id: "job-7", created_at: "2026-07-12T09:00:00Z")
    {
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo"
      },
      "analysis_sha" => "a" * 40,
      "policy" => { "discovery" => true, "auto_fix" => true, "issue_filing" => false },
      "state" => "blocked",
      "complete" => false,
      "dispositions" => { "accepted" => [], "flagged" => [], "suppressed" => [] },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => nil,
      "attempts" => [
        {
          "kind" => "action_block",
          "state" => "blocked",
          "reason" => "checkout_changed",
          "finished_at" => "2026-07-12T10:00:00Z",
          "next_eligible_at" => "2026-07-12T10:01:00Z"
        }
      ],
      "actions" => [
        {
          "canonical_action_id" => "fix-fp",
          "thesis_id" => "thesis-1",
          "thesis_fingerprint" => "fp",
          "kind" => "fix",
          "owner_job_id" => "job-7",
          "outcome" => "retry",
          "terminal" => false,
          "receipts" => {},
          "claims" => [
            {
              "state" => "released",
              "outcome" => "retry",
              "next_eligible_at" => "2026-07-12T10:01:00Z"
            }
          ]
        }
      ],
      "created_at" => created_at,
      "updated_at" => "2026-07-12T10:00:00Z"
    }
  end
end
