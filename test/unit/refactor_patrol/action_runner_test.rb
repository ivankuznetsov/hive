require "test_helper"
require "hive/refactor_patrol/action_runner"
require "hive/refactor_patrol/policy"

class RefactorPatrolActionRunnerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 10, 12, 0, 0)

  FakeFamilyOutcome = Struct.new(
    :status, :family_id, :reason, :ambiguous?, :dry_run,
    keyword_init: true
  )

  class FakeFamilyStore
    attr_reader :calls

    def initialize(ambiguous: false)
      @ambiguous = ambiguous
      @calls = []
    end

    def resolve(**arguments)
      @calls << arguments
      FakeFamilyOutcome.new(
        status: @ambiguous ? "family_ambiguous" : "new_family",
        family_id: @ambiguous ? nil : Hive::RefactorPatrol::SemanticFamily.id_for(
          Hive::RefactorPatrol::SemanticDescriptor.call(
            thesis: arguments.fetch(:thesis), source: arguments.fetch(:source)
          )
        ),
        reason: @ambiguous ? "structural_ambiguity" : "deterministic_descriptor",
        ambiguous?: @ambiguous,
        dry_run: arguments.fetch(:dry_run, false)
      )
    end
  end

  class FakeFixer
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def attempt(**arguments)
      @calls << arguments
      raise "missing fake fixer result" if @results.empty?

      @results.shift
    end
  end

  class FakePrOpener
    attr_reader :calls
    attr_accessor :before_create

    def initialize(*results, crash_after_intent: false)
      @results = results
      @crash_after_intent = crash_after_intent
      @calls = []
    end

    def open(**arguments)
      @calls << arguments.except(:record_intent)
      unless arguments.fetch(:creation_attempted)
        raise "intent was not persisted" unless arguments.fetch(:record_intent).call == true

        @before_create&.call
        raise "injected crash after intent" if @crash_after_intent
      end
      raise "missing fake PR result" if @results.empty?

      @results.shift
    end
  end

  class FakeIssueFiler
    attr_reader :calls
    attr_accessor :before_create

    def initialize(*results)
      @results = results
      @calls = []
    end

    def publish(**arguments)
      @calls << arguments.except(:record_intent)
      unless arguments.fetch(:creation_attempted)
        raise "intent was not persisted" unless arguments.fetch(:record_intent).call == true

        @before_create&.call
      end
      raise "missing fake issue result" if @results.empty?

      @results.shift
    end
  end

  def test_initializes_only_snapshotted_actions_and_reconstructs_language_neutral_theses
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => false, "issue_filing" => true),
        dispositions: dispositions(
          accepted: [ disposition(thesis(id: "go-fix", feature_id: "architecture-cmd-server",
                                                   files: %w[cmd/server/main.go internal/server/server.go])) ],
          flagged: [ disposition(
            thesis(id: "ts-issue", feature_id: "architecture-services-orders",
                   files: %w[src/orders/index.ts src/orders/service.ts], flags: [ "cross_feature_impact" ]),
            reasons: [ "cross_feature_impact" ]
          ) ]
        )
      )
      family_store = FakeFamilyStore.new
      cfg = config(auto_fix: true, issue_filing: true)
      runner = build_runner(
        dir,
        store: store,
        cfg: cfg,
        family_store: family_store,
        issue_filer: FakeIssueFiler.new(issue_result)
      )

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_equal [ "issue" ], result.actions.map { |action| action.fetch("kind") }
      assert_equal [ "ts-issue" ], family_store.calls.map { |call| call.fetch(:thesis).id }
      assert_equal %w[src/orders/index.ts src/orders/service.ts],
                   family_store.calls.first.fetch(:thesis).feature_boundary.fetch("owned_files")
      assert_empty runner.fixer.calls, "current auto-fix must not broaden a false snapshot"
    end
  end

  def test_processes_fix_before_related_issue_and_suppresses_issue_after_successful_pr
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted-1")) ])
      )
      order = []
      fixer = FakeFixer.new(validated_patch).tap do |fake|
        fake.define_singleton_method(:attempt) do |**arguments|
          order << :fix
          super(**arguments)
        end
      end
      opener = FakePrOpener.new(pr_result).tap do |fake|
        fake.before_create = -> { order << :pr }
      end
      filer = FakeIssueFiler.new(issue_result).tap do |fake|
        fake.before_create = -> { order << :issue }
      end
      runner = build_runner(
        dir, store: store, fixer: fixer, pr_opener: opener, issue_filer: filer
      )
      opener.before_create = lambda do
        action = store.read_job("job-1").fetch("actions").find { |item| item.fetch("kind") == "fix" }
        assert_equal validated_patch.commit_sha, action.dig("receipts", "patch", "commit_sha")
        order << :pr
      end

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_equal %i[fix pr], order
      assert_empty filer.calls
      assert_equal %w[issue_not_needed pr_opened], result.actions.map { |action| action.fetch("outcome") }.sort
      fix = result.actions.find { |action| action.fetch("kind") == "fix" }
      assert_equal true, fix.dig("receipts", "creation_intent", "payload").is_a?(Hash)
    end
  end

  def test_missing_action_policy_snapshot_fails_closed_without_effects
    with_tmp_dir do |dir|
      item = thesis(id: "accepted", fingerprint: "fp-accepted")
      store = write_classified_job(
        dir,
        policy: {
          "discovery" => true, "auto_fix" => true, "issue_filing" => true,
          "captured_at" => T0.iso8601
        },
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      runner = build_runner(dir, store: store)

      result = runner.run(job_id: "job-1")

      refute result.complete?
      assert_equal "policy_snapshot_missing", result.completeness.fetch("reason")
      assert_empty result.aggregate.fetch("actions")
      assert_empty runner.fixer.calls
      assert_empty runner.pr_opener.calls
      assert_empty runner.issue_filer.calls
    end
  end

  def test_changed_validation_command_revokes_an_existing_fix_snapshot
    with_tmp_dir do |dir|
      item = thesis(id: "accepted", fingerprint: "fp-accepted")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      current = config
      current["refactor_patrol"]["commands"]["test"] = "bin/test --changed"
      runner = build_runner(dir, store: store, cfg: current)

      result = runner.run(job_id: "job-1")

      refute result.complete?
      assert_equal "authority_revoked", result.actions.fetch(0).fetch("outcome")
      assert_empty runner.fixer.calls
      assert_empty runner.pr_opener.calls
    end
  end

  def test_deterministic_nonfix_outcome_can_file_one_strategic_issue_after_fix
    with_tmp_dir do |dir|
      item = thesis(id: "accepted-cap", flags: [ "caps_exceeded" ])
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      order = []
      fixer = FakeFixer.new(fix_result("caps_exceeded", terminal: true)).tap do |fake|
        fake.define_singleton_method(:attempt) do |**arguments|
          order << :fix
          super(**arguments)
        end
      end
      filer = FakeIssueFiler.new(issue_result).tap do |fake|
        fake.before_create = lambda do
          issue_action = store.read_job("job-1").fetch("actions").find { |action| action.fetch("kind") == "issue" }
          assert_equal "create_issue", issue_action.dig("receipts", "creation_intent", "payload", "operation")
          order << :issue
        end
      end
      runner = build_runner(dir, store: store, fixer: fixer, issue_filer: filer)

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_equal %i[fix issue], order
      assert_equal [ "caps_exceeded" ], filer.calls.first.fetch(:reasons)
      assert_match(/\Aissue-[a-f0-9]{64}\z/, filer.calls.first.fetch(:canonical_action_id))
      assert_equal %w[caps_exceeded issue_created], result.actions.map { |action| action.fetch("outcome") }.sort
    end
  end

  def test_transient_fix_retries_without_substituting_an_issue
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted-retry")) ])
      )
      fixer = FakeFixer.new(
        fix_result("fix_agent_failed", terminal: false),
        fix_result("no_diff", terminal: true)
      )
      filer = FakeIssueFiler.new(issue_result)
      runner = build_runner(dir, store: store, fixer: fixer, issue_filer: filer, backoff_sec: 0)

      first = runner.run(job_id: "job-1")
      refute first.complete?
      assert_equal "fix_agent_failed", first.actions.find { |action| action.fetch("kind") == "fix" }.fetch("outcome")
      assert_empty filer.calls

      second = runner.run(job_id: "job-1")
      assert second.complete?
      assert_equal "no_diff", second.actions.find { |action| action.fetch("kind") == "fix" }.fetch("outcome")
      assert_equal "issue_not_needed", second.actions.find { |action| action.fetch("kind") == "issue" }.fetch("outcome")
      assert_empty filer.calls
    end
  end

  def test_crash_after_pr_intent_retries_reconciliation_without_rerunning_fixer_or_creating_again
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted-crash")) ])
      )
      fixer = FakeFixer.new(validated_patch(fingerprint: "fp-accepted-crash"))
      crashing = FakePrOpener.new(crash_after_intent: true)
      runner = build_runner(
        dir, store: store, fixer: fixer, pr_opener: crashing, backoff_sec: 0
      )

      first = runner.run(job_id: "job-1")
      refute first.complete?
      assert_equal "remote_outcome_unknown", first.actions.first.fetch("outcome")
      assert store.read_job("job-1").dig("actions", 0, "receipts", "creation_intent")

      reconciling = FakePrOpener.new(pr_result)
      recovered = build_runner(
        dir, store: store, fixer: fixer, pr_opener: reconciling, backoff_sec: 0
      ).run(job_id: "job-1")

      assert recovered.complete?
      assert_equal 1, fixer.calls.size
      assert_equal true, reconciling.calls.first.fetch(:creation_attempted)
      assert_equal validated_patch.commit_sha, reconciling.calls.first.fetch(:patch).commit_sha
    end
  end

  def test_review_handoff_retry_reuses_the_persisted_patch_and_remote_intent
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted-handoff")) ])
      )
      fixer = FakeFixer.new(validated_patch(fingerprint: "fp-accepted-handoff"))
      pending = Hive::RefactorPatrol::PrOpener::Result.new(
        outcome: "review_handoff_pending",
        terminal: false,
        pr_url: "https://github.com/acme/polyglot/pull/99",
        receipts: {
          "creation_intent" => true,
          "pr_url" => "https://github.com/acme/polyglot/pull/99"
        }
      )
      opener = FakePrOpener.new(pending, pr_result)
      runner = build_runner(
        dir, store: store, fixer: fixer, pr_opener: opener, backoff_sec: 0
      )

      first = runner.run(job_id: "job-1")
      refute first.complete?
      assert_equal "review_handoff_pending", first.actions.first.fetch("outcome")

      second = runner.run(job_id: "job-1")
      assert second.complete?
      assert_equal 1, fixer.calls.size
      assert_equal false, opener.calls.first.fetch(:creation_attempted)
      assert_equal true, opener.calls.last.fetch(:creation_attempted)
      assert_equal validated_patch.commit_sha, opener.calls.last.fetch(:patch).commit_sha
    end
  end

  def test_trunk_drift_supersedes_patch_and_reruns_fixer_for_a_new_generation
    with_tmp_dir do |dir|
      item = thesis(id: "accepted-drift")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      first_patch = validated_patch(fingerprint: item.fingerprint)
      second_patch = validated_patch(
        fingerprint: item.fingerprint,
        publication_base_sha: "d" * 40,
        commit_sha: "f" * 40
      )
      fixer = FakeFixer.new(first_patch, second_patch)
      calls = []
      final_result = pr_result
      opener = Object.new
      opener.define_singleton_method(:open) do |**arguments|
        calls << arguments.except(:record_intent, :authorize_push)
        if calls.one?
          Hive::RefactorPatrol::PrOpener::Result.new(
            outcome: "trunk_drift_retry", terminal: false, receipts: {}
          )
        else
          raise "intent was not persisted" unless arguments.fetch(:record_intent).call == true
          final_result
        end
      end
      runner = build_runner(
        dir, store: store, fixer: fixer, pr_opener: opener, backoff_sec: 0
      )

      first = runner.run(job_id: "job-1")
      second = runner.run(job_id: "job-1")

      refute first.complete?
      assert_equal "trunk_drift_retry", first.actions.first.fetch("outcome")
      assert second.complete?
      assert_equal 2, fixer.calls.size
      assert_equal [ first_patch.commit_sha, second_patch.commit_sha ],
                   calls.map { |call| call.fetch(:patch).commit_sha }
      receipts = second.actions.first.fetch("receipts")
      assert_equal first_patch.commit_sha, receipts.dig("patch", "commit_sha")
      assert_equal second_patch.commit_sha, receipts.dig("patch_2", "commit_sha")
    end
  end

  def test_invalid_fresh_patch_identity_never_reaches_publication
    with_tmp_dir do |dir|
      item = thesis(id: "accepted-invalid")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      wrong = validated_patch(fingerprint: "another-action")
      opener = FakePrOpener.new(pr_result)

      result = build_runner(
        dir, store: store, fixer: FakeFixer.new(wrong), pr_opener: opener,
        backoff_sec: 0
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal "invalid_fixer_result", result.actions.first.fetch("outcome")
      assert_empty opener.calls
      assert_empty result.actions.first.fetch("receipts")
    end
  end

  def test_mismatched_creation_intent_cannot_continue_after_revocation
    with_tmp_dir do |dir|
      item = thesis(id: "accepted-intent")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      initialized = store.initialize_actions!(
        "job-1", specifications: [ { "thesis_id" => item.id, "kind" => "fix" } ],
        now: T0
      )
      action_id = initialized.fetch("actions").first.fetch("canonical_action_id")
      token = store.claim_action!("job-1", action_id, owner: "seed", now: T0)
      patch = validated_patch(fingerprint: item.fingerprint)
      store.record_patch_receipt!(
        token, receipt: JSON.parse(JSON.generate(patch.to_h)), now: T0
      )
      store.record_creation_intent!(
        token,
        intent: {
          "operation" => "create_pr", "canonical_action_id" => "fix-wrong",
          "repository" => "acme/polyglot", "branch" => patch.branch,
          "commit_sha" => patch.commit_sha
        },
        now: T0
      )
      store.release_action!(token, outcome: "seeded", now: T0, backoff_sec: 0)
      opener = FakePrOpener.new(pr_result)

      result = build_runner(
        dir, store: store, cfg: config(auto_fix: false),
        fixer: FakeFixer.new, pr_opener: opener, backoff_sec: 0
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal "invalid_creation_intent", result.actions.first.fetch("outcome")
      assert_empty opener.calls
    end
  end

  def test_terminal_pr_without_mandatory_handoff_proof_is_rejected
    with_tmp_dir do |dir|
      item = thesis(id: "accepted-proof")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      incomplete = Hive::RefactorPatrol::PrOpener::Result.new(
        outcome: "pr_opened", terminal: true,
        pr_url: "https://github.com/acme/polyglot/pull/99",
        receipts: { "pr_url" => "https://github.com/acme/polyglot/pull/99" }
      )

      result = build_runner(
        dir, store: store,
        fixer: FakeFixer.new(validated_patch(fingerprint: item.fingerprint)),
        pr_opener: FakePrOpener.new(incomplete), backoff_sec: 0
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal "invalid_action_result", result.actions.first.fetch("outcome")
    end
  end

  def test_successful_fix_suppresses_issue_for_another_thesis_in_the_same_family
    with_tmp_dir do |dir|
      accepted = thesis(id: "accepted-family")
      flagged = thesis(id: "flagged-family", flags: [ "cross_feature_impact" ])
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(
          accepted: [ disposition(accepted) ],
          flagged: [ disposition(flagged, reasons: [ "cross_feature_impact" ]) ]
        )
      )
      filer = FakeIssueFiler.new(issue_result)

      result = build_runner(
        dir, store: store,
        fixer: FakeFixer.new(validated_patch(fingerprint: accepted.fingerprint)),
        pr_opener: FakePrOpener.new(pr_result), issue_filer: filer
      ).run(job_id: "job-1")

      assert result.complete?
      assert_equal %w[issue_not_needed pr_opened], result.actions.map { |item| item.fetch("outcome") }.sort
      assert_equal 1, result.actions.map { |item| item["family_id"] }.compact.uniq.size
      assert_empty filer.calls
    end
  end

  def test_revocation_blocks_new_effects_but_allows_continuation_only_reconciliation
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted-revoked")) ])
      )
      cfg = config(auto_fix: false)
      fixer = FakeFixer.new(validated_patch(fingerprint: "fp-accepted-revoked"))
      runner = build_runner(dir, store: store, cfg: cfg, fixer: fixer)

      blocked = runner.run(job_id: "job-1")
      refute blocked.complete?
      assert_equal "authority_revoked", blocked.actions.first.fetch("outcome")
      assert_empty fixer.calls

      # Seed proof of an already-authorized external transaction, as if the
      # daemon restarted after the create request became ambiguous.
      cfg.dig("refactor_patrol", "auto_fix")["enabled"] = true
      active = runner.run(job_id: "job-1")
      refute active.complete?
      cfg.dig("refactor_patrol", "auto_fix")["enabled"] = false

      opener = FakePrOpener.new(pr_result)
      continued = build_runner(
        dir, store: store, cfg: cfg, fixer: fixer, pr_opener: opener, backoff_sec: 0
      ).run(job_id: "job-1")

      assert continued.complete?
      assert_equal true, opener.calls.first.fetch(:creation_attempted)
      assert_empty fixer.calls.drop(1)
    end
  end

  def test_linked_actions_only_reconcile_the_canonical_owner
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "first", fingerprint: "shared-fp")) ])
      )
      first = build_runner(
        dir, store: store,
        fixer: FakeFixer.new(fix_result("no_diff", terminal: true))
      ).run(job_id: "job-1")
      assert first.complete?

      write_classified_job(
        dir,
        job_id: "job-2",
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "second", fingerprint: "shared-fp")) ])
      )
      fixer = FakeFixer.new(validated_patch)
      opener = FakePrOpener.new(pr_result)

      linked = build_runner(
        dir, store: store, fixer: fixer, pr_opener: opener
      ).run(job_id: "job-2")

      assert linked.complete?
      assert_equal "job-1", linked.actions.first.fetch("owner_job_id")
      assert_equal "no_diff", linked.actions.first.fetch("outcome")
      assert_empty linked.actions.first.fetch("receipts")
      assert_empty fixer.calls
      assert_empty opener.calls
    end
  end

  def test_dry_run_previews_family_routing_with_zero_writes_or_effects
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(
          flagged: [ disposition(
            thesis(id: "dry-issue", flags: [ "dependency_change" ]),
            reasons: [ "dependency_change" ]
          ) ]
        )
      )
      before = File.binread(job_path(store, "job-1"))
      family_store = FakeFamilyStore.new
      runner = build_runner(dir, store: store, family_store: family_store)

      result = runner.run(job_id: "job-1", dry_run: true)

      refute result.complete?
      assert result.dry_run
      assert_equal "would_initialize", result.actions.first.fetch("outcome")
      assert_equal true, family_store.calls.first.fetch(:dry_run)
      assert_equal before, File.binread(job_path(store, "job-1"))
      assert_empty store.read_job("job-1").fetch("actions")
      assert_empty runner.fixer.calls
      assert_empty runner.pr_opener.calls
      assert_empty runner.issue_filer.calls
    end
  end

  def test_dry_run_never_resumes_an_already_initialized_action
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "dry-resume")) ])
      )
      store.initialize_actions!(
        "job-1",
        specifications: [ { "thesis_id" => "dry-resume", "kind" => "fix" } ],
        now: T0
      )
      before = File.binread(job_path(store, "job-1"))
      fixer = FakeFixer.new(validated_patch)
      opener = FakePrOpener.new(pr_result)
      runner = build_runner(dir, store: store, fixer: fixer, pr_opener: opener)

      result = runner.run(job_id: "job-1", dry_run: true)

      assert result.dry_run
      refute result.complete?
      assert_equal "queued", result.actions.first.fetch("outcome")
      assert_equal "would_resume", result.actions.first.fetch("preview")
      assert_equal before, File.binread(job_path(store, "job-1"))
      assert_empty fixer.calls
      assert_empty opener.calls
    end
  end

  def test_discovery_revocation_pauses_uninitialized_jobs_without_family_or_action_writes
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(
          flagged: [ disposition(
            thesis(id: "paused", flags: [ "dependency_change" ]),
            reasons: [ "dependency_change" ]
          ) ]
        )
      )
      before = File.binread(job_path(store, "job-1"))
      family_store = FakeFamilyStore.new
      runner = build_runner(
        dir, store: store, cfg: config(discovery: false), family_store: family_store
      )

      result = runner.run(job_id: "job-1")

      refute result.complete?
      assert_equal "discovery_revoked", result.completeness.fetch("reason")
      assert_empty family_store.calls
      assert_equal before, File.binread(job_path(store, "job-1"))
    end
  end

  def test_ambiguous_family_fails_closed_without_completing_or_freezing_the_action_snapshot
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(
          flagged: [ disposition(
            thesis(id: "ambiguous", flags: [ "cross_feature_impact" ]),
            reasons: [ "cross_feature_impact" ]
          ) ]
        )
      )
      family_store = FakeFamilyStore.new(ambiguous: true)
      runner = build_runner(dir, store: store, family_store: family_store)

      first = runner.run(job_id: "job-1")
      second = runner.run(job_id: "job-1")

      refute first.complete?
      refute second.complete?
      assert_equal "family_ambiguous", first.completeness.fetch("reason")
      assert_equal "family_ambiguous", first.actions.first.fetch("outcome")
      assert_empty store.read_job("job-1").fetch("actions")
      assert_equal 2, family_store.calls.size
    end
  end

  private

  def build_runner(dir, store:, cfg: config, family_store: FakeFamilyStore.new,
                   fixer: FakeFixer.new, pr_opener: FakePrOpener.new,
                   issue_filer: FakeIssueFiler.new, backoff_sec: 0)
    Hive::RefactorPatrol::ActionRunner.new(
      dir,
      cfg: cfg,
      job_store: store,
      family_store: family_store,
      fixer: fixer,
      pr_opener: pr_opener,
      issue_filer: issue_filer,
      owner: "test-runner",
      clock: -> { T0 },
      lease_sec: 60,
      backoff_sec: backoff_sec
    )
  end

  def write_classified_job(dir, job_id: "job-1", policy:, dispositions:)
    store = Hive::RefactorPatrol::JobStore.new(dir)
    store.write_job!(
      {
        "schema" => "hive-refactor-patrol-job",
        "schema_version" => 2,
        "job_id" => job_id,
        "source" => source(job_id == "job-1" ? 7 : 8),
        "analysis_sha" => "c" * 40,
        "policy" => policy,
        "state" => "classified",
        "complete" => false,
        "dispositions" => dispositions,
        "feature_results" => [],
        "review_errors" => [],
        "zero_reason" => nil,
        "attempts" => [ { "number" => 1, "outcome" => "classified" } ],
        "actions" => [],
        "created_at" => T0.iso8601,
        "updated_at" => T0.iso8601
      }
    )
    store
  end

  def source(number)
    {
      "url" => "https://github.com/acme/polyglot/pull/#{number}",
      "number" => number,
      "repository" => "acme/polyglot",
      "registration" => "polyglot",
      "base_branch" => "main",
      "base_sha" => "a" * 40,
      "merge_sha" => number == 7 ? "b" * 40 : "d" * 40
    }
  end

  def snapshot_policy(overrides = {})
    Hive::RefactorPatrol::Policy.capture(config, now: T0).merge(
      "auto_fix" => false,
      "issue_filing" => false
    ).merge(overrides)
  end

  def config(discovery: true, auto_fix: true, issue_filing: true)
    {
      "default_branch" => "main",
      "refactor_patrol" => {
        "enabled" => discovery,
        "min_confidence" => "medium",
        "auto_fix" => { "enabled" => auto_fix, "agent" => "codex" },
        "issue_filing" => { "enabled" => issue_filing, "min_leverage_score" => 0.5 },
        "commands" => {
          "docs" => nil, "format" => nil, "lint" => nil,
          "typecheck" => nil, "test" => "bin/test"
        },
        "caps" => {
          "single_feature_only" => true,
          "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false,
          "max_files" => 8,
          "max_diff_lines" => 400,
          "allow_cross_feature" => false
        }
      }
    }
  end

  def dispositions(accepted: [], flagged: [], suppressed: [])
    { "accepted" => accepted, "flagged" => flagged, "suppressed" => suppressed }
  end

  def disposition(item, reasons: [])
    {
      "id" => item.id,
      "feature_id" => item.feature_id,
      "fingerprint" => item.fingerprint,
      "score" => item.expected_leverage.fetch("score"),
      "admissible" => item.admissible,
      "reasons" => reasons,
      "thesis" => item.to_h
    }
  end

  def thesis(id:, fingerprint: nil, feature_id: "architecture-services-checkout",
             files: %w[src/checkout/index.ts src/checkout/service.ts], flags: [])
    Hive::RefactorPatrol::Thesis.new(
      id: id,
      feature_id: feature_id,
      feature: "Checkout policy",
      problem: "Validation policy is duplicated across checkout handlers",
      cost: "Changes repeatedly touch routing and authorization",
      evidence: files.map.with_index do |file, index|
        { "file" => file, "line" => index + 1, "claim" => "Checkout policy is repeated" }
      end,
      proposed_refactor: "Consolidate checkout validation policy behind one decision",
      feature_boundary: { "owned_files" => files, "entrypoints" => [ files.first ] },
      feature_hotspot: {},
      expected_leverage: {
        "score" => 0.8,
        "drivers" => [
          { "signal" => "coupling", "relief" => 0.5, "mechanism" => "Centralize checkout policy" }
        ]
      },
      confidence: "high",
      risk: { "flags" => flags, "advisories" => [] },
      required_validation: { "commands" => [ "test" ] },
      admissible: true,
      admissibility_reason: "anchored",
      follow_up_approval_state: "pending",
      fingerprint: fingerprint || "fp-#{id}"
    )
  end

  def validated_patch(fingerprint: "fp-accepted-1", publication_base_sha: "c" * 40,
                      commit_sha: "e" * 40)
    token = fingerprint.gsub(/[^a-zA-Z0-9]+/, "")[0, 16]
    Hive::RefactorPatrol::Fixer::Result.new(
      outcome: "validated",
      terminal: false,
      branch: "hive-refactor/job-1-#{token}",
      worktree_path: "/tmp/refactor-worktree",
      analysis_sha: "c" * 40,
      publication_base_sha: publication_base_sha,
      commit_sha: commit_sha,
      validation: {
        "passed" => true,
        "commands" => [ { "name" => "test", "exit_code" => 0 } ]
      },
      changed_paths: [ "src/checkout/service.ts" ],
      diff_lines: 12,
      details: {}
    )
  end

  def fix_result(outcome, terminal:)
    Hive::RefactorPatrol::Fixer::Result.new(
      outcome: outcome,
      terminal: terminal,
      analysis_sha: "c" * 40,
      details: {}
    )
  end

  def pr_result
    Hive::RefactorPatrol::PrOpener::Result.new(
      outcome: "pr_opened",
      terminal: true,
      pr_url: "https://github.com/acme/polyglot/pull/99",
      review_task_path: "/review/task",
      receipts: {
        "creation_intent" => true,
        "pr_url" => "https://github.com/acme/polyglot/pull/99",
        "review_task_path" => "/review/task"
      }
    )
  end

  def issue_result
    Hive::RefactorPatrol::IssueFiler::Result.new(
      outcome: "issue_created",
      terminal: true,
      issue_url: "https://github.com/acme/polyglot/issues/99",
      receipts: {
        "creation_intent" => true,
        "issue_url" => "https://github.com/acme/polyglot/issues/99"
      }
    )
  end

  def job_path(store, job_id)
    File.join(store.root, "jobs", "#{job_id}.json")
  end
end
