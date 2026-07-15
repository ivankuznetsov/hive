require "test_helper"
require "json"
require "json_schemer"
require "hive/refactor_patrol/post_merge_reporter"
require "hive/refactor_patrol/post_merge_state_store"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis"

class HiveRefactorPatrolPostMergeReporterTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 15, 12, 0, 0)

  class Guard
    attr_accessor :blocked

    def assert_unchanged!(_snapshot)
      raise Hive::RefactorPatrol::CheckoutGuard::Blocked.new("checkout_moved", "moved") if blocked

      true
    end
  end

  def test_mixed_completion_persists_actionable_schema_valid_report_and_advances
    with_report_context(baseline: { "fp-s" => { "state" => "seen" } }) do |ctx|
      accepted = thesis("accepted", "fp-a")
      flagged = thesis("flagged", "fp-f", flags: [ "cross_feature_scope" ])
      suppressed = thesis("suppressed", "fp-s", collision: { "kind" => "collision_already_seen", "reference" => "fp-s" })
      write_theses(ctx, accepted, flagged, suppressed)
      envelope = envelope_for(
        ranked: [ accepted, flagged ],
        flagged: [ flagged ],
        suppressed: [ suppressed ]
      )

      report = ctx.fetch(:reporter).call(
        token: ctx.fetch(:token), envelope: envelope, state_store: ctx.fetch(:post_merge),
        guard: ctx.fetch(:guard), snapshot: Object.new, now: T0 + 10
      )

      assert_equal({ "accepted" => 1, "flagged" => 1, "suppressed" => 1 }, report.fetch("totals"))
      detail = report.fetch("flagged_theses").fetch(0)
      %w[id fingerprint content_digest problem proposed_refactor evidence feature_boundary risk
         admissibility_reason expected_leverage required_validation].each do |key|
        assert detail.key?(key), key
      end
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-refactor-patrol-post-merge"))))
      assert schemer.valid?(report), schemer.validate(report).map { |error| error["error"] }.inspect
      assert_equal "processed", ctx.fetch(:post_merge).merge_record(ctx.dig(:token, "identity")).fetch("status")
      assert_equal "merge", ctx.fetch(:post_merge).state.fetch("checkpoint_sha")
      assert File.file?(ctx.fetch(:post_merge).report_path(ctx.dig(:token, "identity")))
    end
  end

  def test_unchanged_build_emits_no_delta_but_changed_content_emits_once
    with_report_context do |ctx|
      item = thesis("accepted", "fp-a")
      write_theses(ctx, item)
      envelope = envelope_for(ranked: [ item ])

      first = ctx.fetch(:reporter).build(token: ctx.fetch(:token), envelope: envelope,
                                         state_store: ctx.fetch(:post_merge), now: T0 + 10)
      refute_empty first.fetch(:report).fetch("emitted_delta")
      ctx.fetch(:post_merge).persist_artifacts!(
        ctx.dig(:token, "identity"), report: first.fetch(:report), emission_digests: first.fetch(:emission_digests)
      )

      unchanged = ctx.fetch(:reporter).build(token: ctx.fetch(:token), envelope: envelope,
                                             state_store: ctx.fetch(:post_merge), now: T0 + 11)
      assert_empty unchanged.fetch(:report).fetch("emitted_delta")

      item.problem = "A materially changed architectural problem"
      write_theses(ctx, item)
      changed = ctx.fetch(:reporter).build(token: ctx.fetch(:token), envelope: envelope,
                                           state_store: ctx.fetch(:post_merge), now: T0 + 12)
      assert_equal [ "fp-a" ], changed.fetch(:report).fetch("emitted_delta").map { |delta| delta.fetch("fingerprint") }
    end
  end

  def test_retry_collision_added_after_original_snapshot_keeps_intrinsic_bucket
    with_report_context do |ctx|
      item = thesis("accepted", "fp-new", collision: { "kind" => "collision_already_seen", "reference" => "fp-new" })
      write_theses(ctx, item)
      envelope = envelope_for(suppressed: [ item ])

      result = ctx.fetch(:reporter).build(token: ctx.fetch(:token), envelope: envelope,
                                          state_store: ctx.fetch(:post_merge), now: T0 + 10)

      assert_equal({ "accepted" => 1, "flagged" => 0, "suppressed" => 0 }, result.fetch(:report).fetch("totals"))
      assert_equal "accepted", result.fetch(:report).fetch("emitted_delta").first.fetch("bucket")
    end
  end

  def test_checkout_drift_and_missing_thesis_leave_merge_unprocessed
    with_report_context do |ctx|
      guard = ctx.fetch(:guard)
      guard.blocked = true
      error = assert_raises(Hive::RefactorPatrol::CheckoutGuard::Blocked) do
        ctx.fetch(:reporter).call(
          token: ctx.fetch(:token), envelope: envelope_for(ranked: [ thesis("missing", "fp") ]),
          state_store: ctx.fetch(:post_merge), guard: guard, snapshot: Object.new, now: T0 + 10
        )
      end
      assert_equal "checkout_moved", error.reason
      assert_equal "running", ctx.fetch(:post_merge).merge_record(ctx.dig(:token, "identity")).fetch("status")

      guard.blocked = false
      assert_raises(Hive::RefactorPatrol::PostMergeReporter::ReportError) do
        ctx.fetch(:reporter).call(
          token: ctx.fetch(:token), envelope: envelope_for(ranked: [ thesis("missing", "fp") ]),
          state_store: ctx.fetch(:post_merge), guard: guard, snapshot: Object.new, now: T0 + 11
        )
      end
      assert_equal "running", ctx.fetch(:post_merge).merge_record(ctx.dig(:token, "identity")).fetch("status")
    end
  end

  private

  def with_report_context(baseline: {})
    with_tmp_dir do |dir|
      @report_root = File.realpath(dir)
      state = Hive::RefactorPatrol::PostMergeStateStore.new(dir, project: "hive")
      state.initialize_at!(head_sha: "base", now: T0)
      state.open_batch!(
        head_sha: "merge",
        merges: [ { "pr_number" => 10, "merge_sha" => "merge", "base_sha" => "base",
                    "subject" => "Change (#10)", "changed_paths" => [ "lib/change.rb" ] } ],
        now: T0 + 1
      )
      identity = state.identity_for(10, "merge")
      state.reserve!(identity, fingerprint_snapshot: baseline, now: T0 + 2)
      token = {
        "project" => "hive",
        "analysis_root" => File.realpath(dir),
        "pinned_head" => "merge",
        "identity" => identity,
        "pr_number" => 10,
        "merge_sha" => "merge",
        "base_sha" => "base",
        "changed_paths" => [ "lib/change.rb" ],
        "scope" => { "kind" => "path", "values" => [ "lib" ], "fallback" => false },
        "started_at" => (T0 + 2).utc.iso8601
      }
      yield(
        root: dir,
        post_merge: state,
        refactor_state: Hive::RefactorPatrol::StateStore.new(dir),
        reporter: Hive::RefactorPatrol::PostMergeReporter.new(dir),
        guard: Guard.new,
        token: token
      )
    ensure
      @report_root = nil
    end
  end

  def write_theses(ctx, *items)
    items.each { |item| ctx.fetch(:refactor_state).write_thesis(item) }
  end

  def envelope_for(ranked: [], flagged: [], suppressed: [])
    {
      "schema" => "hive-refactor-patrol",
      "schema_version" => 1,
      "ok" => true,
      "project" => "hive",
      "project_root" => @report_root,
      "dry_run" => false,
      "features_mapped" => 1,
      "theses" => ranked.size - flagged.size,
      "ranked" => ranked.map do |item|
        { "id" => item.id, "feature_id" => item.feature_id, "score" => 1.0,
          "breakdown" => {}, "admissible" => item.admissible,
          "flagged" => Array(item.risk["flags"]), "advisories" => [] }
      end,
      "flagged_theses" => flagged.map { |item| { "id" => item.id, "reason" => "flagged" } },
      "suppressed" => suppressed.map do |item|
        { "id" => item.id, "reason" => item.collision.fetch("kind"), "reference" => item.collision.fetch("reference") }
      end,
      "last_scanned_sha" => "merge"
    }
  end

  def thesis(id, fingerprint, flags: [], collision: nil)
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout mixes validation and orchestration",
      cost: "Changes fan out",
      evidence: [ { "file" => "lib/change.rb", "signal" => "churn", "value" => 10 } ],
      proposed_refactor: "Extract checkout orchestration",
      feature_boundary: { "owned_files" => [ "lib/change.rb" ], "entrypoints" => [ "bin/hive" ] },
      expected_leverage: { "score" => 1.0, "breakdown" => { "churn" => 1.0 } },
      confidence: "high",
      risk: { "flags" => flags, "advisories" => [], "caps" => {}, "public_api_impact" => false,
              "public_api_details" => [], "cross_feature_impact" => false, "cross_feature_details" => [] },
      required_validation: { "commands" => [ "bundle exec rake test" ], "characterization_first" => false, "notes" => "" },
      admissible: true,
      admissibility_reason: "evidence-backed",
      follow_up_approval_state: "pending",
      fingerprint: fingerprint,
      collision: collision
    )
  end
end
