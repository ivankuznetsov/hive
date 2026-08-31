require "test_helper"
require "hive/config"
require "hive/plan_review/orchestrator"

require "tmpdir"

class PlanReviewOrchestratorTest < Minitest::Test
  include HiveTestHelper

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

  Workflow = Struct.new(:id, keyword_init: true)
  Task = Struct.new(
    :folder, :project_root, :slug, :id, :workflow, :meta_yml_path,
    keyword_init: true
  )

  class FakeAdapter
    attr_reader :calls, :capability_calls

    def initialize(capability: nil, &response)
      @response = response
      @capability = capability
      @calls = []
      @capability_calls = []
    end

    def call(request)
      @calls << request
      @response.call(request)
    end

    def probe_capability(**arguments)
      @capability_calls << arguments
      return { "status" => "present" } unless @capability

      @capability.call(**arguments)
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

  class SequencedRevision
    attr_reader :calls

    def initialize(*candidates)
      @candidates = candidates
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      candidate = @candidates.fetch(@calls.length - 1)
      Hive::PlanReview::PlannerRevision::Result.new(
        outcome: "success", candidate_bytes: candidate,
        candidate_digest: Digest::SHA256.hexdigest(candidate),
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
      assert_equal "route failed", route.fetch("diagnostic")
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

  def test_legacy_cross_provider_planner_model_recovers_once_with_the_same_provider
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      revision = TransientRevision.new(revised)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      legacy = {
        "provider" => "codex", "model" => "claude-opus-4-8",
        "family" => "openai", "effort" => "default", "route" => "codex-cli/v1"
      }
      first = Hive::PlanReview::Orchestrator.new(
        task:, cfg:, planner_identity: legacy, adapter:, planner_revision: revision,
        route_resolver: method(:resolve_route), clock: -> { Time.utc(2026, 8, 12, 12) }
      ).advance!

      assert_equal "retry_scheduled", first.record.state

      repaired = legacy.merge("model" => "default", "reconstructed" => true)
      cleared = Hive::PlanReview::Orchestrator.new(
        task:, cfg:, planner_identity: repaired, adapter:, planner_revision: revision,
        route_resolver: method(:resolve_route), clock: -> { Time.utc(2026, 8, 12, 13) }
      ).advance!

      assert_equal "cleared", cleared.record.state
      models = revision.calls.map { |call| call.fetch(:planner_identity).fetch("model") }
      assert_equal %w[claude-opus-4-8 default], models
      recovered = cleared.record["routes"].select do |route|
        route["planner_identity_contract_recovery"] == true
      end
      assert_equal 2, recovered.length
      assert_equal 1, recovered.count { |route| route["role"] == "planner" }
      assert_equal 1, recovered.count { |route| route["role"] == "planner_revision" }
    end
  end

  def test_exhausted_planner_revision_retries_after_result_contract_upgrade
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      revision = TransientRevision.new(revised)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)

      blocked = runner.advance!
      assert_equal "blocked", blocked.record.state

      routes = blocked.record["routes"].map(&:dup)
      routes.last.delete("planner_revision_contract_version")
      legacy = Hive::PlanReview::Record.new(
        blocked.record.to_h.merge(
          "version" => blocked.record.version + 1,
          "routes" => routes,
          "updated_at" => "2026-08-12T12:01:00.000000Z"
        )
      )
      store = runner.instance_variable_get(:@store)
      store.publish_current!(legacy, expected_version: blocked.record.version)

      cleared = runner.advance!

      assert_equal "cleared", cleared.record.state
      assert_equal 2, revision.calls.length
      reset = cleared.record["routes"].find { |route| route["contract_upgrade_recovery"] }
      assert_equal true, reset.fetch("recovery_reset")
      assert_equal Hive::PlanReview::PlannerRevision::RESULT_CONTRACT_VERSION,
                   reset.fetch("planner_revision_contract_version")
    end
  end

  # `Integer()` refuses both a non-numeric string and a non-numeric type. A
  # route carrying either is unreadable adjudication evidence, so the series
  # must re-run under the current contract instead of trusting a version the
  # orchestrator never compared.
  def test_unreadable_planner_revision_contract_version_reads_as_stale
    orchestrator = Hive::PlanReview::Orchestrator.allocate
    current = Hive::PlanReview::PlannerRevision::RESULT_CONTRACT_VERSION

    assert orchestrator.send(
      :stale_planner_revision_contract?,
      { "planner_revision_contract_version" => "v1" }
    )
    assert orchestrator.send(
      :stale_planner_revision_contract?,
      { "planner_revision_contract_version" => { "major" => current } }
    )
    refute orchestrator.send(
      :stale_planner_revision_contract?,
      { "planner_revision_contract_version" => current }
    )
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

  def test_mandatory_mixed_success_and_unavailability_retries_only_the_missing_leg
    with_task(mandatory_plan) do |task, cfg|
      adversarial_available = false
      resolver = lambda do |role:, **|
        if role == "adversarial" && !adversarial_available
          requested = route_identity("grok", "grok-4.6", "grok", "native_adversarial")
          Hive::PlanReview::RouteResolver::Resolution.new(
            status: "unsupported", candidate: nil,
            receipt: {
              "role" => role, "requested" => requested, "actual" => {},
              "capability_result" => "unsupported", "independence_verified" => false,
              "independence_reason" => "reviewer_family_unavailable",
              "attempts" => [
                { "candidate" => requested, "status" => "unsupported" }
              ]
            }
          )
        else
          resolve_route(role:)
        end
      end
      adapter = success_adapter

      pending = orchestrator(task, cfg, adapter:, route_resolver: resolver).advance!.record

      assert_equal "reviewing", pending.state
      assert_equal %w[primary], adapter.calls.map(&:kind)
      primary_routes = pending["routes"].select { |route| route["role"] == "primary" }
      adversarial_routes = pending["routes"].select { |route| route["role"] == "adversarial" }
      assert_equal 1, primary_routes.length
      assert_equal "success", primary_routes.last.fetch("outcome")
      assert_equal 2, adversarial_routes.length
      assert_equal true, adversarial_routes.last.fetch("recovery_reset")

      adversarial_available = true
      cleared = orchestrator(
        task, cfg, adapter:, route_resolver: resolver
      ).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "primary" }
      assert_equal 1, adapter.calls.count { |request| request.kind == "adversarial" }
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
    end
  end

  def test_legacy_grok_success_retries_once_under_the_current_identity_contract
    with_task(mandatory_plan) do |task, cfg|
      adversarial_calls = 0
      adapter = FakeAdapter.new do |request|
        unless request.kind == "adversarial" && (adversarial_calls += 1) == 1
          next successful_result(request)
        end

        successful = successful_result(request)
        Hive::PlanReview::Adapters::Base::Result.new(
          outcome: successful.outcome,
          findings: successful.findings,
          coverage: successful.coverage,
          residual_evidence: successful.residual_evidence,
          route_receipt: {
            "role" => "adversarial", "requested" => request.reviewer,
            "actual" => {
              "provider" => "grok", "model" => "grok-4.6-build",
              "effort" => "high", "route" => "native_grok_build"
            },
            "capability_result" => "present", "independence_verified" => false,
            "independence_reason" => "reviewer_family_unknown"
          }
        )
      end

      blocked = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "blocked", blocked.state
      assert_equal [ "coverage_failed" ], blocked["blockers"].map { |row| row.fetch("reason") }
      assert_equal 1, adapter.calls.count { |request| request.kind == "primary" }
      assert_equal 1, adapter.calls.count { |request| request.kind == "adversarial" }

      cleared = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "primary" }
      assert_equal 2, adapter.calls.count { |request| request.kind == "adversarial" }
      reset = cleared["routes"].find { |route| route["identity_contract_recovery"] }
      assert_equal true, reset.fetch("recovery_reset")
      assert_equal Hive::PlanReview::RouteResolver::IDENTITY_CONTRACT_VERSION,
                   reset.fetch("identity_contract_version")
    end
  end

  def test_legacy_selected_lenses_parser_failure_retries_once_under_the_current_contract
    with_task(mandatory_plan) do |task, cfg|
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary" && (primary_calls += 1) == 1
          next Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "terminal_failure",
            diagnostic: "plan review selected_lenses must contain lowercase names"
          )
        end

        successful_result(request)
      end

      blocked = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "blocked", blocked.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "primary" }

      cleared = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 2, adapter.calls.count { |request| request.kind == "primary" }
      reset = cleared["routes"].find { |route| route["selected_lenses_contract_recovery"] }
      assert_equal true, reset.fetch("recovery_reset")
      assert_equal 2, reset.fetch("selected_lenses_contract_version")

      orchestrator(task, cfg, adapter:).advance!
      assert_equal 2, adapter.calls.count { |request| request.kind == "primary" }
    end
  end

  def test_legacy_selected_lenses_parser_failure_recovers_every_affected_role_once
    with_task(mandatory_plan) do |task, cfg|
      calls = Hash.new(0)
      adapter = FakeAdapter.new do |request|
        calls[request.kind] += 1
        if %w[primary adversarial].include?(request.kind) && calls.fetch(request.kind) == 1
          next Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "terminal_failure",
            diagnostic: "plan review selected_lenses must contain lowercase names"
          )
        end

        successful_result(request)
      end

      blocked = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "blocked", blocked.state
      assert_equal({ "primary" => 1, "adversarial" => 1 }, calls)

      cleared = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal({ "primary" => 2, "adversarial" => 2, "verification" => 1 }, calls)
      resets = cleared["routes"].select { |route| route["selected_lenses_contract_recovery"] }
      assert_equal %w[adversarial primary], resets.map { |route| route.fetch("role") }.sort

      orchestrator(task, cfg, adapter:).advance!
      assert_equal({ "primary" => 2, "adversarial" => 2, "verification" => 1 }, calls)
    end
  end

  def test_current_selected_lenses_failure_after_recovery_remains_terminal
    with_task(mandatory_plan) do |task, cfg|
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          primary_calls += 1
          diagnostic = if primary_calls == 1
            "plan review selected_lenses must contain lowercase names"
          else
            "plan review selected_lenses must contain lowercase names of 1-64 characters that " \
              "start with a letter and use only lowercase letters, digits, hyphens, or underscores"
          end
          next Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "terminal_failure", diagnostic:,
            route_receipt: { "diagnostic_source" => "parser" }
          )
        end

        successful_result(request)
      end

      assert_equal "blocked", orchestrator(task, cfg, adapter:).advance!.record.state
      assert_equal "blocked", orchestrator(task, cfg, adapter:).advance!.record.state
      assert_equal 2, primary_calls

      orchestrator(task, cfg, adapter:).advance!
      assert_equal 2, primary_calls
    end
  end

  def test_reviewer_authored_legacy_diagnostic_does_not_trigger_contract_recovery
    with_task(mandatory_plan) do |task, cfg|
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          primary_calls += 1
          next Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "terminal_failure",
            diagnostic: "plan review selected_lenses must contain lowercase names",
            route_receipt: { "diagnostic_source" => "reviewer" }
          )
        end

        successful_result(request)
      end

      blocked = orchestrator(task, cfg, adapter:).advance!.record
      replay = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "blocked", blocked.state
      assert_equal "blocked", replay.state
      assert_equal 1, primary_calls
      refute replay["routes"].any? { |route| route["selected_lenses_contract_recovery"] }
    end
  end

  def test_initial_residual_evidence_prompt_contract_recovers_once
    with_task(mandatory_plan) do |task, cfg|
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary" && (primary_calls += 1) <= 2
          next Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "terminal_failure",
            diagnostic: "invalid plan review residual evidence entry",
            route_receipt: { "diagnostic_source" => "parser" }
          )
        end

        successful_result(request)
      end

      assert_equal "blocked", orchestrator(task, cfg, adapter:).advance!.record.state
      retried = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "blocked", retried.state
      assert_equal 2, primary_calls
      reset = retried["routes"].find { |route| route["residual_evidence_contract_recovery"] }
      assert_equal true, reset.fetch("recovery_reset")
      assert_equal 1, reset.fetch("residual_evidence_contract_version")

      orchestrator(task, cfg, adapter:).advance!
      assert_equal 2, primary_calls
    end
  end

  # Mandatory capability failures get cheap re-probes, then move to a paced
  # retry instead of growing current.json on every daemon tick or parking
  # forever after the provider becomes available.
  def test_mandatory_total_unavailability_schedules_after_three_stable_probes
    with_task(mandatory_plan) do |task, cfg|
      available = false
      capability = lambda do |**|
        {
          "status" => available ? "present" : "unsupported",
          "diagnostic" => available ? nil : "missing reviewer"
        }
      end
      adapter = FakeAdapter.new(capability:) do |request|
        available ? successful_result(request) :
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "unsupported", diagnostic: "missing reviewer",
            route_receipt: { "capability_result" => "unsupported" }
          )
      end
      first = orchestrator(task, cfg, adapter:).advance!.record
      second = orchestrator(task, cfg, adapter:).advance!.record
      record = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "reviewing", first.state
      assert_equal "reviewing", second.state
      assert_equal "retry_scheduled", record.state
      refute record.execution_allowed?
      assert_empty record["blockers"]
      assert_includes record["required_action"], "restore reviewer capability"
      assert_equal "2026-08-12T12:05:00.000000Z", record["retry_at"]
      assert_equal 2, adapter.calls.length
      counts = record["routes"].filter_map do |route|
        route["capability_probe_count"] if route["role"] == "primary"
      end
      assert_equal [ 3 ], counts
      route_count = record["routes"].length
      attempt_count = record["attempt_ids"].length
      attempt_directories = Dir[
        File.join(task.folder, "plan-review", "reviews", "*", "attempts", "*")
      ].length

      available = true
      held = orchestrator(
        task, cfg, adapter:, clock: -> { Time.utc(2026, 8, 12, 12, 4, 59) }
      ).advance!.record
      assert_equal "retry_scheduled", held.state
      assert_equal 2, adapter.calls.length

      available = false
      10.times do
        due = Time.iso8601(record["retry_at"])
        record = orchestrator(task, cfg, adapter:, clock: -> { due }).advance!.record
        assert_equal "retry_scheduled", record.state
        assert_equal route_count, record["routes"].length
        assert_equal attempt_count, record["attempt_ids"].length
        assert_equal attempt_directories, Dir[
          File.join(task.folder, "plan-review", "reviews", "*", "attempts", "*")
        ].length
      end
      primary_probe = record["routes"].find do |route|
        route["role"] == "primary" && route["capability_probe_count"]
      end
      assert_equal 13, primary_probe.fetch("capability_probe_count")
      assert_equal 2, adapter.calls.length

      available = true
      due = Time.iso8601(record["retry_at"])
      cleared = orchestrator(
        task, cfg, adapter:, clock: -> { due }
      ).advance!.record
      assert_equal "cleared", cleared.state
      assert_equal 5, adapter.calls.length
    end
  end

  def test_policy_approved_verification_finding_runs_a_second_revision
    revised_once = standard_plan.sub("# Plan", "# Revised once")
    revised_twice = standard_plan.sub("# Plan", "# Revised twice")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["approval_policies"] = [
        {
          "id" => "verification_followup", "version" => 1,
          "action" => "approve_finding", "risk" => "low",
          "paths" => [ "plan.md" ],
          "valid_from" => "2026-08-12T00:00:00Z",
          "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
        }
      ]
      initial = finding("safe_auto", "Clarify tests")
      regression = finding("gated_auto", "New regression", line: 2)
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        findings = if request.kind == "primary"
          [ initial ]
        elsif request.kind == "verification" && (verification_calls += 1) == 1
          [ regression ]
        else
          []
        end
        successful_result(request, findings:)
      end
      revision = SequencedRevision.new(revised_once, revised_twice)
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)

      followup = runner.advance!

      assert_equal "revising", followup.record.state
      assert_equal "approved", followup.record["findings"].last.fetch("lifecycle")
      assert_equal "policy", followup.record["decisions"].last.fetch("origin")

      projection = runner.advance!

      assert_equal "cleared", projection.record.state
      assert_equal 2, revision.calls.length
      assert_equal revised_once, revision.calls.last.fetch(:plan_bytes)
      assert_equal 2, adapter.calls.count { |request| request.kind == "verification" }
      assert_equal revised_twice, File.binread(File.join(task.folder, "plan.md"))
    end
  end

  def test_capped_verification_revision_is_a_noop_on_external_reentry
    candidates = 4.times.map do |index|
      standard_plan.sub("# Plan", "# Revision #{index + 1}")
    end
    with_task(standard_plan) do |task, cfg|
      residual = finding("safe_auto", "Still needs revision")
      adapter = FakeAdapter.new do |request|
        successful_result(
          request,
          findings: request.kind == "primary" || request.kind == "verification" ?
            [ residual ] : []
        )
      end
      revision = SequencedRevision.new(*candidates)
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)

      2.times { assert_equal "revising", runner.advance!.record.state }
      capped = runner.advance!.record

      assert_equal "blocked", capped.state
      assert_equal Hive::PlanReview::Orchestrator::MAX_VERIFICATION_REVISION_ROUNDS,
                   revision.calls.length
      verification_calls = adapter.calls.count { |request| request.kind == "verification" }
      version = capped.version

      replay = runner.advance!.record

      assert_equal version, replay.version
      assert_equal capped.to_h, replay.to_h
      assert_equal Hive::PlanReview::Orchestrator::MAX_VERIFICATION_REVISION_ROUNDS,
                   revision.calls.length
      assert_equal verification_calls,
                   adapter.calls.count { |request| request.kind == "verification" }
    end
  end

  def test_repeated_incorporated_finding_reopens_with_its_prior_decision
    existing = finding("gated_auto", "Still broken")
    accepted = Hive::PlanReview::Finding.new(
      existing.to_h.merge(
        "lifecycle" => "incorporated", "decision_id" => "prd-#{'a' * 64}"
      )
    )
    runner = Hive::PlanReview::Orchestrator.allocate

    findings, = runner.send(
      :apply_verification, [ accepted.to_h ], [ existing.to_h ], "success", []
    )

    assert_equal "approved", findings.first.fetch("lifecycle")
    assert_equal "prd-#{'a' * 64}", findings.first.fetch("decision_id")

    safe = finding("safe_auto", "Safe residual", line: 2)
    manual = finding("manual", "Manual residual", line: 3)
    fyi = finding("fyi", "FYI residual", line: 4)
    reopened = [ safe, manual, fyi ].map do |finding|
      runner.send(:reopen_verification_finding, finding, finding)
    end
    assert_equal %w[open open open], reopened.map { |finding| finding.fetch("lifecycle") }
  end

  def test_legacy_policy_approval_resets_terminal_verification_before_revising
    revised_once = standard_plan.sub("# Plan", "# Revised once")
    revised_twice = standard_plan.sub("# Plan", "# Revised twice")
    with_task(standard_plan) do |task, cfg|
      initial = finding("safe_auto", "Clarify tests")
      regression = finding("gated_auto", "New regression", line: 2)
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        findings = if request.kind == "primary"
          [ initial ]
        elsif request.kind == "verification" && (verification_calls += 1) == 1
          [ regression ]
        else
          []
        end
        successful_result(request, findings:)
      end
      revision = SequencedRevision.new(revised_once, revised_twice)
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)

      assert_equal "awaiting_decision", runner.advance!.record.state

      cfg["plan_review"]["approval_policies"] = [
        {
          "id" => "legacy_followup", "version" => 1,
          "action" => "approve_finding", "risk" => "low", "paths" => [ "plan.md" ],
          "valid_from" => "2026-08-12T00:00:00Z",
          "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
        }
      ]
      projection = runner.advance!

      assert_equal "cleared", projection.record.state
      assert_equal 2, revision.calls.length
      assert_equal 2, adapter.calls.count { |request| request.kind == "verification" }
      assert projection.record["routes"].any? { |route|
        route["role"] == "verification" && route["verification_followup"] == true
      }
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

  def test_mandatory_exhausted_transient_series_retries_automatically_with_paced_backoff
    with_task(mandatory_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary" && (primary_calls += 1) <= 2
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "timeout")
        else
          successful_result(request)
        end
      end

      first = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "retry_scheduled", first.state
      assert_equal 1, primary_calls
      first_due = Time.iso8601(first["retry_at"])
      assert_operator first_due, :>, Time.utc(2026, 8, 12, 12)

      second = orchestrator(
        task, cfg, adapter:, clock: -> { first_due }
      ).advance!.record

      assert_equal "retry_scheduled", second.state
      assert_equal 2, primary_calls
      second_due = Time.iso8601(second["retry_at"])
      assert_operator second_due - first_due, :>=, 10 * 60

      cleared = orchestrator(
        task, cfg, adapter:, clock: -> { second_due }
      ).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 3, primary_calls
      assert_equal 1, adapter.calls.count { |request| request.kind == "adversarial" }
      recoveries = cleared["routes"].select { |route| route["transient_series_recovery"] }
      assert_equal [ 1, 2 ], recoveries.map { |route| route.fetch("transient_series") }
    end
  end

  def test_legacy_past_due_transient_series_retries_in_the_same_advance
    with_task(mandatory_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      primary_calls = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary" && (primary_calls += 1) == 1
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "timeout", retry_at: "2026-08-11T00:00:00Z"
          )
        else
          successful_result(request)
        end
      end

      cleared = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 2, primary_calls
      reset = cleared["routes"].find { |route| route["transient_series_recovery"] }
      assert_equal 1, reset.fetch("transient_series")
    end
  end

  def test_standard_exhausted_transient_series_keeps_the_degraded_fallback
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      adapter = FakeAdapter.new do |request|
        request.kind == "primary" ?
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "timeout") :
          successful_result(request)
      end

      projection = orchestrator(task, cfg, adapter:).advance!.record

      assert_equal "degraded_cleared", projection.state
      refute projection["routes"].any? { |route| route["transient_series_recovery"] }
    end
  end

  def test_transient_series_retry_uses_the_current_clock_for_an_invalid_hint
    with_task(mandatory_plan) do |task, cfg|
      runner = orchestrator(task, cfg, adapter: success_adapter)
      record = Struct.new(:review_id).new("pr-#{"a" * 64}")

      due = runner.send(
        :transient_series_retry_at, record, "primary",
        { "retry_at" => "not-a-time" }, 1
      )

      assert_operator Time.iso8601(due), :>, Time.utc(2026, 8, 12, 12, 5)
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
      prepare_test_task_lease_repository(folder)
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
