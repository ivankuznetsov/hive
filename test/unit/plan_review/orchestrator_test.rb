require "test_helper"
require "hive/config"
require "hive/plan_review/orchestrator"

require "tmpdir"

class PlanReviewOrchestratorTest < Minitest::Test
  # A plan containing any non-ASCII character (em dash, arrow, curly quote)
  # used to crash the whole plan-review stage with
  # `Encoding::CompatibilityError: incompatible character encodings: UTF-8 and
  # BINARY`, because plan.md was binread and handed to prompt construction as
  # ASCII-8BIT. Every webmail.sh plan task died this way 23 times overnight.
  def test_plan_text_returns_utf8_for_a_plan_with_non_ascii
    Dir.mktmpdir do |dir|
      path = File.join(dir, "plan.md")
      File.write(path, "# Plan\n\nUse the port — not the vendor → adapter.\n")
      orchestrator = Hive::PlanReview::Orchestrator.allocate

      text = orchestrator.send(:plan_text, path)

      assert_equal Encoding::UTF_8, text.encoding
      assert text.valid_encoding?
      assert_includes text, "—"
      # The real failure mode: concatenating with a UTF-8 prompt template.
      assert_equal "prompt: #{text}", "prompt: " + text
    end
  end

  # Invalid UTF-8 must not be silently mangled; PlanSignals reports it as
  # invalid_utf8, which is the error the operator should actually see.
  def test_plan_text_leaves_invalid_utf8_as_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "plan.md")
      File.binwrite(path, "# Plan\n\xC3\x28 bad\n")
      orchestrator = Hive::PlanReview::Orchestrator.allocate

      text = orchestrator.send(:plan_text, path)

      refute text.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end
  end

  Workflow = Struct.new(:id, keyword_init: true)
  Task = Struct.new(
    :folder, :project_root, :slug, :id, :workflow, :meta_yml_path,
    keyword_init: true
  )

  class FakeAdapter
    attr_reader :calls

    def initialize(&response)
      @response = response
      @calls = []
    end

    def call(request)
      @calls << request
      @response.call(request)
    end
  end

  class FakeRevision
    attr_reader :calls

    def initialize(candidate)
      @candidate = candidate
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      Hive::PlanReview::PlannerRevision::Result.new(
        outcome: "success", candidate_bytes: @candidate,
        candidate_digest: Digest::SHA256.hexdigest(@candidate),
        route_receipt: arguments.fetch(:planner_identity), diagnostic: nil
      )
    end
  end

  class TransientRevision
    attr_reader :calls

    def initialize(candidate)
      @candidate = candidate
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      return Hive::PlanReview::PlannerRevision::Result.new(
        outcome: "retryable_failure", candidate_bytes: nil, candidate_digest: nil,
        route_receipt: arguments.fetch(:planner_identity), diagnostic: "route failed"
      ) if @calls.length == 1

      Hive::PlanReview::PlannerRevision::Result.new(
        outcome: "success", candidate_bytes: @candidate,
        candidate_digest: Digest::SHA256.hexdigest(@candidate),
        route_receipt: arguments.fetch(:planner_identity), diagnostic: nil
      )
    end
  end

  def test_skip_records_clearance_without_any_reviewer_call
    with_task(skip_plan) do |task, cfg|
      adapter = FakeAdapter.new { flunk "skip must not invoke a reviewer" }
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "skipped", projection.record.state
      assert projection.record.execution_allowed?
      assert_empty adapter.calls
      assert_equal 0, projection.summary.fetch("attempt_count")
    end
  end

  def test_standard_safe_change_uses_one_revision_and_one_verification
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      finding = finding("safe_auto", "Clarify tests")
      adapter = success_adapter(primary_findings: [ finding ])
      revision = FakeRevision.new(revised)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "cleared", projection.record.state
      assert projection.record.execution_allowed?
      assert_equal %w[primary adversarial verification], adapter.calls.map(&:kind)
      assert_equal 1, revision.calls.length
      assert_equal revised, File.binread(File.join(task.folder, "plan.md"))
      assert_equal 4, projection.record["attempt_ids"].length
      assert_equal "verified", projection.record["findings"].first.fetch("lifecycle")
    end
  end

  def test_planner_revision_failures_are_durable_and_retry_within_the_shared_bound
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      revision = TransientRevision.new(revised)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])

      first = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "retry_scheduled", first.record.state
      route = first.record["routes"].last
      assert_equal "planner_revision", route.fetch("role")
      assert_equal "retryable_failure", route.fetch("outcome")
      assert route.fetch("retry_at")
      assert first.record["artifacts"].fetch("planner_revision_result")

      cleared = orchestrator(
        task, cfg, adapter:, planner_revision: revision,
        clock: -> { Time.utc(2026, 8, 12, 13) }
      ).advance!

      assert_equal "cleared", cleared.record.state
      assert_equal 2, revision.calls.length
      assert_equal 2, cleared.record["routes"].count { |entry|
        entry["role"] == "planner_revision"
      }
    end
  end

  def test_selected_fallback_keeps_the_preferred_request_and_probe_history
    with_task(standard_plan) do |task, cfg|
      preferred = route_identity("grok", "grok-4.6", "grok", "preferred")
      fallback = route_identity("codex", "gpt-5.6-sol", "openai", "fallback")
      resolver = lambda do |role:, **|
        next resolve_route(role:) unless role == "primary"

        Hive::PlanReview::RouteResolver::Resolution.new(
          status: "resolved", candidate: fallback,
          receipt: {
            "role" => role, "requested" => preferred, "actual" => fallback,
            "capability_result" => "present", "independence_verified" => true,
            "independence_reason" => "different_model_family",
            "attempts" => [
              { "candidate" => preferred, "status" => "unsupported" },
              { "candidate" => fallback, "status" => "present" }
            ]
          }
        )
      end

      projection = orchestrator(
        task, cfg, adapter: success_adapter, route_resolver: resolver
      ).advance!

      primary = projection.record["routes"].find { |entry| entry["role"] == "primary" }
      assert_equal preferred, primary.fetch("requested")
      assert_equal fallback, primary.fetch("actual")
      assert_equal %w[unsupported present], primary.fetch("attempts").map { |row| row.fetch("status") }
    end
  end

  def test_candidate_promotion_and_resolution_hold_the_task_mutation_lock
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      runner = orchestrator(
        task, cfg,
        adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
        planner_revision: FakeRevision.new(revised)
      )
      observed = []
      promotion = runner.method(:promote_candidate!)
      runner.define_singleton_method(:promote_candidate!) do |*arguments|
        observed << Hive::Lock.task_lock_held?(task.folder)
        promotion.call(*arguments)
      end

      projection = runner.advance!

      assert_equal "cleared", projection.record.state
      assert_equal [ true ], observed
    end
  end

  def test_resolution_publication_reuses_an_orphaned_immutable_artifact
    with_task(standard_plan) do |task, cfg|
      runner = orchestrator(task, cfg, adapter: success_adapter)
      store = runner.instance_variable_get(:@store)
      publish = store.method(:publish_current!)
      failed = false
      store.define_singleton_method(:publish_current!) do |record, expected_version:|
        if record.state == "cleared" && !failed
          failed = true
          raise Errno::EIO, "simulated current pointer crash"
        end
        publish.call(record, expected_version:)
      end

      assert_raises(Errno::EIO) { runner.advance! }
      orphan = Dir[File.join(store.root, "reviews", "*", "resolution-v*.json")].fetch(0)
      orphan_bytes = File.binread(orphan)

      recovered = orchestrator(
        task, cfg, adapter: success_adapter,
        clock: -> { Time.utc(2026, 8, 12, 13) }
      ).advance!

      assert_equal "cleared", recovered.record.state
      assert_equal orphan_bytes, File.binread(orphan)
    end
  end

  def test_manual_finding_pauses_before_revision_or_verification
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter(primary_findings: [ finding("manual", "Choose rollback") ])
      revision = FakeRevision.new(standard_plan)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "awaiting_decision", projection.record.state
      assert_equal %w[primary adversarial], adapter.calls.map(&:kind)
      assert_empty revision.calls
      assert_equal 1, projection.summary.dig("finding_counts", "open_manual")
    end
  end

  def test_exact_scoped_policy_approves_gated_finding_with_a_receipt
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["approval_policies"] = [
        {
          "id" => "plan_wording", "version" => 1,
          "action" => "approve_finding", "risk" => "low",
          "paths" => [ "plan.md" ],
          "valid_from" => "2026-08-12T00:00:00Z",
          "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
        }
      ]
      adapter = success_adapter(primary_findings: [ finding("gated_auto", "Clarify tests") ])
      revision = FakeRevision.new(revised)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "cleared", projection.record.state
      assert_equal 1, projection.record["decisions"].length
      decision = projection.record["decisions"].first
      assert_equal "policy", decision.fetch("origin")
      assert_equal "plan_wording", decision.dig("policy_receipt", "policy_id")
      assert_equal 1, revision.calls.length
    end
  end

  def test_coverage_rows_have_stable_review_bound_fingerprints
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter
      projection = orchestrator(task, cfg, adapter:).advance!

      projection.record["coverage"].each do |entry|
        assert_equal Hive::PlanReview::Identity.coverage(
          review_id: projection.record.review_id, name: entry.fetch("name"),
          policy_fingerprint: projection.record.policy_fingerprint
        ), entry.fetch("fingerprint")
      end
    end
  end

  def test_standard_total_unavailability_degrades
    with_task(standard_plan) do |task, cfg|
      adapter = FakeAdapter.new do |_request|
        Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported")
      end
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "degraded_cleared", projection.record.state
      assert_equal "review_unavailable", projection.record["degradation_reason"]
      assert_equal %w[primary adversarial], adapter.calls.map(&:kind)
    end
  end

  # A mandatory review that could not launch any reviewer has learned nothing
  # about the plan, so it must not cache a verdict. Reviewer routes are not
  # part of the review identity, so a terminal `blocked` here would replay
  # forever even after the reviewer was fixed. Instead the legs are reset and
  # the review retries itself once capability returns.
  def test_mandatory_total_unavailability_resets_instead_of_caching_a_verdict
    with_task(mandatory_plan) do |task, cfg|
      adapter = FakeAdapter.new do |_request|
        Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported")
      end
      projection = orchestrator(task, cfg, adapter:).advance!
      record = projection.record

      refute_equal "blocked", record.state
      assert_equal "reviewing", record.state
      refute record.execution_allowed?
      assert_empty record["blockers"]
      assert_includes record["required_action"], "restore reviewer capability"
      assert record["routes"].any? { |route| route["recovery_reset"] == true },
             "the failed legs must be reset so the next run probes capability again"
      assert_equal %w[primary adversarial], adapter.calls.map(&:kind)
    end
  end

  def test_new_verification_finding_blocks_without_a_second_revision
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      initial = finding("safe_auto", "Clarify tests")
      regression = finding("safe_auto", "New regression", line: 2)
      adapter = success_adapter(
        primary_findings: [ initial ], verification_findings: [ regression ]
      )
      revision = FakeRevision.new(revised)
      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "blocked", projection.record.state
      assert_equal 1, revision.calls.length
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
      assert_equal standard_plan, File.binread(File.join(task.folder, "plan.md"))
    end
  end

  def test_transient_attempt_retries_within_bound_but_unsupported_does_not
    with_task(standard_plan) do |task, cfg|
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary" && (primary_calls += 1) == 1
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "timeout")
        else
          successful_result(request)
        end
      end
      first = orchestrator(task, cfg, adapter:).advance!
      assert_equal "retry_scheduled", first.record.state
      assert_operator Time.iso8601(first.record["retry_at"]), :>, Time.utc(2026, 8, 12, 12)
      projection = orchestrator(
        task, cfg, adapter:, clock: -> { Time.utc(2026, 8, 12, 12, 2) }
      ).advance!

      assert_equal "cleared", projection.record.state
      assert_equal 2, adapter.calls.count { |request| request.kind == "primary" }
      assert_equal 4, projection.record["attempt_ids"].length
    end

    with_task(standard_plan) do |task, cfg|
      adapter = FakeAdapter.new do |request|
        request.kind == "primary" ?
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported") :
          successful_result(request)
      end
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "degraded_cleared", projection.record.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "primary" }
    end
  end

  def test_standard_degradation_does_not_discard_open_manual_finding
    with_task(standard_plan) do |task, cfg|
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          successful_result(request, findings: [ finding("manual", "Choose rollback") ])
        else
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported")
        end
      end

      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "awaiting_decision", projection.record.state
      refute projection.record.execution_allowed?
      assert_equal "manual_answer_required", projection.record["blockers"].first.fetch("reason")
    end
  end

  def test_standard_degradation_still_revises_an_accepted_finding
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["approval_policies"] = [
        {
          "id" => "bounded_wording", "version" => 1,
          "action" => "approve_finding", "risk" => "low",
          "paths" => [ "plan.md" ], "valid_from" => "2026-08-12T00:00:00Z",
          "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
        }
      ]
      accepted = finding("gated_auto", "Clarify tests")
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          successful_result(request, findings: [ accepted ])
        elsif request.kind == "adversarial"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported")
        else
          successful_result(request)
        end
      end
      revision = FakeRevision.new(revised)

      projection = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!

      assert_equal "degraded_cleared", projection.record.state
      assert_equal 1, revision.calls.length
      assert_equal "verified", projection.record["findings"].first.fetch("lifecycle")
      assert_equal revised, File.binread(File.join(task.folder, "plan.md"))
    end
  end

  def test_verification_provider_limit_waits_then_retries_within_the_same_bound
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      finding = finding("safe_auto", "Clarify tests")
      verification_calls = 0
      retry_at = "2026-08-12T13:00:00Z"
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          successful_result(request, findings: [ finding ])
        elsif request.kind == "verification" && (verification_calls += 1) == 1
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "provider_limit", retry_at:
          )
        else
          successful_result(request)
        end
      end
      first = orchestrator(
        task, cfg, adapter:, planner_revision: FakeRevision.new(revised)
      ).advance!
      assert_equal "retry_scheduled", first.record.state
      assert_equal retry_at, first.record["retry_at"]

      held = orchestrator(
        task, cfg, adapter:, planner_revision: FakeRevision.new(revised),
        clock: -> { Time.utc(2026, 8, 12, 12, 30) }
      ).advance!
      assert_equal "retry_scheduled", held.record.state
      assert_equal 1, verification_calls

      cleared = orchestrator(
        task, cfg, adapter:, planner_revision: FakeRevision.new(revised),
        clock: -> { Time.utc(2026, 8, 12, 13) }
      ).advance!
      assert_equal "cleared", cleared.record.state
      assert_equal 2, verification_calls
    end
  end

  def test_optional_specialist_failure_is_distinct_partial_coverage
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["coverage"]["optional"] = [ "security" ]
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          coverage = request.required_coverage.map do |name|
            {
              "name" => name, "required" => name != "security",
              "status" => name == "security" ? "failed" : "completed"
            }
          end
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "partial_coverage", coverage:
          )
        else
          successful_result(request)
        end
      end
      projection = orchestrator(task, cfg, adapter:).advance!

      assert_equal "degraded_cleared", projection.record.state
      assert_equal "partial_coverage", projection.record["degradation_reason"]
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
    end
  end

  def test_unverified_adversarial_route_cannot_satisfy_independent_coverage
    [ [ standard_plan, "degraded_cleared", "terminal_failure" ],
      [ mandatory_plan, "blocked", nil ] ].each do |plan, state, degradation|
      with_task(plan) do |task, cfg|
        adapter = FakeAdapter.new do |request|
          result = successful_result(request)
          next result unless request.kind == "adversarial"

          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "success", coverage: result.coverage,
            route_receipt: result.route_receipt.merge(
              "independence_verified" => false,
              "independence_reason" => "same_family"
            )
          )
        end
        projection = orchestrator(task, cfg, adapter:).advance!

        assert_equal state, projection.record.state
        degradation ? assert_equal(degradation, projection.record["degradation_reason"]) :
          assert_nil(projection.record["degradation_reason"])
        adversarial = projection.record["coverage"].find { |row| row["name"] == "adversarial" }
        assert_equal "failed", adversarial.fetch("status")
        assert_equal "same_family", adversarial.fetch("reason")
      end
    end
  end

  def test_returning_to_an_older_plan_creates_a_new_linked_review
    plan_a = standard_plan
    plan_b = standard_plan.sub("# Plan", "# Plan B")
    with_task(plan_a) do |task, cfg|
      first = orchestrator(task, cfg, adapter: success_adapter).advance!
      File.binwrite(File.join(task.folder, "plan.md"), plan_b)
      second = orchestrator(task, cfg, adapter: success_adapter).advance!
      File.binwrite(File.join(task.folder, "plan.md"), plan_a)
      third = orchestrator(task, cfg, adapter: success_adapter).advance!

      assert_equal first.record.review_id, second.record.prior_review_id
      assert_equal second.record.review_id, third.record.prior_review_id
      refute_equal first.record.review_id, third.record.review_id
      assert_equal "cleared", third.record.state
    end
  end

  def test_metadata_drift_rolls_a_cleared_plan_into_a_new_review
    with_task(standard_plan) do |task, cfg|
      first = orchestrator(task, cfg, adapter: success_adapter).advance!
      File.open(task.meta_yml_path, "a") { |file| file << "owner: platform\n" }
      second = orchestrator(task, cfg, adapter: success_adapter).advance!

      refute_equal first.record.task_generation, second.record.task_generation
      refute_equal first.record.review_id, second.record.review_id
      assert_equal first.record.review_id, second.record.prior_review_id
      assert_equal "cleared", second.record.state
    end
  end

  def test_concurrent_entries_coalesce_under_the_orchestration_lock
    with_task(standard_plan) do |task, cfg|
      adapter = FakeAdapter.new do |request|
        sleep 0.03 if request.kind == "primary"
        successful_result(request)
      end
      ready = Queue.new
      release = Queue.new
      threads = 2.times.map do
        Thread.new do
          ready << true
          release.pop
          orchestrator(task, cfg, adapter:).advance!
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      projections = threads.map(&:value)

      assert_equal 1, projections.map { |projection| projection.record.review_id }.uniq.length
      assert_equal %w[primary adversarial verification], adapter.calls.map(&:kind)
    end
  end

  def test_reentry_stale_publish_and_terminal_revision_paths_are_durable
    with_task(standard_plan) do |task, cfg|
      revised = standard_plan.sub("# Plan", "# Revised")
      runner = orchestrator(
        task, cfg,
        adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
        planner_revision: FakeRevision.new(revised)
      )
      first = runner.advance!
      store = runner.instance_variable_get(:@store)
      suspended = Hive::PlanReview::Record.new(
        first.record.to_h.merge(
          "version" => first.record.version + 1, "state" => "reviewing",
          "outcome" => nil, "execution_allowed" => false,
          "updated_at" => "2026-08-12T12:01:00.000000Z"
        )
      )
      store.publish_current!(suspended, expected_version: first.record.version)
      resumed = runner.advance!
      assert_equal "cleared", resumed.record.state
      second = runner.advance!
      assert_equal first.record.review_id, second.record.review_id

      store.define_singleton_method(:current_validated) do |**|
        raise Hive::PlanReview::StaleObservation, "lost publication race"
      end
      assert_equal first.record.review_id, runner.advance!.record.review_id
    end

    with_task(standard_plan) do |task, cfg|
      failed_revision = Object.new
      failed_revision.define_singleton_method(:call) do |**|
        Hive::PlanReview::PlannerRevision::Result.new(
          outcome: "terminal_failure", candidate_bytes: nil, candidate_digest: nil,
          route_receipt: {}, diagnostic: "planner failed"
        )
      end
      projection = orchestrator(
        task, cfg,
        adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
        planner_revision: failed_revision
      ).advance!
      assert_equal "blocked", projection.record.state
      assert_equal "planner_revision_terminal_failure", projection.record["blockers"].first.fetch("reason")
    end

    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      revision = TransientRevision.new(standard_plan.sub("# Plan", "# Revised"))
      runner = orchestrator(
        task, cfg,
        adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
        planner_revision: revision
      )
      assert_equal "blocked", runner.advance!.record.state
      assert_equal "blocked", runner.advance!.record.state
      assert_equal 1, revision.calls.length
    end
  end

  def test_failed_candidate_verification_adds_a_reviewer_blocker
    revised = standard_plan.sub("# Plan", "# Revised")
    with_task(standard_plan) do |task, cfg|
      adapter = FakeAdapter.new do |request|
        if request.kind == "verification"
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "terminal_failure", findings: [], coverage: [], residual_evidence: [],
            route_receipt: {
              "role" => request.kind, "requested" => request.reviewer,
              "actual" => request.reviewer, "capability_result" => "present",
              "independence_verified" => true
            }, diagnostic: "verification failed"
          )
        else
          successful_result(
            request,
            findings: request.kind == "primary" ? [ finding("safe_auto", "Clarify tests") ] : []
          )
        end
      end
      projection = orchestrator(
        task, cfg, adapter:, planner_revision: FakeRevision.new(revised)
      ).advance!
      assert_equal "blocked", projection.record.state
      assert projection.record["blockers"].any? { |row|
        row.fetch("reason") == "candidate_verification_terminal_failure"
      }
    end
  end

  def test_incomplete_successful_verification_retries_only_missing_dispositions
    revised = standard_plan.sub("# Plan", "# Revised")
    with_task(standard_plan) do |task, cfg|
      findings = [
        finding("safe_auto", "Clarify tests"),
        finding("safe_auto", "Clarify rollback", line: 2)
      ]
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "verification"
          verification_calls += 1
          result = successful_result(request)
          if verification_calls == 1
            result = Hive::PlanReview::Adapters::Base::Result.new(
              **result.to_h.merge(
                residual_evidence: result.residual_evidence.take(1)
              ).transform_keys(&:to_sym)
            )
          end
          result
        else
          successful_result(
            request, findings: request.kind == "primary" ? findings : []
          )
        end
      end
      runner = orchestrator(
        task, cfg, adapter:, planner_revision: FakeRevision.new(revised)
      )

      incomplete = runner.advance!

      assert_equal "verifying", incomplete.record.state
      refute incomplete.record.execution_allowed?
      assert_equal %w[verified incorporated],
                   incomplete.record["findings"].map { |finding| finding.fetch("lifecycle") }
      reset = incomplete.record["routes"].last
      assert_equal "verification", reset.fetch("role")
      assert_equal true, reset.fetch("recovery_reset")
      assert_equal true, reset.fetch("incomplete_attestation_retry")

      cleared = runner.advance!

      assert_equal "cleared", cleared.record.state
      assert cleared.record.execution_allowed?
      verification_requests = adapter.calls.select { |request| request.kind == "verification" }
      assert_equal [ 2, 1 ], verification_requests.map { |request|
        request.verification_findings.length
      }
      assert cleared.record["findings"].all? { |finding|
        finding.fetch("lifecycle") == "verified"
      }
    end
  end

  def test_incomplete_verification_blocks_after_the_transient_retry_bound
    revised = standard_plan.sub("# Plan", "# Revised")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 1
      adapter = FakeAdapter.new do |request|
        result = successful_result(
          request,
          findings: request.kind == "primary" ?
            [ finding("safe_auto", "Clarify tests") ] : []
        )
        next result unless request.kind == "verification"

        Hive::PlanReview::Adapters::Base::Result.new(
          **result.to_h.merge(residual_evidence: []).transform_keys(&:to_sym)
        )
      end
      runner = orchestrator(
        task, cfg, adapter:, planner_revision: FakeRevision.new(revised)
      )

      assert_equal "verifying", runner.advance!.record.state

      exhausted = runner.advance!

      assert_equal "blocked", exhausted.record.state
      assert_equal "disposition_verification_missing",
                   exhausted.record["blockers"].first.fetch("reason")
      assert_equal 2, adapter.calls.count { |request| request.kind == "verification" }
      assert_equal 1, exhausted.record["routes"].count { |route|
        route["incomplete_attestation_retry"] == true
      }
    end
  end

  def test_private_integrity_helpers_cover_corrupt_and_mismatched_inputs
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["coverage"]["required"] = [ "adversarial" ]
      cfg["plan_review"]["coverage"]["optional"] = []
      runner = orchestrator(task, cfg, adapter: success_adapter)
      projection = runner.advance!
      record = projection.record
      store = runner.instance_variable_get(:@store)

      primary = runner.send(:coverage_for, "primary", record.review_id, record.policy_fingerprint)
      assert_equal "whole_document", primary.first.fetch("name")

      incorporated = finding("safe_auto", "Disposition").to_h.merge("lifecycle" => "incorporated")
      unchanged, blockers = runner.send(
        :apply_verification, [ incorporated ], [], "success", []
      )
      assert_equal "incorporated", unchanged.first.fetch("lifecycle")
      assert_equal "disposition_verification_missing", blockers.first.fetch("reason")
      _unchanged, failed_blockers = runner.send(
        :apply_verification, [ incorporated ], [], "terminal_failure", []
      )
      assert_empty failed_blockers

      bad_result = store.write_review_artifact!(
        review_id: record.review_id, basename: "bad-verification-result.json",
        content: "not json"
      )
      bad_record = Hive::PlanReview::Record.new(
        record.to_h.merge(
          "artifacts" => record["artifacts"].merge("verification_result" => bad_result)
        )
      )
      assert_raises(Hive::PlanReview::InvalidRecord) do
        runner.send(:persisted_result, bad_record, "verification")
      end

      original_plan = File.binread(File.join(task.folder, "plan.md"))
      File.write(File.join(task.folder, "plan.md"), "# external edit\n")
      assert_raises(Hive::PlanReview::StaleObservation) do
        runner.send(:promote_candidate!, record, "candidate")
      end
      File.binwrite(File.join(task.folder, "plan.md"), original_plan)
      current = original_plan
      digest_record = Hive::PlanReview::Record.new(
        record.to_h.merge(
          "plan_digest" => Digest::SHA256.hexdigest(current),
          "candidate_plan_digest" => "0" * 64
        )
      )
      assert_raises(Hive::PlanReview::InvalidRecord) do
        runner.send(:promote_candidate!, digest_record, current)
      end

      File.write(File.join(store.root, "level.json"), "not json")
      assert_nil runner.send(:persisted_run_level)
      no_policy = Hive::PlanReview::Record.new(
        record.to_h.merge("artifacts" => record["artifacts"].reject { |key, _| key == "policy" })
      )
      refute runner.send(:policy_configuration_fresh?, no_policy)
      bad_policy = store.write_review_artifact!(
        review_id: record.review_id, basename: "bad-policy.json", content: "not json"
      )
      invalid_policy = Hive::PlanReview::Record.new(
        record.to_h.merge(
          "artifacts" => record["artifacts"].merge("policy" => bad_policy)
        )
      )
      refute runner.send(:policy_configuration_fresh?, invalid_policy)
      refute runner.send(:retry_in_future?, "not-a-time")
      assert_nil runner.send(:safe_plan_digest, File.join(task.folder, "missing-plan.md"))
      assert_equal "symbol", runner.send(:stringify, :symbol)
    end
  end

  def test_review_requirement_metadata_errors_are_typed
    with_task(standard_plan) do |task, cfg|
      runner = orchestrator(task, cfg, adapter: success_adapter)
      task.meta_yml_path && File.write(task.meta_yml_path, "plan_review_required: false\n")
      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        runner.send(:ensure_review_requirement!)
      end
      assert_includes error.message, "could not be persisted"
    end
  end

  private

  def orchestrator(task, cfg, adapter:, planner_revision: FakeRevision.new(standard_plan),
                   route_resolver: method(:resolve_route),
                   clock: -> { Time.utc(2026, 8, 12, 12) })
    Hive::PlanReview::Orchestrator.new(
      task:, cfg:, planner_identity: planner_identity, adapter:,
      planner_revision:, route_resolver:,
      clock:
    )
  end

  def resolve_route(role:, **)
    candidate = {
      "provider" => role == "adversarial" ? "grok" : "codex",
      "model" => role == "adversarial" ? "grok-4.6" : "gpt-5.6-sol",
      "family" => role == "adversarial" ? "grok" : "openai",
      "effort" => "high", "route" => "native_#{role}"
    }
    Hive::PlanReview::RouteResolver::Resolution.new(
      status: "resolved", candidate: candidate,
      receipt: {
        "role" => role, "requested" => candidate, "actual" => candidate,
        "capability_result" => "present", "independence_verified" => true
      }
    )
  end

  def route_identity(provider, model, family, route)
    {
      "provider" => provider, "model" => model, "family" => family,
      "effort" => "high", "route" => route
    }
  end

  def success_adapter(primary_findings: [], verification_findings: [])
    FakeAdapter.new do |request|
      findings = case request.kind
      when "primary" then primary_findings
      when "verification" then verification_findings
      else []
      end
      successful_result(request, findings:)
    end
  end

  def successful_result(request, findings: [])
    residual_evidence = if request.kind == "verification"
      request.verification_findings.map do |finding|
        {
          "finding_fingerprint" => finding.fetch("fingerprint"),
          "status" => "verified", "evidence" => "candidate contains the disposition"
        }
      end
    else []
    end
    Hive::PlanReview::Adapters::Base::Result.new(
        outcome: "success", findings:,
        coverage: request.required_coverage.map do |name|
          { "name" => name, "required" => true, "status" => "completed" }
        end,
        residual_evidence:,
        route_receipt: {
          "role" => request.kind, "requested" => request.reviewer,
          "actual" => request.reviewer, "capability_result" => "present",
          "independence_verified" => true
        }
      )
  end

  def finding(classification, title, line: 1)
    Hive::PlanReview::Finding.new(
      "source" => "whole_document", "classification" => classification,
      "risk" => classification == "manual" ? "high" : "low",
      "title" => title, "description" => "#{title} in the executable plan.",
      "evidence" => {
        "path" => "plan.md", "start_line" => line, "end_line" => line,
        "anchor_digest" => Digest::SHA256.hexdigest("line #{line}")
      },
      "lifecycle" => "open", "display_order" => line
    )
  end

  def with_task(plan)
    Dir.mktmpdir("hive-plan-orchestrator") do |project|
      folder = File.join(project, ".hive-state", "stages", "3-plan", "demo-task")
      FileUtils.mkdir_p(folder)
      meta = File.join(folder, "meta.yml")
      File.write(meta, "id: task-1\nslug: demo-task\nworkflow: coding\n")
      File.write(File.join(folder, "plan.md"), plan)
      task = Task.new(
        folder:, project_root: project, slug: "demo-task", id: "task-1",
        workflow: Workflow.new(id: :coding), meta_yml_path: meta
      )
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["project_root"] = project
      yield task, cfg
    end
  end

  def skip_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - The focused test passes.
      ## Rollback
      Revert the local change; it is reversible.
      <!-- COMPLETE -->
    MD
  end

  def standard_plan
    <<~MD
      ---
      files:
        - lib/demo.rb
        - test/demo_test.rb
      ---
      # Plan
      ## Test scenarios
      - The focused test passes.
      <!-- COMPLETE -->
    MD
  end

  def mandatory_plan
    standard_plan.sub("# Plan", "# Plan\nUpdate authentication permissions")
  end

  def planner_identity
    {
      "provider" => "claude", "model" => "opus", "family" => "anthropic",
      "effort" => "high", "route" => "native_claude"
    }
  end
end
