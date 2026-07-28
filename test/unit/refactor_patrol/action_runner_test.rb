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
        persist_publication!(arguments)

        @before_create&.call
        raise "injected crash after intent" if @crash_after_intent
      end
      raise "missing fake PR result" if @results.empty?

      @results.shift
    end

    private

    def persist_publication!(arguments)
      action_id = arguments.fetch(:canonical_action_id)
      repository = arguments.fetch(:source).fetch("repository")
      patch = arguments.fetch(:patch)
      callback = arguments.fetch(:record_intent)
      phases = {
        "push_intent" => Hive::RefactorPatrol::PrOpener.push_intent_payload(
          canonical_action_id: action_id,
          repository: repository,
          branch: patch.branch,
          commit_sha: patch.commit_sha,
          expected_remote_oid: nil
        ),
        "push_complete" => Hive::RefactorPatrol::PrOpener.push_complete_payload(
          canonical_action_id: action_id,
          repository: repository,
          branch: patch.branch,
          commit_sha: patch.commit_sha
        ),
        "pr_create_intent" => Hive::RefactorPatrol::PrOpener.pr_create_intent_payload(
          canonical_action_id: action_id,
          repository: repository,
          branch: patch.branch,
          commit_sha: patch.commit_sha
        )
      }
      phases.each do |phase, payload|
        raise "#{phase} was not persisted" unless callback.call(phase: phase, payload: payload) == true
      end
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

  class BareRemoteRecoveryGh
    attr_reader :pushes, :created

    def initialize(remote_path, crash_after_push: false)
      @remote_path = remote_path
      @crash_after_push = crash_after_push
      @pushes = []
      @created = []
    end

    def ensure_authenticated!(_cfg, host:) = host == "github.com"

    def lookup_prs_for_branch(*, **) = []

    def origin_push_url(_path, cfg:, managed: false) = @remote_path

    def repository_identity_from_remote(_url)
      { "repository" => "acme/polyglot", "host" => "github.com" }
    end

    def remote_branch_oid(_path, branch, **)
      out, _err, status = Open3.capture3(
        "git", "--git-dir", @remote_path,
        "rev-parse", "--verify", "refs/heads/#{branch}"
      )
      status.success? ? out.strip : nil
    end

    def push_branch!(path, branch, expected_remote_oid:, expected_remote_absent:, **)
      @pushes << {
        expected_remote_oid: expected_remote_oid,
        expected_remote_absent: expected_remote_absent
      }
      expected = expected_remote_absent ? "" : expected_remote_oid
      raise "missing remote lease expectation" if expected.nil?

      _out, err, status = Open3.capture3(
        "git", "-C", path, "push",
        "--force-with-lease=refs/heads/#{branch}:#{expected}",
        @remote_path, "#{branch}:refs/heads/#{branch}"
      )
      raise Hive::GhError, "test push failed: #{err}" unless status.success?

      Process.kill("KILL", Process.pid) if @crash_after_push
      true
    end

    def capture3(*args, chdir:, cfg:)
      @created << { args: args, chdir: chdir, cfg: cfg }
      [
        "https://github.com/acme/polyglot/pull/99\n",
        "",
        Hive::Gh::CommandStatus.new(exitstatus: 0)
      ]
    end

    def remote_head(branch)
      remote_branch_oid(nil, branch)
    end
  end

  class RecoveryGateway
    attr_reader :verified

    def initialize = @verified = []

    def verify_pr_identity!(url, **identity)
      @verified << identity.merge(url: url)
      true
    end
  end

  class RecoveryHandoff
    attr_reader :calls

    def initialize = @calls = []

    def enqueue(**arguments)
      @calls << arguments
      "/review/recovered-patch"
    end
  end

  class LateProofCatalog
    attr_reader :resolve_calls, :rebuild_calls

    def initialize(proof_after:, &proof_builder)
      @proof_after = proof_after
      @proof_builder = proof_builder
      @resolve_calls = 0
      @rebuild_calls = 0
    end

    def resolve(action_ids:, **)
      @resolve_calls += 1
      return {} if @resolve_calls < @proof_after

      action_ids.to_h { |action_id| [ action_id, @proof_builder.call(action_id) ] }
    end

    def rebuild!
      @rebuild_calls += 1
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
        issue_filer: FakeIssueFiler.new(issue_result, issue_result)
      )

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_equal %w[issue issue], result.actions.map { |action| action.fetch("kind") }
      assert_equal %w[go-fix ts-issue], family_store.calls.map { |call| call.fetch(:thesis).id }.sort
      orders = family_store.calls.find { |call| call.fetch(:thesis).id == "ts-issue" }
      assert_equal %w[src/orders/index.ts src/orders/service.ts],
                   orders.fetch(:thesis).feature_boundary.fetch("owned_files")
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
      attempt = fix.dig("receipts", "publication_attempts").values.first
      assert_equal "create_pr", attempt.dig("pr_create_intent", "operation")
    end
  end

  def test_mixed_job_creates_one_pr_one_issue_and_keeps_suppression_exactly_once
    with_tmp_dir do |dir|
      accepted = thesis(id: "accepted-mixed")
      flagged = thesis(
        id: "flagged-mixed", feature_id: "architecture-search",
        files: [ "src/search/index.ts" ], flags: [ "cross_feature_impact" ]
      )
      suppressed = thesis(id: "suppressed-mixed", fingerprint: "already-terminal")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(
          accepted: [ disposition(accepted) ],
          flagged: [ disposition(flagged, reasons: [ "cross_feature_impact" ]) ],
          suppressed: [ disposition(suppressed, reasons: [ "collision_already_seen" ]) ]
        )
      )
      fixer = FakeFixer.new(validated_patch(fingerprint: accepted.fingerprint))
      opener = FakePrOpener.new(pr_result)
      filer = FakeIssueFiler.new(issue_result)
      runner = build_runner(
        dir, store: store, fixer: fixer, pr_opener: opener, issue_filer: filer
      )

      first = runner.run(job_id: "job-1")
      second = runner.run(job_id: "job-1")

      assert first.complete?
      assert second.complete?
      assert_equal 1, fixer.calls.size
      fix_action = first.actions.find { |action| action.fetch("kind") == "fix" }
      assert_equal fix_action.fetch("canonical_action_id"),
                   fixer.calls.first.fetch(:canonical_action_id)
      assert_equal "hive-refactor/#{fix_action.fetch('canonical_action_id')}",
                   opener.calls.first.fetch(:patch).branch
      assert_equal 1, opener.calls.size
      assert_equal 1, filer.calls.size
      assert_equal %w[issue_created issue_not_needed pr_opened],
                   first.actions.map { |action| action.fetch("outcome") }.sort
      assert_equal [ "suppressed-mixed" ], first.aggregate.dig("dispositions", "suppressed")
                                                    .map { |item| item.fetch("id") }
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

  def test_revoked_uncontinued_action_records_phase_backoff_instead_of_hot_looping
    with_tmp_dir do |dir|
      item = thesis(id: "revoked-backoff", fingerprint: "fp-revoked-backoff")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      current = config(auto_fix: false)
      runner = build_runner(
        dir, store: store, cfg: current,
        fixer: FakeFixer.new, backoff_sec: 60, authority_backoff_sec: 3600
      )

      first = runner.run(job_id: "job-1")
      second = runner.run(job_id: "job-1")

      refute first.complete?
      assert_equal "authority_revoked", first.actions.first.fetch("outcome")
      assert_equal "action_block", first.aggregate.fetch("attempts").last.fetch("kind")
      assert_equal "authority_revoked", first.aggregate.fetch("attempts").last.fetch("reason")
      assert_equal (T0 + 3600).iso8601,
                   first.aggregate.fetch("attempts").last.fetch("next_eligible_at")
      assert_equal "action_backoff", second.completeness.fetch("reason")
      assert_equal 1, second.aggregate.fetch("attempts").count { |attempt| attempt["kind"] == "action_block" }
      assert_empty runner.fixer.calls
    end
  end

  def test_missing_owner_process_identity_blocks_before_an_action_claim
    with_tmp_dir do |dir|
      item = thesis(id: "missing-process-identity")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      runner = build_runner(dir, store: store)
      runner.instance_variable_set(:@owner_process_start_time, nil)

      result = runner.run(job_id: "job-1")

      refute result.complete?
      assert_equal "process_identity_unavailable", result.completeness.fetch("reason")
      assert_empty result.aggregate.fetch("actions")
      assert_equal "process_identity_unavailable", result.aggregate.fetch("attempts").last.fetch("reason")
    end
  end

  def test_deterministic_validation_failure_can_file_one_strategic_issue_after_fix
    with_tmp_dir do |dir|
      item = thesis(id: "accepted-validation-failure")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      order = []
      fixer = FakeFixer.new(fix_result("validation_failed", terminal: true)).tap do |fake|
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
      assert_equal [ "validation_failed" ], filer.calls.first.fetch(:reasons)
      assert_match(/\Aissue-[a-f0-9]{64}\z/, filer.calls.first.fetch(:canonical_action_id))
      assert_equal %w[issue_created validation_failed], result.actions.map { |action| action.fetch("outcome") }.sort
    end
  end

  def test_docs_missing_validation_routes_to_issue_without_invoking_fixer
    with_tmp_dir do |dir|
      item = thesis(
        id: "docs-missing-validation",
        feature_id: "documentation-docs-root",
        files: [ "docs/architecture.md" ],
        flags: [ "missing_docs_validation" ]
      )
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(
          flagged: [ disposition(item, reasons: [ "missing_docs_validation" ]) ]
        )
      )
      filer = FakeIssueFiler.new(issue_result)
      runner = build_runner(dir, store: store, issue_filer: filer)

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_empty runner.fixer.calls
      assert_empty runner.pr_opener.calls
      assert_equal [ "missing_docs_validation" ], filer.calls.first.fetch(:reasons)
      assert_equal [ "issue_created" ], result.actions.map { |action| action.fetch("outcome") }
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

  def test_transient_fix_error_details_persist_as_generation_scoped_release_evidence
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted-evidence")) ])
      )
      failed = Hive::RefactorPatrol::Fixer::Result.new(
        outcome: "fix_error", terminal: false, analysis_sha: "c" * 40,
        details: { "error" => "Hive::GitError: registered checkout must be clean before refactor fix" }
      )
      fixer = FakeFixer.new(failed, fix_result("no_diff", terminal: true))
      runner = build_runner(dir, store: store, fixer: fixer, backoff_sec: 0)

      first = runner.run(job_id: "job-1")

      refute first.complete?
      action = first.actions.find { |entry| entry.fetch("kind") == "fix" }
      assert_equal "fix_error", action.fetch("outcome")
      evidence = action.fetch("receipts").fetch("fix_release_1")
      assert_equal "fix_error", evidence.fetch("outcome")
      assert_includes evidence.fetch("details"), "registered checkout must be clean"

      second = runner.run(job_id: "job-1")
      assert second.complete?
      assert_equal "no_diff", second.actions.find { |entry| entry.fetch("kind") == "fix" }.fetch("outcome")
    end
  end

  def test_closed_unmerged_refactor_pr_routes_the_accepted_thesis_to_an_issue
    with_tmp_dir do |dir|
      item = thesis(id: "closed-pr")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      closed = Hive::RefactorPatrol::PrOpener::Result.new(
        outcome: "closed_without_merge", terminal: true,
        pr_url: "https://github.com/acme/polyglot/pull/99",
        receipts: { "pr_url" => "https://github.com/acme/polyglot/pull/99" }
      )
      filer = FakeIssueFiler.new(issue_result)

      result = build_runner(
        dir, store: store,
        fixer: FakeFixer.new(validated_patch(fingerprint: item.fingerprint)),
        pr_opener: FakePrOpener.new(closed), issue_filer: filer
      ).run(job_id: "job-1")

      assert result.complete?
      assert_equal 1, filer.calls.size
      assert_includes filer.calls.first.fetch(:reasons), "closed_without_merge"
      assert_equal %w[closed_without_merge issue_created],
                   result.actions.map { |action| action.fetch("outcome") }.sort
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
      attempts = store.read_job("job-1").dig("actions", 0, "receipts", "publication_attempts")
      assert attempts.values.first["pr_create_intent"]

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

  def test_pushed_fix_resumes_at_pr_create_from_durable_phase_receipts
    with_tmp_dir do |dir|
      item = thesis(id: "phase-resume", fingerprint: "fp-phase-resume")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      patch = validated_patch(fingerprint: item.fingerprint)
      calls = 0
      test_case = self
      success = pr_result
      opener = Object.new
      opener.define_singleton_method(:open) do |record_intent:, publication_state:,
                                                    canonical_action_id:, source:, patch:, **|
        calls += 1
        if calls == 1
          push = Hive::RefactorPatrol::PrOpener.push_intent_payload(
            canonical_action_id: canonical_action_id,
            repository: source.fetch("repository"), branch: patch.branch,
            commit_sha: patch.commit_sha, expected_remote_oid: nil
          )
          complete = Hive::RefactorPatrol::PrOpener.push_complete_payload(
            canonical_action_id: canonical_action_id,
            repository: source.fetch("repository"), branch: patch.branch,
            commit_sha: patch.commit_sha
          )
          raise "push intent failed" unless record_intent.call(
            phase: "push_intent", payload: push
          )
          raise "push receipt failed" unless record_intent.call(
            phase: "push_complete", payload: complete
          )
          Hive::RefactorPatrol::PrOpener::Result.new(
            outcome: "authority_revoked", terminal: false, receipts: {}
          )
        else
          test_case.assert_equal %w[push_complete push_intent], publication_state.keys.sort
          create = Hive::RefactorPatrol::PrOpener.pr_create_intent_payload(
            canonical_action_id: canonical_action_id,
            repository: source.fetch("repository"), branch: patch.branch,
            commit_sha: patch.commit_sha
          )
          raise "PR intent failed" unless record_intent.call(
            phase: "pr_create_intent", payload: create
          )
          success
        end
      end
      runner = build_runner(
        dir, store: store, fixer: FakeFixer.new(patch),
        pr_opener: opener, backoff_sec: 0
      )

      first = runner.run(job_id: "job-1")
      second = runner.run(job_id: "job-1")

      refute first.complete?
      assert second.complete?
      assert_equal 1, runner.fixer.calls.size
      receipts = second.actions.first.fetch("receipts")
      attempt = receipts.fetch("publication_attempts").values.first
      assert_equal "push_branch", attempt.dig("push_intent", "operation")
      assert_equal "push_branch_complete", attempt.dig("push_complete", "operation")
      assert_equal "create_pr", attempt.dig("pr_create_intent", "operation")
    end
  end

  def test_effect_gateway_wraps_remote_sinks_and_records_evidence_after_job_settlement
    with_tmp_dir do |dir|
      item = thesis(id: "effect-order", fingerprint: "fp-effect-order")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      operations = []
      recording = Module.new
      recording.define_method(:prepare_effect!) do |intent, **options|
        operations << [ :effect_intent, intent.sink ]
        super(intent, **options)
      end
      recording.define_method(:finish_action!) do |token, **arguments|
        result = super(token, **arguments)
        operations << :job_settled
        result
      end
      store.singleton_class.prepend(recording)

      durable_evidence = Hive::Modules::Migration::EvidenceStore.new(
        root: File.join(dir, "effect-evidence")
      )
      evidence = Object.new
      evidence.define_singleton_method(:append_capture) do |capture|
        operations << :capture
        durable_evidence.append_capture(capture)
      end
      evidence.define_singleton_method(:append_receipt) do |receipt|
        operations << [ :effect_evidence, receipt.intent.sink ]
        durable_evidence.append_receipt(receipt)
      end

      patch = validated_patch(fingerprint: item.fingerprint)
      success = pr_result
      opener = Object.new
      opener.define_singleton_method(:open) do |record_intent:, execute_effect:,
                                                execute_handoff:,
                                                canonical_action_id:, source:, patch:, **|
        push_intent = Hive::RefactorPatrol::PrOpener.push_intent_payload(
          canonical_action_id: canonical_action_id,
          repository: source.fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha, expected_remote_oid: nil
        )
        push_complete = Hive::RefactorPatrol::PrOpener.push_complete_payload(
          canonical_action_id: canonical_action_id,
          repository: source.fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha
        )
        pr_intent = Hive::RefactorPatrol::PrOpener.pr_create_intent_payload(
          canonical_action_id: canonical_action_id,
          repository: source.fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha
        )
        raise "push intent failed" unless record_intent.call(
          phase: "push_intent", payload: push_intent
        )
        execute_effect.call(phase: "push_intent", payload: push_intent) do
          operations << :push_sink
        end
        raise "push completion failed" unless record_intent.call(
          phase: "push_complete", payload: push_complete
        )
        raise "PR intent failed" unless record_intent.call(
          phase: "pr_create_intent", payload: pr_intent
        )
        execute_effect.call(phase: "pr_create_intent", payload: pr_intent) do
          operations << :pr_sink
          success.pr_url
        end
        execute_handoff.call(
          phase: "review_handoff",
          payload: {
            "pr_url" => success.pr_url,
            "job_id" => "job-1",
            "canonical_action_id" => canonical_action_id,
            "commit_sha" => patch.commit_sha
          }
        ) do
          operations << :handoff_sink
          success.review_task_path
        end
        success
      end

      result = build_runner(
        dir,
        store: store,
        fixer: FakeFixer.new(patch),
        pr_opener: opener,
        evidence_store: evidence
      ).run(job_id: "job-1")

      assert result.complete?
      intents = operations.filter_map do |operation|
        operation.last if operation.is_a?(Array) &&
                          operation.first == :effect_intent
      end
      assert_equal 1, intents.count("branch")
      assert_equal 1, intents.count("pull_request")
      assert_equal 1, intents.count("review_handoff")
      assert_operator intents.count("action"), :>=, 4
      assert_operator(
        operations.index([ :effect_intent, "branch" ]),
        :<,
        operations.index(:push_sink)
      )
      assert_operator(
        operations.index([ :effect_intent, "review_handoff" ]),
        :<,
        operations.index(:handoff_sink)
      )
      assert_operator(
        operations.index(:job_settled),
        :<,
        operations.rindex([ :effect_evidence, "action" ])
      )
      receipt_sinks = durable_evidence.receipts.map do |receipt|
        receipt.intent.sink
      end
      assert_equal 1, receipt_sinks.count("branch")
      assert_equal 1, receipt_sinks.count("pull_request")
      assert_equal 1, receipt_sinks.count("review_handoff")
      assert_operator receipt_sinks.count("action"), :>=, 4
      assert durable_evidence.receipts.all? { |receipt| receipt.status == "committed" }
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
      success_opener = FakePrOpener.new(final_result)
      opener = Object.new
      opener.define_singleton_method(:open) do |**arguments|
        calls << arguments.except(:record_intent, :authorize_push)
        if calls.one?
          Hive::RefactorPatrol::PrOpener::Result.new(
            outcome: "trunk_drift_retry", terminal: false,
            observed_head_sha: "d" * 40, receipts: {}
          )
        else
          success_opener.open(**arguments)
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
      assert_equal [ [], [] ],
                   calls.map { |call| call.fetch(:superseded_patch_commits) }
      receipts = second.actions.first.fetch("receipts")
      assert_equal first_patch.commit_sha, receipts.dig("patch", "commit_sha")
      assert_equal second_patch.commit_sha, receipts.dig("patch_2", "commit_sha")
      refute receipts.key?("commit_sha")
      refute receipts.key?("publication_base_sha")
    end
  end

  def test_process_crash_after_push_recovers_dead_claim_and_replaces_only_proven_remote_oid
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      patch_root = File.join(root, "patch")
      remote = File.join(root, "remote.git")
      FileUtils.mkdir_p(repo)
      run!("git", "init", "--bare", "--quiet", remote)
      run!("git", "-C", repo, "init", "-b", "main", "--quiet")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      run!("git", "-C", repo, "config", "user.name", "Test")
      run!("git", "-C", repo, "config", "commit.gpgsign", "false")
      File.write(File.join(repo, "README.md"), "base\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "base", "--quiet")
      analysis_sha = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      item = thesis(id: "post-push-drift")
      store = write_classified_job(
        repo,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ]),
        analysis_sha: analysis_sha
      )
      action_id = store.canonical_action_id(
        repository: "acme/polyglot", host: "github.com",
        kind: "fix", identity: item.fingerprint
      )
      branch = "hive-refactor/#{action_id}"
      run!("git", "-C", repo, "worktree", "add", "-b", branch, patch_root, analysis_sha, "--quiet")
      FileUtils.mkdir_p(File.join(patch_root, "src", "checkout"))
      File.write(File.join(patch_root, "src", "checkout", "service.ts"), "first patch\n")
      run!("git", "-C", patch_root, "add", "src/checkout/service.ts")
      run!("git", "-C", patch_root, "commit", "-m", "first patch", "--quiet")
      first_commit = run!("git", "-C", patch_root, "rev-parse", "HEAD").strip
      first_patch = recovery_patch(
        branch: branch, worktree_path: patch_root, analysis_sha: analysis_sha,
        publication_base_sha: analysis_sha, commit_sha: first_commit
      )

      fixer_calls = []
      test_case = self
      replacement_fixer = Object.new
      replacement_fixer.define_singleton_method(:calls) { fixer_calls }
      replacement_fixer.define_singleton_method(:attempt) do |**arguments|
        fixer_calls << arguments
        current_base = test_case.send(:run!, "git", "-C", repo, "rev-parse", "HEAD").strip
        test_case.send(:run!, "git", "-C", patch_root, "reset", "--hard", current_base, "--quiet")
        FileUtils.mkdir_p(File.join(patch_root, "src", "checkout"))
        File.write(File.join(patch_root, "src", "checkout", "service.ts"), "replacement patch\n")
        test_case.send(:run!, "git", "-C", patch_root, "add", "src/checkout/service.ts")
        test_case.send(:run!, "git", "-C", patch_root, "commit", "-m", "replacement patch", "--quiet")
        replacement = test_case.send(:run!, "git", "-C", patch_root, "rev-parse", "HEAD").strip
        test_case.send(
          :recovery_patch,
          branch: branch, worktree_path: patch_root, analysis_sha: analysis_sha,
          publication_base_sha: current_base, commit_sha: replacement
        )
      end

      gateway = RecoveryGateway.new
      handoff = RecoveryHandoff.new
      build_opener = lambda do |gh|
        Hive::RefactorPatrol::PrOpener.new(
          repo, cfg: config, gh: gh, github_gateway: gateway,
          review_handoff: handoff,
          diff_reader: ->(_patch) { "diff --git a/src/checkout/service.ts b/src/checkout/service.ts\n+ok\n" }
        )
      end

      child_pid = fork do
        child_gh = BareRemoteRecoveryGh.new(remote, crash_after_push: true)
        build_runner(
          repo,
          store: Hive::RefactorPatrol::JobStore.new(repo),
          fixer: FakeFixer.new(first_patch),
          pr_opener: build_opener.call(child_gh),
          backoff_sec: 0
        ).run(job_id: "job-1")
        exit! 91
      end
      _waited, child_status = Process.wait2(child_pid)
      assert child_status.signaled?, "child unexpectedly exited #{child_status.inspect}"
      assert_equal Signal.list.fetch("KILL"), child_status.termsig

      remote_gh = BareRemoteRecoveryGh.new(remote)
      assert_equal first_commit, remote_gh.remote_head(branch)
      interrupted = Hive::RefactorPatrol::JobStore.new(repo).read_job("job-1")
      interrupted_action = interrupted.fetch("actions").first
      first_id = Hive::RefactorPatrol::PublicationAttempt.id_for(
        publication_base_sha: analysis_sha, commit_sha: first_commit
      )
      assert_equal "push_branch",
                   interrupted_action.dig(
                     "receipts", "publication_attempts", first_id, "push_intent", "operation"
                   )
      assert_nil interrupted_action.dig(
        "receipts", "publication_attempts", first_id, "push_complete"
      )
      assert_equal child_pid, interrupted_action.fetch("claims").last.fetch("owner_pid")
      assert_equal "claimed", interrupted_action.fetch("claims").last.fetch("state")

      File.write(File.join(repo, "README.md"), "trunk advanced\n")
      run!("git", "-C", repo, "add", "README.md")
      run!("git", "-C", repo, "commit", "-m", "advance trunk", "--quiet")
      advanced_head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      superseded = build_runner(
        repo,
        store: Hive::RefactorPatrol::JobStore.new(repo),
        fixer: replacement_fixer,
        pr_opener: build_opener.call(remote_gh),
        backoff_sec: 0,
        clock: -> { T0 + 61 }
      ).run(job_id: "job-1")
      refute superseded.complete?
      assert_equal "trunk_drift_retry", superseded.actions.first.fetch("outcome")
      assert_empty fixer_calls
      recovered_claims = superseded.actions.first.fetch("claims")
      assert_equal "superseded", recovered_claims.first.fetch("state")
      assert_equal "expired_claim_resolved", recovered_claims.first.fetch("outcome")

      completed = build_runner(
        repo,
        store: Hive::RefactorPatrol::JobStore.new(repo),
        fixer: replacement_fixer,
        pr_opener: build_opener.call(remote_gh),
        backoff_sec: 0,
        clock: -> { T0 + 62 }
      ).run(job_id: "job-1")
      assert completed.complete?, completed.to_h.inspect
      assert_equal "pr_opened", completed.actions.first.fetch("outcome")
      assert_equal 1, fixer_calls.size
      assert_equal 1, remote_gh.pushes.size
      assert_equal first_commit, remote_gh.pushes.first.fetch(:expected_remote_oid)
      assert_equal 1, remote_gh.created.size
      assert_equal 1, gateway.verified.size
      assert_equal 1, handoff.calls.size

      receipts = completed.actions.first.fetch("receipts")
      attempts = receipts.fetch("publication_attempts")
      assert_equal 2, attempts.size
      replacement_commit = receipts.dig("patch_2", "commit_sha")
      second_id = Hive::RefactorPatrol::PublicationAttempt.id_for(
        publication_base_sha: advanced_head, commit_sha: replacement_commit
      )
      assert_equal advanced_head, attempts.dig(first_id, "superseded", "observed_head_sha")
      assert_equal first_commit, attempts.dig(first_id, "push_complete", "remote_oid")
      assert_nil attempts.dig(second_id, "superseded")
      assert_equal "create_pr", attempts.dig(second_id, "pr_create_intent", "operation")
      assert_equal replacement_commit, remote_gh.remote_head(branch)
      assert_equal "/review/recovered-patch", completed.actions.first.dig("receipts", "review_task_path")
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

  def test_pr_create_fence_rejects_replaced_claim_after_intent
    with_tmp_dir do |dir|
      item = thesis(id: "stale-pr-create")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      creates = 0
      success = pr_result
      opener = Object.new
      opener.define_singleton_method(:open) do |record_intent:, authorize_create:, canonical_action_id:,
                                               source:, patch:, **|
        push_intent = Hive::RefactorPatrol::PrOpener.push_intent_payload(
          canonical_action_id: canonical_action_id,
          repository: source.fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha, expected_remote_oid: nil
        )
        push_complete = Hive::RefactorPatrol::PrOpener.push_complete_payload(
          canonical_action_id: canonical_action_id,
          repository: source.fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha
        )
        create_intent = Hive::RefactorPatrol::PrOpener.pr_create_intent_payload(
          canonical_action_id: canonical_action_id,
          repository: source.fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha
        )
        raise "push intent failed" unless record_intent.call(phase: "push_intent", payload: push_intent)
        raise "push complete failed" unless record_intent.call(phase: "push_complete", payload: push_complete)
        raise "PR intent failed" unless record_intent.call(phase: "pr_create_intent", payload: create_intent)
        action = store.read_job("job-1").fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") == canonical_action_id
        end
        claim = action.fetch("claims").last
        old_token = {
          job_id: "job-1", canonical_action_id: canonical_action_id,
          owner: claim.fetch("owner"), generation: claim.fetch("generation")
        }
        store.release_action!(old_token, outcome: "interleaved", now: T0, backoff_sec: 0)
        store.claim_action!("job-1", canonical_action_id, owner: "replacement", now: T0)
        creates += 1 if authorize_create.call
        success
      end

      result = build_runner(
        dir, store: store,
        fixer: FakeFixer.new(validated_patch(fingerprint: item.fingerprint)),
        pr_opener: opener
      ).run(job_id: "job-1")

      assert_equal "stale_claim", result.completeness.fetch("reason")
      assert_equal 0, creates
      attempts = store.read_job("job-1").dig("actions", 0, "receipts", "publication_attempts")
      assert attempts.values.first["pr_create_intent"]
    end
  end

  def test_external_fence_reloads_current_config_during_a_long_fix
    with_tmp_dir do |dir|
      item = thesis(id: "live-config-revocation")
      initial = config(auto_fix: true)
      current = JSON.parse(JSON.generate(initial))
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      requests = 0
      opener = Object.new
      opener.define_singleton_method(:open) do |authorize_push:, **|
        raise "initial fence unexpectedly denied" unless authorize_push.call

        current.fetch("refactor_patrol").fetch("auto_fix")["enabled"] = false
        requests += 1 if authorize_push.call
        Hive::RefactorPatrol::PrOpener::Result.new(
          outcome: "authority_revoked", terminal: false, receipts: {}
        )
      end

      result = build_runner(
        dir, store: store, cfg: initial,
        fixer: FakeFixer.new(validated_patch(fingerprint: item.fingerprint)),
        pr_opener: opener, config_loader: ->(_root) { current }
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal 0, requests
      assert_equal "authority_revoked", result.actions.first.fetch("outcome")
    end
  end

  def test_issue_create_fence_rejects_replaced_claim_after_intent
    with_tmp_dir do |dir|
      item = thesis(id: "stale-issue-create", flags: [ "cross_feature_impact" ])
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(flagged: [ disposition(item, reasons: [ "cross_feature_impact" ]) ])
      )
      creates = 0
      success = issue_result
      filer = Object.new
      filer.define_singleton_method(:publish) do |record_intent:, authorize_create:, canonical_action_id:, **|
        raise "intent failed" unless record_intent.call == true
        action = store.read_job("job-1").fetch("actions").find do |candidate|
          candidate.fetch("canonical_action_id") == canonical_action_id
        end
        claim = action.fetch("claims").last
        old_token = {
          job_id: "job-1", canonical_action_id: canonical_action_id,
          owner: claim.fetch("owner"), generation: claim.fetch("generation")
        }
        store.release_action!(old_token, outcome: "interleaved", now: T0, backoff_sec: 0)
        store.claim_action!("job-1", canonical_action_id, owner: "replacement", now: T0)
        creates += 1 if authorize_create.call
        success
      end

      result = build_runner(dir, store: store, issue_filer: filer).run(job_id: "job-1")

      assert_equal "stale_claim", result.completeness.fetch("reason")
      assert_equal 0, creates
      assert store.read_job("job-1").dig("actions", 0, "receipts", "creation_intent")
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

  def test_repository_drift_continues_only_the_action_with_remote_evidence
    with_tmp_dir do |dir|
      continued = thesis(id: "continued-fix", fingerprint: "fp-continued-fix")
      untouched = thesis(
        id: "untouched-issue", feature_id: "architecture-search",
        flags: [ "cross_feature_impact" ]
      )
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(
          accepted: [ disposition(continued) ],
          flagged: [ disposition(untouched, reasons: [ "cross_feature_impact" ]) ]
        )
      )
      family_id = Hive::RefactorPatrol::SemanticFamily.id_for(
        Hive::RefactorPatrol::SemanticDescriptor.call(
          thesis: untouched, source: source(7)
        )
      )
      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => continued.id, "kind" => "fix" },
          { "thesis_id" => untouched.id, "kind" => "issue", "family_id" => family_id }
        ],
        now: T0
      )
      fix = initialized.fetch("actions").find { |action| action.fetch("kind") == "fix" }
      token = store.claim_action!("job-1", fix.fetch("canonical_action_id"), owner: "seed", now: T0)
      patch = validated_patch(fingerprint: continued.fingerprint)
      store.record_patch_receipt!(token, receipt: JSON.parse(JSON.generate(patch.to_h)), now: T0)
      store.record_creation_intent!(
        token,
        intent: Hive::RefactorPatrol::PrOpener.pr_create_intent_payload(
          canonical_action_id: fix.fetch("canonical_action_id"),
          repository: source(7).fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha
        ),
        now: T0
      )
      store.record_action_receipt!(
        token,
        key: "push_complete",
        value: Hive::RefactorPatrol::PrOpener.push_complete_payload(
          canonical_action_id: fix.fetch("canonical_action_id"),
          repository: source(7).fetch("repository"), branch: patch.branch,
          commit_sha: patch.commit_sha
        ),
        now: T0
      )
      store.release_action!(token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0)
      opener = FakePrOpener.new(pr_result)
      filer = FakeIssueFiler.new(issue_result)

      result = build_runner(
        dir, store: store, fixer: FakeFixer.new, pr_opener: opener,
        issue_filer: filer,
        repository_resolver: ->(*) { { "repository" => "other/repository", "host" => "github.com" } }
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal 1, opener.calls.size
      assert_equal true, opener.calls.first.fetch(:creation_attempted)
      assert_equal false, opener.calls.first.fetch(:authorize_push).call
      assert_equal false, opener.calls.first.fetch(:authorize_create).call
      assert_empty filer.calls
      assert_equal "pr_opened", result.actions.find { |action| action.fetch("kind") == "fix" }.fetch("outcome")
      assert_equal "queued", result.actions.find { |action| action.fetch("kind") == "issue" }.fetch("outcome")
      assert_equal "repository_identity_drift", result.aggregate.fetch("attempts").last.fetch("reason")
      assert_equal "repository_identity_drift",
                   result.completeness.fetch("runner_events").last.fetch("outcome")
    end
  end

  def test_duplicate_repository_owner_blocks_before_action_initialization
    with_tmp_dir do |dir|
      other = File.join(File.dirname(dir), "duplicate-owner")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "duplicate-owner")) ])
      )
      cfg = config
      entries = [
        { "name" => "polyglot", "path" => dir },
        { "name" => "other", "path" => other }
      ]
      ownership = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { entries }, config_loader: ->(_path) { cfg },
        identity_resolver: ->(_entry, _current_cfg) {
          { "repository" => "acme/polyglot", "host" => "github.com" }
        }
      )
      fixer = FakeFixer.new(fix_result("no_diff", terminal: true))
      opener = FakePrOpener.new(pr_result)
      filer = FakeIssueFiler.new(issue_result)

      result = build_runner(
        dir, store: store, cfg: cfg, fixer: fixer, pr_opener: opener,
        issue_filer: filer, repository_ownership: ownership
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal "duplicate_repository_registration", result.completeness.fetch("reason")
      assert_empty result.actions, "ownership must block before the write-once action catalog is initialized"
      assert_empty fixer.calls
      assert_empty opener.calls
      assert_empty filer.calls
    end
  end

  def test_duplicate_owner_blocks_an_existing_remote_intent_from_reconciliation
    with_tmp_dir do |dir|
      other = File.join(File.dirname(dir), "duplicate-continuation-owner")
      item = thesis(id: "duplicate-continuation", flags: [ "cross_feature_impact" ])
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(
          flagged: [ disposition(item, reasons: [ "cross_feature_impact" ]) ]
        )
      )
      family_id = Hive::RefactorPatrol::SemanticFamily.id_for(
        Hive::RefactorPatrol::SemanticDescriptor.call(thesis: item, source: source(7))
      )
      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => item.id, "kind" => "issue", "family_id" => family_id }
        ],
        now: T0
      )
      action = initialized.fetch("actions").first
      token = store.claim_action!(
        "job-1", action.fetch("canonical_action_id"), owner: "seed", now: T0
      )
      store.record_creation_intent!(
        token,
        intent: Hive::RefactorPatrol::IssueFiler.create_intent_payload(
          canonical_action_id: action.fetch("canonical_action_id"),
          repository: source(7).fetch("repository"), family_id: family_id,
          thesis_fingerprint: item.fingerprint
        ),
        now: T0
      )
      store.release_action!(token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0)
      cfg = config
      ownership = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: lambda {
          [
            { "name" => "polyglot", "path" => dir },
            { "name" => "other", "path" => other }
          ]
        },
        config_loader: ->(_path) { cfg },
        identity_resolver: ->(_entry, _current_cfg) {
          { "repository" => "acme/polyglot", "host" => "github.com" }
        }
      )
      filer = FakeIssueFiler.new(issue_result)

      result = build_runner(
        dir, store: store, cfg: cfg, issue_filer: filer,
        repository_ownership: ownership
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal "duplicate_repository_registration", result.completeness.fetch("reason")
      assert_empty filer.calls
      assert_equal "remote_outcome_unknown", result.actions.first.fetch("outcome")
    end
  end

  def test_duplicate_added_after_intent_is_caught_by_the_final_issue_fence
    with_tmp_dir do |dir|
      other = File.join(File.dirname(dir), "late-duplicate-owner")
      flagged = thesis(id: "late-duplicate", flags: [ "cross_feature_impact" ])
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(
          flagged: [ disposition(flagged, reasons: [ "cross_feature_impact" ]) ]
        )
      )
      cfg = config
      entries = [ { "name" => "polyglot", "path" => dir } ]
      ownership = Hive::RefactorPatrol::RepositoryOwnership.new(
        registry: -> { entries }, config_loader: ->(_path) { cfg },
        identity_resolver: ->(_entry, _current_cfg) {
          { "repository" => "acme/polyglot", "host" => "github.com" }
        }
      )
      remote_requests = 0
      filer = Object.new
      filer.define_singleton_method(:publish) do |**arguments|
        return Hive::RefactorPatrol::IssueFiler::Result.new(
          outcome: "authority_revoked", terminal: false, receipts: {}
        ) unless arguments.fetch(:authorize_create).call

        arguments.fetch(:record_intent).call
        entries << { "name" => "other", "path" => other }
        if arguments.fetch(:authorize_create).call
          remote_requests += 1
          Hive::RefactorPatrol::IssueFiler::Result.new(
            outcome: "issue_created", terminal: true,
            issue_url: "https://github.com/acme/polyglot/issues/99", receipts: {}
          )
        else
          Hive::RefactorPatrol::IssueFiler::Result.new(
            outcome: "authority_revoked", terminal: false, receipts: {}
          )
        end
      end

      result = build_runner(
        dir, store: store, cfg: cfg, issue_filer: filer,
        repository_ownership: ownership
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal 0, remote_requests
      assert_equal "authority_revoked", result.actions.first.fetch("outcome")
      assert result.actions.first.dig("receipts", "creation_intent")
    end
  end

  def test_repository_drift_reconciles_an_issue_before_blocking_an_unstarted_fix
    with_tmp_dir do |dir|
      untouched = thesis(id: "untouched-fix", fingerprint: "fp-untouched-fix")
      continued = thesis(
        id: "continued-issue", feature_id: "architecture-search",
        flags: [ "cross_feature_impact" ]
      )
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(
          accepted: [ disposition(untouched) ],
          flagged: [ disposition(continued, reasons: [ "cross_feature_impact" ]) ]
        )
      )
      family_id = Hive::RefactorPatrol::SemanticFamily.id_for(
        Hive::RefactorPatrol::SemanticDescriptor.call(
          thesis: continued, source: source(7)
        )
      )
      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => untouched.id, "kind" => "fix" },
          { "thesis_id" => continued.id, "kind" => "issue", "family_id" => family_id }
        ],
        now: T0
      )
      issue = initialized.fetch("actions").find { |action| action.fetch("kind") == "issue" }
      token = store.claim_action!("job-1", issue.fetch("canonical_action_id"), owner: "seed", now: T0)
      store.record_creation_intent!(
        token,
        intent: Hive::RefactorPatrol::IssueFiler.create_intent_payload(
          canonical_action_id: issue.fetch("canonical_action_id"),
          repository: source(7).fetch("repository"), family_id: family_id,
          thesis_fingerprint: continued.fingerprint
        ),
        now: T0
      )
      store.release_action!(token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0)
      filer = FakeIssueFiler.new(issue_result)
      fixer = FakeFixer.new(fix_result("no_diff", terminal: true))

      result = build_runner(
        dir, store: store, fixer: fixer, issue_filer: filer,
        repository_resolver: ->(*) {
          { "repository" => "other/repository", "host" => "github.com" }
        }
      ).run(job_id: "job-1")

      refute result.complete?
      assert_equal 1, filer.calls.size
      assert_empty fixer.calls
      assert_equal "issue_created",
                   result.actions.find { |action| action.fetch("kind") == "issue" }.fetch("outcome")
      assert_equal "queued",
                   result.actions.find { |action| action.fetch("kind") == "fix" }.fetch("outcome")
      assert_equal "repository_identity_drift", result.aggregate.fetch("attempts").last.fetch("reason")
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

  def test_expired_action_claim_is_reclaimed_after_dead_owner_is_proven
    with_tmp_dir do |dir|
      item = thesis(id: "expired-owner")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      initialized = store.initialize_actions!(
        "job-1", specifications: [ { "thesis_id" => item.id, "kind" => "fix" } ],
        now: T0 - 180
      )
      action_id = initialized.fetch("actions").first.fetch("canonical_action_id")
      store.claim_action!(
        "job-1", action_id, owner: "crashed-runner",
        now: T0 - 120, lease_sec: 60,
        owner_pid: 999_999_999, owner_process_start_time: "dead-owner"
      )

      result = build_runner(
        dir, store: store,
        fixer: FakeFixer.new(fix_result("no_diff", terminal: true))
      ).run(job_id: "job-1")

      assert result.complete?
      claims = store.read_job("job-1").dig("actions", 0, "claims")
      assert_equal %w[superseded complete], claims.map { |claim| claim.fetch("state") }
      assert_equal "expired_claim_resolved", claims.first.fetch("outcome")
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

  def test_dry_run_preserves_repository_state_worktrees_refs_and_external_effect_snapshot
    with_tmp_git_repo do |repo|
      accepted = thesis(id: "dry-fix")
      flagged = thesis(
        id: "dry-issue-snapshot", feature_id: "architecture-search",
        files: [ "src/search/index.ts" ], flags: [ "cross_feature_impact" ]
      )
      store = write_classified_job(
        repo,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(
          accepted: [ disposition(accepted) ],
          flagged: [ disposition(flagged, reasons: [ "cross_feature_impact" ]) ]
        )
      )
      fixer = FakeFixer.new(validated_patch(fingerprint: accepted.fingerprint))
      opener = FakePrOpener.new(pr_result)
      filer = FakeIssueFiler.new(issue_result)
      runner = build_runner(
        repo, store: store, fixer: fixer, pr_opener: opener, issue_filer: filer
      )
      before = repository_snapshot(repo, store)

      result = runner.run(job_id: "job-1", dry_run: true)

      assert result.dry_run
      assert_equal before, repository_snapshot(repo, store)
      assert_empty fixer.calls
      assert_empty opener.calls
      assert_empty filer.calls
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
      family_store = FakeFamilyStore.new
      runner = build_runner(
        dir, store: store, cfg: config(discovery: false), family_store: family_store
      )

      result = runner.run(job_id: "job-1")

      refute result.complete?
      assert_equal "discovery_revoked", result.completeness.fetch("reason")
      assert_empty family_store.calls
      aggregate = store.read_job("job-1")
      assert_empty aggregate.fetch("actions")
      assert_equal "discovery_revoked", aggregate.fetch("attempts").last.fetch("reason")
    end
  end

  def test_dry_run_reports_discovery_revocation_without_writing_report_only_job
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy,
        dispositions: dispositions
      )
      path = job_path(store, "job-1")
      before = File.binread(path)

      result = build_runner(
        dir, store: store, cfg: config(discovery: false)
      ).run(job_id: "job-1", dry_run: true)

      assert result.dry_run
      refute result.complete?
      assert_equal "discovery_revoked", result.completeness.fetch("reason")
      assert_equal false, result.completeness.fetch("would_complete")
      assert_equal before, File.binread(path)
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

  def test_reuses_exact_cross_registration_pr_proof_without_fix_or_remote_effects
    with_tmp_dir do |root|
      old_root = File.join(root, "old")
      new_root = File.join(root, "new")
      state_home = File.join(root, "state")
      item = thesis(id: "shared-pr", fingerprint: "fp-shared-pr")
      policy = snapshot_policy("auto_fix" => true)
      old_store = write_classified_job(
        old_root,
        policy: policy,
        dispositions: dispositions(accepted: [ disposition(item) ]),
        registration: "old"
      )
      action_id = finish_foreign_action(
        old_store,
        thesis_id: item.id,
        kind: "fix",
        outcome: "pr_opened",
        receipts: {
          "pr_url" => "https://github.com/acme/polyglot/pull/91",
          "review_task_path" => File.join(
            old_root, ".hive-state", "stages", "6-review", "review-task"
          )
        }
      )
      new_store = write_classified_job(
        new_root,
        job_id: "job-2",
        policy: policy,
        dispositions: dispositions(accepted: [ disposition(item) ]),
        registration: "new"
      )
      entries = [
        { "name" => "old", "path" => old_root },
        { "name" => "new", "path" => new_root }
      ]
      catalog = Hive::RefactorPatrol::CanonicalActionCatalog.new(
        state_home: state_home, registry: -> { entries }, clock: -> { T0 }
      )
      runner = build_runner(
        new_root,
        store: new_store,
        fixer: FakeFixer.new,
        pr_opener: FakePrOpener.new,
        canonical_action_catalog: catalog
      )
      before = File.binread(job_path(new_store, "job-2"))

      preview = runner.run(job_id: "job-2", dry_run: true)

      assert_equal "would_link_terminal", preview.actions.first.fetch("outcome")
      assert_equal "pr_opened", preview.actions.first.fetch("linked_outcome")
      assert_equal before, File.binread(job_path(new_store, "job-2"))
      refute File.exist?(catalog.path)

      result = runner.run(job_id: "job-2")

      assert result.complete?
      action = result.actions.first
      assert_equal action_id, action.fetch("canonical_action_id")
      assert_equal "pr_opened", action.fetch("outcome")
      assert_equal "old", action.dig("receipts", "canonical_action_link", "owner", "registration")
      assert_equal "https://github.com/acme/polyglot/pull/91", action.dig("receipts", "pr_url")
      assert_empty runner.fixer.calls
      assert_empty runner.pr_opener.calls
    end
  end

  def test_reuses_exact_cross_registration_issue_proof_without_filing_again
    with_tmp_dir do |root|
      old_root = File.join(root, "old")
      new_root = File.join(root, "new")
      item = thesis(
        id: "shared-issue",
        fingerprint: "fp-shared-issue",
        flags: [ "cross_feature_impact" ]
      )
      policy = snapshot_policy("issue_filing" => true)
      classified = dispositions(
        flagged: [ disposition(item, reasons: [ "cross_feature_impact" ]) ]
      )
      old_store = write_classified_job(
        old_root, policy: policy, dispositions: classified, registration: "old"
      )
      family_id = FakeFamilyStore.new.resolve(
        thesis: item, source: source(7, registration: "old"), dry_run: false
      ).family_id
      action_id = finish_foreign_action(
        old_store,
        thesis_id: item.id,
        kind: "issue",
        family_id: family_id,
        outcome: "issue_created",
        receipts: { "issue_url" => "https://github.com/acme/polyglot/issues/73" }
      )
      new_store = write_classified_job(
        new_root,
        job_id: "job-2",
        policy: policy,
        dispositions: classified,
        registration: "new"
      )
      catalog = Hive::RefactorPatrol::CanonicalActionCatalog.new(
        state_home: File.join(root, "state"),
        registry: -> {
          [
            { "name" => "old", "path" => old_root },
            { "name" => "new", "path" => new_root }
          ]
        },
        clock: -> { T0 }
      )
      runner = build_runner(
        new_root,
        store: new_store,
        family_store: FakeFamilyStore.new,
        issue_filer: FakeIssueFiler.new,
        canonical_action_catalog: catalog
      )

      result = runner.run(job_id: "job-2")

      assert result.complete?
      action = result.actions.first
      assert_equal action_id, action.fetch("canonical_action_id")
      assert_equal "issue_created", action.fetch("outcome")
      assert_equal "old", action.dig("receipts", "canonical_action_link", "owner", "registration")
      assert_equal "https://github.com/acme/polyglot/issues/73", action.dig("receipts", "issue_url")
      assert_empty runner.issue_filer.calls
    end
  end

  def test_late_terminal_proof_blocks_the_final_external_effect_and_fails_closed_durably
    with_tmp_dir do |dir|
      item = thesis(id: "late-proof", fingerprint: "fp-late-proof")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      catalog = LateProofCatalog.new(proof_after: 3) do |action_id|
        terminal_proof(
          action_id,
          project_root: "/foreign/project",
          receipts: {
            "pr_url" => "https://github.com/acme/polyglot/pull/81",
            "review_task_path" => "/foreign/project/.hive-state/stages/6-review/review-task"
          }
        )
      end
      remote_effects = 0
      opener = Object.new
      opener.define_singleton_method(:open) do |authorize_push:, **|
        if authorize_push.call.equal?(true)
          remote_effects += 1
          raise "late proof did not fence the remote effect"
        end
        Hive::RefactorPatrol::PrOpener::Result.new(
          outcome: "authority_revoked", terminal: false, receipts: {}
        )
      end
      runner = build_runner(
        dir,
        store: store,
        fixer: FakeFixer.new(validated_patch(fingerprint: item.fingerprint)),
        pr_opener: opener,
        canonical_action_catalog: catalog,
        backoff_sec: 0
      )

      first = runner.run(job_id: "job-1")
      second = runner.run(job_id: "job-1")

      refute first.complete?
      assert_equal "authority_revoked", first.actions.first.fetch("outcome")
      assert_equal 0, remote_effects
      refute second.complete?
      assert_equal "canonical_action_proof_unresolved", second.completeness.fetch("reason")
      assert_equal "canonical_action_proof_unresolved",
                   second.aggregate.fetch("attempts").last.fetch("reason")
    end
  end

  def test_terminal_proof_that_arrives_after_initialization_materializes_before_claiming
    with_tmp_dir do |dir|
      item = thesis(id: "late-before-claim", fingerprint: "fp-late-before-claim")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      catalog = LateProofCatalog.new(proof_after: 2) do |action_id|
        terminal_proof(
          action_id,
          project_root: "/foreign/project",
          receipts: {
            "pr_url" => "https://github.com/acme/polyglot/pull/82",
            "review_task_path" => "/foreign/project/.hive-state/stages/6-review/review-task"
          }
        )
      end
      runner = build_runner(
        dir,
        store: store,
        fixer: FakeFixer.new,
        pr_opener: FakePrOpener.new,
        canonical_action_catalog: catalog
      )

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_equal "pr_opened", result.actions.first.fetch("outcome")
      assert_empty result.actions.first.fetch("claims")
      assert_equal "canonical_action_linked",
                   result.completeness.fetch("runner_events").first.fetch("outcome")
      assert_empty runner.fixer.calls
      assert_empty runner.pr_opener.calls
    end
  end

  def test_catalog_error_at_the_external_fence_blocks_the_effect
    with_tmp_dir do |dir|
      item = thesis(id: "fence-catalog-error", fingerprint: "fp-fence-catalog-error")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      calls = 0
      catalog = Object.new
      catalog.define_singleton_method(:resolve) do |**|
        calls += 1
        if calls >= 3
          raise Hive::RefactorPatrol::CanonicalActionCatalog::ProofUnresolved,
                "archive unavailable"
        end

        {}
      end
      catalog.define_singleton_method(:rebuild!) { nil }
      remote_effects = 0
      opener = Object.new
      opener.define_singleton_method(:open) do |authorize_push:, **|
        remote_effects += 1 if authorize_push.call.equal?(true)
        Hive::RefactorPatrol::PrOpener::Result.new(
          outcome: "authority_revoked", terminal: false, receipts: {}
        )
      end
      runner = build_runner(
        dir,
        store: store,
        fixer: FakeFixer.new(validated_patch(fingerprint: item.fingerprint)),
        pr_opener: opener,
        canonical_action_catalog: catalog
      )

      result = runner.run(job_id: "job-1")

      refute result.complete?
      assert_equal 0, remote_effects
      assert_equal "canonical_action_proof_unresolved",
                   result.completeness.fetch("runner_events").first.fetch("outcome")
    end
  end

  def test_catalog_refresh_failure_is_reported_without_losing_terminal_job_state
    with_tmp_dir do |dir|
      item = thesis(id: "refresh-failure", fingerprint: "fp-refresh-failure")
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      catalog = Object.new
      catalog.define_singleton_method(:resolve) { |**| {} }
      catalog.define_singleton_method(:rebuild!) do
        raise Hive::RefactorPatrol::CanonicalActionCatalog::ProofUnresolved,
              "archive unavailable"
      end
      runner = build_runner(
        dir,
        store: store,
        fixer: FakeFixer.new(fix_result("no_diff", terminal: true)),
        canonical_action_catalog: catalog
      )

      result = runner.run(job_id: "job-1")

      assert result.complete?
      assert_equal "no_diff", result.actions.first.fetch("outcome")
      assert_equal "canonical_action_catalog_refresh_failed",
                   result.completeness.fetch("runner_events").first.fetch("outcome")
    end
  end

  def test_result_serialization_and_default_repository_resolution_are_explicit
    result = Hive::RefactorPatrol::ActionRunner::Result.new(
      aggregate: { "job_id" => "job-1" }, actions: [],
      completeness: { "complete" => true }, dry_run: true
    )
    assert_equal "job-1", result.to_h.dig("aggregate", "job_id")
    assert result.complete

    with_tmp_dir do |dir|
      expected = { "repository" => "acme/polyglot", "host" => "github.com" }
      test = self
      current_config = config
      resolver = lambda do |root, cfg:|
        test.assert_equal dir, root
        test.assert_equal current_config, cfg
        expected
      end
      with_replaced_singleton_method(Hive::Gh, :repository_identity, resolver) do
        runner = Hive::RefactorPatrol::ActionRunner.new(
          dir, cfg: current_config, owner: "runner", canonical_action_catalog: false
        )
        assert_equal expected,
                     runner.instance_variable_get(:@repository_resolver).call(dir, current_config)
      end
    end
  end

  def test_dry_run_reports_repository_ownership_block_without_initializing_actions
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted")) ])
      )
      ownership = Object.new
      ownership.define_singleton_method(:call) do |**|
        Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
          authority: :blocked, reason: "duplicate_repository_registration", evidence: {}
        )
      end
      runner = build_runner(dir, store: store, repository_ownership: ownership)

      result = runner.run(job_id: "job-1", dry_run: true)

      assert_equal "duplicate_repository_registration", result.completeness.fetch("reason")
      assert_empty store.read_job("job-1").fetch("actions")
    end
  end

  def test_discovery_revocation_between_planning_and_initialization_is_fenced
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted")) ])
      )
      reads = 0
      gate_reader = lambda do
        reads += 1
        { discovery: reads == 1, auto_fix: true, issue_filing: true }
      end
      runner = build_runner(dir, store: store, gate_reader: gate_reader)

      result = runner.run(job_id: "job-1")

      assert_equal "discovery_revoked", result.completeness.fetch("reason")
      assert_empty store.read_job("job-1").fetch("actions")
    end
  end

  def test_family_store_failure_is_reported_without_freezing_an_action_snapshot
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("issue_filing" => true),
        dispositions: dispositions(flagged: [
          disposition(thesis(id: "issue", flags: [ "cross_feature_impact" ]),
                      reasons: [ "cross_feature_impact" ])
        ])
      )
      family_store = Object.new
      family_store.define_singleton_method(:resolve) { |**| raise IOError, "family state unavailable" }
      runner = build_runner(dir, store: store, family_store: family_store)

      result = runner.run(job_id: "job-1")

      assert_equal "family_resolution_failed", result.completeness.fetch("reason")
      assert_includes result.actions.first.fetch("error"), "family state unavailable"
      assert_empty store.read_job("job-1").fetch("actions")
    end
  end

  def test_snapshot_reconstruction_reports_missing_and_malformed_theses
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir, policy: snapshot_policy,
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted")) ])
      )
      runner = build_runner(dir, store: store)
      aggregate = store.read_job("job-1")

      missing = JSON.parse(JSON.generate(aggregate))
      missing.dig("dispositions", "accepted", 0).delete("thesis")
      _entries, errors = runner.send(:reconstruct_entries, missing)
      assert_equal "invalid_thesis_snapshot", errors.first.fetch("outcome")
      assert_includes errors.first.fetch("error"), "missing immutable"

      malformed = JSON.parse(JSON.generate(aggregate))
      malformed.dig("dispositions", "accepted", 0, "thesis").delete("problem")
      _entries, errors = runner.send(:reconstruct_entries, malformed)
      assert_equal "invalid_thesis_snapshot", errors.first.fetch("outcome")
    end
  end

  def test_snapshot_reconstruction_promotes_legacy_size_only_findings
    with_tmp_dir do |dir|
      item = thesis(
        id: "formerly-oversized", fingerprint: "fp-formerly-oversized",
        flags: [ "exceeds_max_files", "exceeds_max_diff_lines" ]
      )
      stored = disposition(
        item, reasons: [ "exceeds_max_files", "exceeds_max_diff_lines" ]
      )
      store = write_classified_job(
        dir, policy: snapshot_policy,
        dispositions: dispositions(flagged: [ stored ])
      )

      entries, errors = build_runner(dir, store: store).send(
        :reconstruct_entries, store.read_job("job-1")
      )

      assert_empty errors
      assert_empty entries.fetch("flagged")
      recovered = entries.fetch("accepted").fetch(0)
      assert_equal "accepted", recovered.fetch(:disposition)
      assert_empty recovered.dig(:item, "reasons")
      assert_empty recovered.fetch(:thesis).risk.fetch("flags")

      guarded = thesis(
        id: "still-guarded", fingerprint: "fp-still-guarded",
        flags: [ "exceeds_max_files", "public_api_impact" ]
      )
      aggregate = store.read_job("job-1")
      aggregate.fetch("dispositions").fetch("flagged") << disposition(
        guarded, reasons: [ "exceeds_max_files", "public_api_impact" ]
      )
      entries, errors = build_runner(dir, store: store).send(:reconstruct_entries, aggregate)

      assert_empty errors
      assert_equal [ "public_api_impact" ], entries.fetch("flagged").fetch(0).dig(:item, "reasons")
      assert_equal [ "public_api_impact" ], entries.fetch("flagged").fetch(0).fetch(:thesis).risk.fetch("flags")
    end
  end

  def test_runs_fix_for_persisted_legacy_size_only_flagged_job
    with_tmp_dir do |dir|
      item = thesis(
        id: "legacy-size-fix", fingerprint: "fp-legacy-size-fix",
        flags: [ "exceeds_max_files", "exceeds_max_diff_lines" ]
      )
      stored = disposition(
        item, reasons: [ "exceeds_max_files", "exceeds_max_diff_lines" ]
      )
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(flagged: [ stored ])
      )
      fixer = FakeFixer.new(fix_result("no_diff", terminal: true))

      result = build_runner(dir, store: store, fixer: fixer).run(job_id: "job-1")

      assert result.complete?
      assert_equal 1, fixer.calls.size
      assert_equal "no_diff", result.actions.fetch(0).fetch("outcome")
      assert_equal "fix", result.actions.fetch(0).fetch("kind")
      assert_equal [ "exceeds_max_files", "exceeds_max_diff_lines" ],
                   result.aggregate.dig("dispositions", "flagged", 0, "reasons")
    end
  end

  def test_does_not_run_fix_when_legacy_size_row_or_thesis_is_inadmissible
    with_tmp_dir do |dir|
      %w[item thesis].each do |inadmissible_source|
        root = File.join(dir, inadmissible_source)
        item = thesis(
          id: "inadmissible-#{inadmissible_source}",
          fingerprint: "fp-inadmissible-#{inadmissible_source}",
          flags: [ "exceeds_max_files" ]
        )
        stored = disposition(item, reasons: [ "exceeds_max_files" ])
        if inadmissible_source == "item"
          stored["admissible"] = false
        else
          stored.fetch("thesis")["admissible"] = false
        end
        store = write_classified_job(
          root,
          policy: snapshot_policy("auto_fix" => true),
          dispositions: dispositions(flagged: [ stored ])
        )
        fixer = FakeFixer.new(fix_result("no_diff", terminal: true))

        result = build_runner(root, store: store, fixer: fixer).run(job_id: "job-1")

        assert result.complete?, inadmissible_source
        assert_empty result.actions, inadmissible_source
        assert_empty fixer.calls, inadmissible_source
        assert_equal [ "exceeds_max_files" ],
                     result.aggregate.dig("dispositions", "flagged", 0, "reasons")
      end
    end
  end

  def test_reconciles_initialized_legacy_size_issue_with_remote_intent
    with_tmp_dir do |dir|
      item = thesis(
        id: "legacy-size-issue", fingerprint: "fp-legacy-size-issue",
        flags: [ "exceeds_max_files" ]
      )
      stored = disposition(item, reasons: [ "exceeds_max_files" ])
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(flagged: [ stored ])
      )
      family_id = Hive::RefactorPatrol::SemanticFamily.id_for(
        Hive::RefactorPatrol::SemanticDescriptor.call(thesis: item, source: source(7))
      )
      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => item.id, "kind" => "issue", "family_id" => family_id }
        ],
        now: T0
      )
      action = initialized.fetch("actions").fetch(0)
      token = store.claim_action!(
        "job-1", action.fetch("canonical_action_id"), owner: "legacy-runner", now: T0
      )
      store.record_creation_intent!(
        token,
        intent: Hive::RefactorPatrol::IssueFiler.create_intent_payload(
          canonical_action_id: action.fetch("canonical_action_id"),
          repository: source(7).fetch("repository"),
          family_id: family_id,
          thesis_fingerprint: item.fingerprint
        ),
        now: T0
      )
      store.release_action!(
        token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0
      )
      filer = FakeIssueFiler.new(issue_result)

      result = build_runner(dir, store: store, issue_filer: filer).run(job_id: "job-1")

      assert result.complete?
      assert_equal "issue_created", result.actions.fetch(0).fetch("outcome")
      assert_equal 1, filer.calls.size
      assert_equal true, filer.calls.fetch(0).fetch(:creation_attempted)
    end
  end

  def test_reconciles_initialized_legacy_size_issue_from_outcome_only_evidence
    with_tmp_dir do |dir|
      item = thesis(
        id: "legacy-size-outcome", fingerprint: "fp-legacy-size-outcome",
        flags: [ "exceeds_max_files" ]
      )
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true, "issue_filing" => true),
        dispositions: dispositions(flagged: [
          disposition(item, reasons: [ "exceeds_max_files" ])
        ])
      )
      family_id = Hive::RefactorPatrol::SemanticFamily.id_for(
        Hive::RefactorPatrol::SemanticDescriptor.call(thesis: item, source: source(7))
      )
      initialized = store.initialize_actions!(
        "job-1",
        specifications: [
          { "thesis_id" => item.id, "kind" => "issue", "family_id" => family_id }
        ],
        now: T0
      )
      action = initialized.fetch("actions").fetch(0)
      token = store.claim_action!(
        "job-1", action.fetch("canonical_action_id"), owner: "legacy-runner", now: T0
      )
      store.release_action!(
        token, outcome: "remote_outcome_unknown", now: T0, backoff_sec: 0
      )
      issue_url = "https://github.com/acme/polyglot/issues/99"
      filer = FakeIssueFiler.new(
        Hive::RefactorPatrol::IssueFiler::Result.new(
          outcome: "issue_linked_open", terminal: true, issue_url: issue_url,
          receipts: { "issue_url" => issue_url }
        )
      )

      result = build_runner(dir, store: store, issue_filer: filer).run(job_id: "job-1")

      assert result.complete?
      assert_equal "issue_linked_open", result.actions.fetch(0).fetch("outcome")
      assert_equal true, filer.calls.fetch(0).fetch(:creation_attempted)
    end
  end

  def test_reconstructs_persisted_legacy_size_row_with_nil_risk
    with_tmp_dir do |dir|
      item = thesis(id: "legacy-nil-risk", fingerprint: "fp-legacy-nil-risk")
      stored = disposition(item, reasons: [ "exceeds_max_files" ])
      stored.fetch("thesis")["risk"] = nil
      store = write_classified_job(
        dir,
        policy: snapshot_policy,
        dispositions: dispositions(flagged: [ stored ])
      )

      entries, errors = build_runner(dir, store: store).send(
        :reconstruct_entries, store.read_job("job-1")
      )

      assert_empty errors
      assert_empty entries.fetch("flagged")
      assert_equal({ "flags" => [] }, entries.fetch("accepted").fetch(0).fetch(:thesis).risk)
    end
  end

  def test_resume_preview_distinguishes_terminal_linked_authorized_and_revoked_actions
    with_tmp_dir do |dir|
      store = write_classified_job(dir, policy: snapshot_policy, dispositions: dispositions)
      runner = build_runner(dir, store: store)
      runner.define_singleton_method(:effect_authorized?) { |kind| kind == "fix" }
      aggregate = {
        "job_id" => "job-1",
        "actions" => [
          { "terminal" => true, "owner_job_id" => "job-1", "kind" => "fix" },
          { "terminal" => false, "owner_job_id" => "other", "kind" => "issue" },
          { "terminal" => false, "owner_job_id" => "job-1", "kind" => "fix" },
          { "terminal" => false, "owner_job_id" => "job-1", "kind" => "issue" }
        ]
      }

      previews = runner.send(:resume_preview, aggregate)

      assert_equal %w[already_terminal would_reconcile would_resume authority_revoked],
                   previews.map { |item| item.fetch("preview") }
    end
  end

  def test_linked_nonterminal_action_reconciles_only_through_its_owner
    with_tmp_dir do |dir|
      store = write_classified_job(
        dir,
        policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ disposition(thesis(id: "accepted")) ])
      )
      store.initialize_actions!(
        "job-1", specifications: [ { "thesis_id" => "accepted", "kind" => "fix" } ], now: T0
      )
      second_item = disposition(thesis(id: "accepted-2", fingerprint: "fp-accepted"))
      write_classified_job(
        dir, job_id: "job-2", policy: snapshot_policy("auto_fix" => true),
        dispositions: dispositions(accepted: [ second_item ])
      )
      linked = store.initialize_actions!(
        "job-2", specifications: [ { "thesis_id" => "accepted-2", "kind" => "fix" } ], now: T0
      )
      assert_equal "job-1", linked.dig("actions", 0, "owner_job_id")
      runner = build_runner(dir, store: store)

      result = runner.run(job_id: "job-2")

      refute result.complete?
      assert_equal "queued", result.actions.first.fetch("outcome")
    end
  end

  def test_owner_action_rechecks_snapshot_authority_and_repository_before_effects
    with_tmp_dir do |dir|
      released = []
      blocked = []
      store = Object.new
      store.define_singleton_method(:block_actions!) do |_job_id, reason:, **|
        blocked << reason
        { "job_id" => "job-1", "actions" => [], "state" => "blocked", "complete" => false }
      end
      store.define_singleton_method(:release_action!) do |_token, outcome:, **|
        released << outcome
      end
      aggregate = {
        "job_id" => "job-1", "analysis_sha" => "c" * 40,
        "source" => source(7), "dispositions" => dispositions,
        "actions" => [], "state" => "acting", "complete" => false
      }
      action = {
        "canonical_action_id" => "fix-action", "thesis_id" => "missing",
        "kind" => "fix", "owner_job_id" => "job-1", "terminal" => false,
        "outcome" => "queued", "receipts" => {}
      }
      store.define_singleton_method(:read_job) { |_job_id| aggregate }
      runner = build_runner(dir, store: store)
      runner.instance_variable_set(:@events, [])
      runner.instance_variable_set(:@source, aggregate.fetch("source"))

      runner.send(:process_owner_action, aggregate, action)
      assert_equal [ "invalid_thesis_snapshot" ], blocked
      assert_equal "invalid_thesis_snapshot",
                   runner.instance_variable_get(:@events).first.fetch("outcome")

      item = thesis(id: "present")
      entry = { disposition: "accepted", item: disposition(item), thesis: item }
      action = action.merge("thesis_id" => "present")
      aggregate["actions"] = [ action ]
      calls = 0
      runner.define_singleton_method(:disposition_index) do |_aggregate|
        calls += 1
        calls == 1 ? { "present" => entry } : {}
      end
      runner.define_singleton_method(:claim_action) do |_aggregate, _action|
        { job_id: "job-1", canonical_action_id: "fix-action", continuation_only: false }
      end
      runner.send(:process_owner_action, aggregate, action)
      assert_includes released, "invalid_thesis_snapshot"

      calls = 0
      runner.define_singleton_method(:disposition_index) do |_aggregate|
        calls += 1
        { "present" => entry }
      end
      runner.define_singleton_method(:effect_authorized?) { |_kind| false }
      runner.send(:process_owner_action, aggregate, action)
      assert_includes released, "authority_revoked"

      decision = Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
        authority: :blocked, reason: "duplicate_repository_registration", evidence: { "owners" => 2 }
      )
      runner.singleton_class.send(:remove_method, :claim_action)
      runner.define_singleton_method(:current_repository_ownership_decision) { |*, **| decision }
      assert_nil runner.send(:claim_action, aggregate, action)
      assert_includes blocked, "duplicate_repository_registration"
    end
  end

  def test_fix_issue_and_settlement_guards_release_invalid_adapter_states
    with_tmp_dir do |dir|
      released = []
      finished = []
      store = Object.new
      store.define_singleton_method(:release_action!) do |_token, outcome:, **|
        released << outcome
      end
      store.define_singleton_method(:finish_action!) do |_token, outcome:, **|
        finished << outcome
      end
      store.define_singleton_method(:record_patch_publication_attempt!) { |*, **| true }
      runner = build_runner(dir, store: store, fixer: FakeFixer.new(Object.new))
      token = { job_id: "job-1", canonical_action_id: "fix-action", continuation_only: false }
      aggregate = { "job_id" => "job-1", "analysis_sha" => "c" * 40, "source" => source(7) }
      action = {
        "canonical_action_id" => "fix-action", "thesis_id" => "accepted",
        "thesis_fingerprint" => "fp-accepted", "kind" => "fix",
        "family_id" => nil, "receipts" => {}, "owner_job_id" => "job-1"
      }
      item = thesis(id: "accepted", fingerprint: "fp-accepted")

      runner.define_singleton_method(:patch_from_receipts) { |*| :invalid }
      runner.send(:process_fix, token, aggregate, action, item)
      assert_includes released, "invalid_patch_receipt"

      runner.define_singleton_method(:patch_from_receipts) { |*| nil }
      runner.define_singleton_method(:claim_effect_authorized?) { |*| false }
      runner.send(:process_fix, token, aggregate, action, item)
      assert_includes released, "authority_revoked"

      runner.define_singleton_method(:claim_effect_authorized?) { |*| true }
      runner.send(:process_fix, token, aggregate, action, item)
      assert_includes released, "invalid_fixer_result"

      patch = validated_patch(fingerprint: "fp-accepted")
      runner.define_singleton_method(:patch_from_receipts) { |*| patch }
      runner.define_singleton_method(:transition_denial_reason) { |*| "policy_changed" }
      runner.send(:process_fix, token, aggregate, action, item)
      assert_includes released, "policy_changed"

      runner.define_singleton_method(:transition_denial_reason) { |*| nil }
      runner.define_singleton_method(:current_action) { |_token| action }
      runner.define_singleton_method(:publication_state) { |*| :invalid }
      runner.send(:process_fix, token, aggregate, action, item)
      assert_includes released, "invalid_creation_intent"

      issue_action = action.merge("kind" => "issue", "family_id" => "af1")
      runner.define_singleton_method(:transition_denial_reason) { |*| "policy_changed" }
      runner.send(:process_issue, token, aggregate, issue_action, item, [])
      assert_includes released, "policy_changed"
      runner.define_singleton_method(:transition_denial_reason) { |*| nil }
      runner.define_singleton_method(:current_action) { |_token| issue_action }
      runner.define_singleton_method(:publication_state) { |*| :invalid }
      runner.send(:process_issue, token, aggregate, issue_action, item, [])
      assert_includes released, "invalid_creation_intent"

      no_family = {
        "actions" => [ action.merge("terminal" => true, "outcome" => "failed") ]
      }
      route = runner.send(:issue_route, no_family, issue_action.except("family_id"),
                          { thesis: item, disposition: "accepted", item: {} })
      assert_nil route.fetch(:outcome)
      assert_equal "failed", route.fetch(:reasons).first
      route = runner.send(
        :issue_route,
        { "actions" => [], "policy" => snapshot_policy("auto_fix" => false) },
        issue_action,
        { thesis: item, disposition: "accepted", item: {} }
      )
      assert_nil route.fetch(:outcome)
      assert_equal [ "auto_fix_disabled" ], route.fetch(:reasons)
      assert_equal "issue_not_needed",
                   runner.send(:issue_route,
                               { "actions" => [], "policy" => snapshot_policy("auto_fix" => true) },
                               issue_action,
                               { thesis: item, disposition: "accepted", item: {} }).fetch(:outcome)

      runner.define_singleton_method(:claim_action) { |*| token }
      runner.define_singleton_method(:effect_authorized?) { |*| false }
      runner.send(:finish_local_issue, aggregate, issue_action, "issue_not_needed")
      assert_includes released, "authority_revoked"

      runner.send(:settle, token, fix_result("no_diff", terminal: true), adapter: :fix)
      assert_includes finished, "no_diff"
      refute runner.send(:valid_adapter_result?, :unknown, Object.new)
    end
  end

  def test_cross_feature_patch_receipt_uses_effective_policy_and_observes_live_revocation
    with_tmp_dir do |dir|
      current_cfg = config
      current_cfg.dig("refactor_patrol", "caps")["allow_cross_feature"] = true
      runner = build_runner(
        dir, store: Hive::RefactorPatrol::JobStore.new(dir), cfg: current_cfg
      )
      item = thesis(id: "accepted", fingerprint: "fp-accepted")
      patch = validated_patch(fingerprint: item.fingerprint)
      patch.changed_paths = [ "src/orders/service.ts" ]
      policy = snapshot_policy
      policy.fetch("action").fetch("caps")["allow_cross_feature"] = true
      aggregate = {
        "analysis_sha" => patch.analysis_sha,
        "policy" => policy
      }
      action = { "canonical_action_id" => patch.branch.delete_prefix("hive-refactor/") }
      runner.send(:prepare_policy, aggregate)

      assert runner.send(:valid_patch?, patch, aggregate, action, item)
      patch.changed_paths = [ "../outside.rb" ]
      refute runner.send(:valid_patch?, patch, aggregate, action, item)

      patch.changed_paths = 9.times.map { |index| "src/shared/#{index}.rb" }
      assert runner.send(:valid_patch?, patch, aggregate, action, item)

      patch.changed_paths = [ "src/orders/service.ts" ]
      patch.diff_lines = 401
      assert runner.send(:valid_patch?, patch, aggregate, action, item)

      current_cfg.dig("refactor_patrol", "caps")["allow_cross_feature"] = false
      runner.send(:prepare_policy, aggregate)
      refute runner.send(:valid_patch?, patch, aggregate, action, item)
    end
  end

  def test_publication_callbacks_ownership_fences_and_policy_fallbacks_fail_closed
    with_tmp_dir do |dir|
      released = []
      asserted = []
      blocked = []
      store = Object.new
      store.define_singleton_method(:release_action!) do |_token, outcome:, **|
        released << outcome
      end
      aggregate = {
        "job_id" => "job-1", "source" => source(7), "actions" => [],
        "state" => "acting", "complete" => false
      }
      store.define_singleton_method(:read_job) { |_job_id| aggregate }
      store.define_singleton_method(:assert_action_claim!) { |token, **| asserted << token }
      store.define_singleton_method(:block_actions!) do |_job_id, reason:, **|
        blocked << reason
        aggregate
      end
      runner = build_runner(dir, store: store)
      runner.instance_variable_set(:@events, [])
      runner.instance_variable_set(:@source, aggregate.fetch("source"))
      action = {
        "canonical_action_id" => "issue-action", "thesis_fingerprint" => "fp",
        "family_id" => "af1", "kind" => "issue", "receipts" => {}
      }
      token = { job_id: "job-1", canonical_action_id: "issue-action", continuation_only: false }

      callback = runner.send(:publication_intent_callback, token, "issue", aggregate, action)
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        callback.call(phase: "issue_create_intent", payload: { "bad" => true })
      end
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        runner.send(:persist_publication_phase, token, "issue", "unknown", {})
      end
      assert_nil runner.send(
        :expected_publication_payload, "issue", "unknown", aggregate, action, nil,
        expected_remote_oid: nil
      )
      malformed = action.merge(
        "receipts" => { "creation_intent" => { "payload" => {}, "recorded_at" => "never" } }
      )
      assert_equal :invalid, runner.send(:publication_state, malformed, aggregate, action)

      blocked_decision = Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
        authority: :blocked, reason: "repository_identity_drift", evidence: {}
      )
      runner.define_singleton_method(:current_repository_ownership_decision) { |*, **| blocked_decision }
      refute runner.send(:continuation_fence, token, aggregate).call
      full_decision = Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
        authority: :full, reason: nil, evidence: {}
      )
      runner.define_singleton_method(:current_repository_ownership_decision) { |*, **| full_decision }
      assert runner.send(:continuation_fence, token, aggregate).call
      assert_equal [ token ], asserted

      runner.define_singleton_method(:creation_intent?) { |*| false }
      runner.send(:settle_unexpected_failure, aggregate, action, token, RuntimeError.new("boom"))
      assert_includes released, "action_runner_error"
      store.define_singleton_method(:release_action!) do |*args, **|
        raise Hive::RefactorPatrol::JobStore::StaleClaim, "stale"
      end
      assert_raises(Hive::RefactorPatrol::JobStore::StaleClaim) do
        runner.send(:settle_unexpected_failure, aggregate, action, token, RuntimeError.new("boom"))
      end

      runner.define_singleton_method(:current_repository_ownership_decision) { |*, **| raise IOError, "lookup" }
      runner.send(:enforce_repository_authority, aggregate)
      assert_includes blocked, "repository_identity_unresolved"

      disabled = Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
        authority: :blocked, reason: "architecture_patrol_disabled", evidence: {}
      )
      duplicate = Hive::RefactorPatrol::RepositoryOwnership::Decision.new(
        authority: :blocked, reason: "duplicate_repository_registration", evidence: {}
      )
      runner.define_singleton_method(:current_repository_ownership_decision) { |*, **| disabled }
      assert_equal "authority_revoked", runner.send(:transition_denial_reason, token, "issue", aggregate)
      runner.define_singleton_method(:current_repository_ownership_decision) { |*, **| duplicate }
      assert_equal "duplicate_repository_registration",
                   runner.send(:transition_denial_reason, token, "issue", aggregate)

      runner.singleton_class.send(:remove_method, :current_repository_ownership_decision)
      runner.instance_variable_set(:@config_loader, ->(*) { raise IOError, "config" })
      assert_equal "repository_identity_unresolved",
                   runner.send(:current_repository_ownership_decision, aggregate, continuation: false).reason
      runner.instance_variable_set(:@repository_ownership, Object.new.tap do |guard|
        guard.define_singleton_method(:call) { |**| raise IOError, "guard" }
      end)
      assert_equal "repository_identity_unresolved",
                   runner.send(:repository_ownership_decision, aggregate, cfg: config, continuation: false).reason

      runner.instance_variable_set(:@policy_snapshot, snapshot_policy)
      assert_equal "current_policy_unavailable", runner.send(:current_policy_result).error
      assert_equal "invalid-policy", runner.send(:action_policy_signature, {}, "fix")
    end
  end

  def test_publication_phase_and_legacy_projection_defensive_branches
    with_tmp_dir do |dir|
      receipts = []
      intents = []
      store = Object.new
      store.define_singleton_method(:record_action_receipt!) do |_token, key:, value:, **|
        receipts << [ key, value ]
      end
      store.define_singleton_method(:record_creation_intent!) do |_token, intent:, **|
        intents << intent
      end
      runner = build_runner(dir, store: store)
      token = { job_id: "job-1", canonical_action_id: "issue-action" }
      aggregate = { "job_id" => "job-1", "source" => source(7) }
      issue_action = {
        "canonical_action_id" => "issue-action", "kind" => "issue",
        "family_id" => "af1", "thesis_fingerprint" => "fp", "receipts" => {}
      }

      runner.send(
        :persist_publication_phase, token, "issue", Hive::RefactorPatrol::PrOpener::PUSH_COMPLETE,
        { "operation" => "push_branch_complete" }
      )
      runner.define_singleton_method(:current_action) do |_token|
        issue_action.merge("receipts" => { "creation_intent" => {} })
      end
      runner.send(
        :persist_publication_phase, token, "issue", Hive::RefactorPatrol::PrOpener::PR_CREATE_INTENT,
        { "operation" => "create_pr" }
      )
      runner.define_singleton_method(:current_action) { |_token| issue_action }
      runner.send(
        :persist_publication_phase, token, "issue", Hive::RefactorPatrol::PrOpener::PR_CREATE_INTENT,
        { "operation" => "create_pr" }
      )
      assert_equal 2, receipts.size
      assert_equal 1, intents.size

      malformed_patch_history = issue_action.merge(
        "receipts" => { Hive::RefactorPatrol::PublicationAttempt::ATTEMPTS_KEY => [] }
      )
      assert_equal :invalid, runner.send(
        :patch_from_receipts, malformed_patch_history, aggregate, thesis(id: "accepted")
      )

      %w[push_branch create_pr].each do |operation|
        candidate = issue_action.merge(
          "receipts" => {
            "creation_intent" => {
              "payload" => { "operation" => operation },
              "recorded_at" => "2026-07-12T10:00:00Z"
            }
          }
        )
        assert_equal :invalid, runner.send(
          :publication_state, candidate, aggregate, issue_action
        )
      end
      [ Hive::RefactorPatrol::PrOpener::PUSH_COMPLETE,
        Hive::RefactorPatrol::PrOpener::PR_CREATE_INTENT ].each do |phase|
        candidate = issue_action.merge(
          "receipts" => { phase => { "operation" => "unexpected" } }
        )
        assert_equal :invalid, runner.send(
          :publication_state, candidate, aggregate, issue_action
        )
      end
      nil_phase = issue_action.merge(
        "receipts" => { Hive::RefactorPatrol::PrOpener::PUSH_COMPLETE => nil }
      )
      assert_equal(
        { Hive::RefactorPatrol::PrOpener::PUSH_COMPLETE => nil },
        runner.send(:publication_state, nil_phase, aggregate, issue_action)
      )

      patch = validated_patch(fingerprint: "fp")
      fix_action = issue_action.merge(
        "canonical_action_id" => "fix-action", "kind" => "fix",
        "thesis_fingerprint" => "fp"
      )
      assert_equal :invalid, runner.send(
        :publication_attempt_state, [], aggregate, fix_action, patch
      )
      attempt_id = Hive::RefactorPatrol::PublicationAttempt.id_for(
        publication_base_sha: patch.publication_base_sha,
        commit_sha: patch.commit_sha
      )
      invalid_descriptor = {
        "receipts" => {
          Hive::RefactorPatrol::PublicationAttempt::ATTEMPTS_KEY => {
            attempt_id => { "descriptor" => { "attempt_id" => "wrong" } }
          }
        }
      }
      assert_equal :invalid, runner.send(
        :publication_attempt_state, invalid_descriptor, aggregate, fix_action, patch
      )
    end
  end

  def test_run_rejects_an_effect_occurrence_from_another_dispatch
    with_tmp_dir do |dir|
      item = thesis(id: "accepted")
      store = write_classified_job(
        dir,
        policy: snapshot_policy,
        dispositions: dispositions(accepted: [ disposition(item) ])
      )
      runner = build_runner(dir, store: store)
      runner.instance_variable_set(
        :@expected_occurrence_id,
        "occ-#{'f' * 64}"
      )

      error = assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        runner.run(job_id: "job-1")
      end

      assert_equal(
        "architecture patrol action occurrence does not match dispatch",
        error.message
      )
      refute_nil store.occurrence_capture("job-1")
    end
  end

  def test_effect_executors_reject_mutated_publication_and_handoff_payloads
    with_tmp_dir do |dir|
      runner = build_runner(dir, store: Object.new)
      token = {
        job_id: "job-1",
        canonical_action_id: "action-1",
        generation: 1,
        continuation_only: false
      }
      aggregate = { "job_id" => "job-1", "source" => source(7) }
      action = {
        "canonical_action_id" => "action-1",
        "family_id" => "family-1",
        "thesis_fingerprint" => "fingerprint-1"
      }
      patch = validated_patch(fingerprint: "fingerprint-1")
      publication = runner.send(
        :publication_effect_executor,
        token, "issue", aggregate, action
      )
      handoff = runner.send(
        :handoff_effect_executor,
        token, "fix", aggregate, action, patch
      )

      publication_error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        publication.call(
          phase: "issue_create_intent",
          payload: { "operation" => "create_issue", "mutated" => true }
        ) { {} }
      end
      handoff_error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        handoff.call(
          phase: "review_handoff",
          payload: {
            "pr_url" => "http://github.com/acme/polyglot/pull/99",
            "job_id" => "job-1",
            "canonical_action_id" => "action-1",
            "commit_sha" => patch.commit_sha
          }
        ) { {} }
      end

      assert_equal "publication effect payload is invalid", publication_error.message
      assert_equal "review handoff effect payload is invalid", handoff_error.message
    end
  end

  def test_effect_gateway_claim_validator_fails_closed_on_a_stale_claim
    with_tmp_dir do |dir|
      store = Object.new
      store.define_singleton_method(:assert_action_claim!) do |_token, **|
        raise Hive::RefactorPatrol::JobStore::StaleClaim, "claim replaced"
      end
      runner = build_runner(dir, store: store)
      options = nil
      runner.instance_variable_set(
        :@effect_gateway_factory,
        lambda do |**gateway_options|
          options = gateway_options
          Object.new
        end
      )
      token = {
        job_id: "job-1",
        canonical_action_id: "action-1",
        generation: 7,
        continuation_only: false
      }

      runner.send(
        :build_effect_gateway,
        token,
        "fix",
        Hive::RefactorPatrol::PrOpener::PUSH_INTENT,
        {},
        architecture_capture,
        attempt_id: "attempt-1"
      )

      refute options.fetch(:claim_validator).call(claim_generation: 7)
      refute options.fetch(:claim_validator).call(claim_generation: 8)
    end
  end

  def test_effect_capture_and_descriptor_guards_are_explicit
    with_tmp_dir do |dir|
      runner = build_runner(dir, store: Object.new)
      token = {
        job_id: "job-1",
        canonical_action_id: "action-1",
        generation: 1,
        continuation_only: false
      }
      aggregate = { "source" => source(7) }
      issue_action = {
        "canonical_action_id" => "action-1",
        "family_id" => "family-1"
      }

      capture_error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        runner.send(:effect_capture, token, aggregate, issue_action)
      end
      issue = runner.send(
        :effect_descriptor,
        token, "issue", "issue_create_intent", {},
        aggregate, issue_action, attempt_id: nil
      )
      phase_error = assert_raises(
        Hive::RefactorPatrol::JobStore::InconsistentRecord
      ) do
        runner.send(
          :effect_descriptor,
          token, "fix", "unknown", {},
          aggregate, issue_action, attempt_id: nil
        )
      end

      assert_equal "architecture patrol effect occurrence is unavailable",
                   capture_error.message
      assert_equal "issue", issue.fetch(:sink)
      assert_equal "acme/polyglot:family-1", issue.fetch(:target)
      assert_equal "github_issues", issue.fetch(:capability)
      assert_equal "architecture patrol effect phase is unsupported",
                   phase_error.message
    end
  end

  def test_effect_project_identity_falls_back_when_registry_is_corrupt
    with_tmp_global_config do |hive_home|
      with_tmp_dir do |dir|
        File.write(File.join(hive_home, "config.yml"), "[")
        runner = build_runner(dir, store: Object.new)

        assert_equal(
          "local-#{::Digest::SHA256.hexdigest(File.expand_path(dir))}",
          runner.send(:effect_project_id)
        )
      end
    end
  end

  def test_publication_attempt_matcher_handles_exact_and_malformed_receipts
    with_tmp_dir do |dir|
      runner = build_runner(dir, store: Object.new)
      captured_matcher = nil
      runner.define_singleton_method(:action_claim_transition!) do |*,
                                                                     matcher:,
                                                                     **|
        captured_matcher = matcher
      end
      token = { job_id: "job-1", canonical_action_id: "action-1" }
      attempt_id = "a" * 64
      phase = Hive::RefactorPatrol::PrOpener::PUSH_INTENT
      payload = { "operation" => "push_branch" }

      runner.send(
        :persist_publication_phase,
        token, "fix", phase, payload, attempt_id: attempt_id
      )

      exact = {
        "receipts" => {
          Hive::RefactorPatrol::PublicationAttempt::ATTEMPTS_KEY => {
            attempt_id => { phase => payload }
          }
        }
      }
      assert captured_matcher.call(exact)
      refute captured_matcher.call("receipts" => nil)
    end
  end

  def test_claim_effect_capability_checks_cover_every_external_sink
    with_tmp_dir do |dir|
      runner = build_runner(dir, store: Object.new)
      runner.define_singleton_method(:effect_authorized?) { |_kind| true }
      token = {
        job_id: "job-1",
        canonical_action_id: "action-1",
        generation: 1,
        continuation_only: false
      }
      calls = []
      context = Object.new
      {
        require_repository_write!: [],
        require_github_mutation!: nil,
        require_external_command!: nil,
        require_network_host!: nil,
        require_filesystem_write!: nil
      }.each do |method_name, fixed_arguments|
        context.define_singleton_method(method_name) do |*arguments|
          calls << [ method_name, *(fixed_arguments || arguments) ]
          true
        end
      end

      refute runner.send(
        :claim_effect_authorized?,
        token, "fix", capability_context: context, capability: nil
      )
      assert runner.send(
        :claim_effect_authorized?,
        token, "fix", capability_context: context,
        capability: "repository_write"
      )
      assert runner.send(
        :claim_effect_authorized?,
        token, "fix", capability_context: context,
        capability: "github_pull_requests"
      )
      assert runner.send(
        :claim_effect_authorized?,
        token, "issue", capability_context: context,
        capability: "github_issues"
      )
      assert runner.send(
        :claim_effect_authorized?,
        token, "fix", capability_context: context,
        capability: "review_handoff"
      )
      refute runner.send(
        :claim_effect_authorized?,
        token, "fix", capability_context: context,
        capability: "unknown"
      )
      assert_equal(
        [
          [ :require_repository_write! ],
          [ :require_github_mutation!, "pull_requests" ],
          [ :require_external_command!, "gh" ],
          [ :require_network_host!, "api.github.com" ],
          [ :require_github_mutation!, "issues" ],
          [ :require_external_command!, "gh" ],
          [ :require_network_host!, "api.github.com" ],
          [ :require_filesystem_write!, ".hive-state/stages/**" ]
        ],
        calls
      )

      denied = Object.new
      denied.define_singleton_method(:require_repository_write!) do
        raise Hive::Modules::CapabilityDenied, "denied"
      end
      refute runner.send(
        :claim_effect_authorized?,
        token, "fix", capability_context: denied,
        capability: "repository_write"
      )
    end
  end

  private

  def build_runner(dir, store:, cfg: config, family_store: FakeFamilyStore.new,
                   fixer: FakeFixer.new, pr_opener: FakePrOpener.new,
                   issue_filer: FakeIssueFiler.new, backoff_sec: 0,
                   authority_backoff_sec: backoff_sec,
                   config_loader: nil,
                   gate_reader: nil,
                   repository_ownership: nil,
                   canonical_action_catalog: nil,
                   evidence_store: nil,
                   clock: -> { T0 },
                   repository_resolver: ->(*) {
                     { "repository" => "acme/polyglot", "host" => "github.com" }
                   })
    Hive::RefactorPatrol::ActionRunner.new(
      dir,
      cfg: cfg,
      job_store: store,
      family_store: family_store,
      fixer: fixer,
      pr_opener: pr_opener,
      issue_filer: issue_filer,
      owner: "test-runner",
      clock: clock,
      repository_resolver: repository_resolver,
      repository_ownership: repository_ownership,
      canonical_action_catalog: canonical_action_catalog,
      evidence_store: evidence_store,
      config_loader: config_loader,
      gate_reader: gate_reader,
      lease_sec: 60,
      backoff_sec: backoff_sec,
      authority_backoff_sec: authority_backoff_sec
    )
  end

  def repository_snapshot(repo, store)
    files = Dir.glob(File.join(store.root, "**", "*"), File::FNM_DOTMATCH)
               .select { |path| File.file?(path) }
               .sort
               .to_h { |path| [ path.delete_prefix("#{repo}/"), File.binread(path) ] }
    {
      "status" => run!("git", "-C", repo, "status", "--porcelain=v1", "--untracked-files=all"),
      "refs" => run!("git", "-C", repo, "show-ref"),
      "worktrees" => run!("git", "-C", repo, "worktree", "list", "--porcelain"),
      "state_files" => files
    }
  end

  def write_classified_job(dir, job_id: "job-1", policy:, dispositions:,
                           registration: "polyglot", analysis_sha: "c" * 40)
    store = Hive::RefactorPatrol::JobStore.new(dir)
    store.write_job!(
      {
        "schema" => "hive-refactor-patrol-job",
        "schema_version" => 2,
        "job_id" => job_id,
        "source" => source(job_id == "job-1" ? 7 : 8, registration: registration),
        "analysis_sha" => analysis_sha,
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

  def source(number, registration: "polyglot")
    {
      "url" => "https://github.com/acme/polyglot/pull/#{number}",
      "number" => number,
      "repository" => "acme/polyglot",
      "registration" => registration,
      "base_branch" => "main",
      "base_sha" => "a" * 40,
      "merge_sha" => number == 7 ? "b" * 40 : "d" * 40
    }
  end

  def architecture_capture
    Hive::Modules::Migration::PatrolCapture.build(
      module_name: "architecture-patrol",
      project: {
        "project_id" => "project-1",
        "name" => "polyglot",
        "repository" => "acme/polyglot"
      },
      trigger: {
        "kind" => "pull_request.merged",
        "id" => "acme/polyglot:7:#{'b' * 40}"
      },
      reservation: {
        "kind" => "architecture",
        "id" => "job-1",
        "job_id" => "job-1"
      },
      owner: "legacy",
      owner_epoch: 1,
      decision_class: "provenance",
      decision: { "rationale" => "due", "job_id" => "job-1" },
      occurred_at: T0,
      recorded_at: T0
    )
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
      "execute" => { "agent" => "codex", "model" => "gpt-5.6-sol", "effort" => "high" },
      "refactor_patrol" => {
        "enabled" => discovery,
        "min_confidence" => "medium",
        "auto_fix" => { "enabled" => auto_fix, "agent" => "codex" },
        "issue_filing" => { "enabled" => issue_filing, "min_leverage_score" => 0.5 },
        "commands" => {
          "docs" => nil, "format" => nil, "lint" => nil, "public_contract" => nil,
          "typecheck" => nil, "test" => "bin/test"
        },
        "caps" => {
          "single_feature_only" => true,
          "allow_dependency_bumps" => false,
          "allow_public_api_changes" => false,
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
    action_id = Hive::RefactorPatrol::JobStore.new("/tmp/refactor-action-id").canonical_action_id(
      repository: "acme/polyglot", host: "github.com",
      kind: "fix", identity: fingerprint
    )
    Hive::RefactorPatrol::Fixer::Result.new(
      outcome: "validated",
      terminal: false,
      branch: "hive-refactor/#{action_id}",
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

  def recovery_patch(branch:, worktree_path:, analysis_sha:, publication_base_sha:, commit_sha:)
    Hive::RefactorPatrol::Fixer::Result.new(
      outcome: "validated",
      terminal: false,
      branch: branch,
      worktree_path: worktree_path,
      analysis_sha: analysis_sha,
      publication_base_sha: publication_base_sha,
      commit_sha: commit_sha,
      validation: {
        "passed" => true,
        "commands" => [ { "name" => "test", "exit_code" => 0 } ]
      },
      changed_paths: [ "src/checkout/service.ts" ],
      diff_lines: 1,
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

  def finish_foreign_action(store, thesis_id:, kind:, outcome:, receipts:, family_id: nil)
    specification = { "thesis_id" => thesis_id, "kind" => kind }
    specification["family_id"] = family_id if family_id
    aggregate = store.initialize_actions!(
      "job-1", specifications: [ specification ], now: T0
    )
    action_id = aggregate.dig("actions", 0, "canonical_action_id")
    token = store.claim_action!("job-1", action_id, owner: "foreign", now: T0)
    store.finish_action!(token, outcome: outcome, receipts: receipts, now: T0 + 1)
    action_id
  end

  def terminal_proof(action_id, project_root:, outcome: "pr_opened", receipts:)
    payload = {
      "canonical_action_id" => action_id,
      "owner" => {
        "registration" => "foreign",
        "project_root" => project_root,
        "job_id" => "job-foreign",
        "pr_number" => 7,
        "merge_sha" => "b" * 40
      },
      "outcome" => outcome,
      "proof" => receipts
    }
    payload.merge(
      "proof_digest" => ::Digest::SHA256.hexdigest(
        JSON.generate(deep_sort_json(payload))
      )
    )
  end

  def deep_sort_json(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [ key, deep_sort_json(value.fetch(key)) ] }
    when Array
      value.map { |item| deep_sort_json(item) }
    else value
    end
  end

  def job_path(store, job_id)
    File.join(store.root, "jobs", "#{job_id}.json")
  end
end
