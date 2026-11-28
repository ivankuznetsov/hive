require "test_helper"
require "hive/config"
require "hive/plan_review/orchestrator"
require "hive/plan_review/decision_service"

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
    :folder, :project_root, :slug, :id, :workflow, :meta_yml_path, :project_name,
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

    def initialize(candidate, failures: 1, after_failure: nil)
      @candidate = candidate
      @failures = failures
      @after_failure = after_failure
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      if @calls.length <= @failures
        @after_failure&.call
        return Hive::PlanReview::PlannerRevision::Result.new(
          outcome: "retryable_failure", candidate_bytes: nil, candidate_digest: nil,
          route_receipt: arguments.fetch(:planner_identity), diagnostic: "route failed"
        )
      end

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
      assert_equal "verified", projection.record["findings"].last.fetch("lifecycle")
    end
  end

  def test_shipped_defaults_skip_the_adversarial_leg_at_standard_level
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan, shipped_defaults: true) do |task, cfg|
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      projection = orchestrator(task, cfg, adapter:, planner_revision: FakeRevision.new(revised)).advance!

      assert_equal "cleared", projection.record.state
      assert_equal %w[primary verification], adapter.calls.map(&:kind)
      refute(projection.record["coverage"].any? { |entry| entry.fetch("name") == "adversarial" })
    end
  end

  def test_adversarial_min_level_off_skips_the_adversarial_leg_even_when_mandatory
    revised = mandatory_plan.sub("# Plan", "# Revised plan")
    with_task(mandatory_plan, shipped_defaults: true) do |task, cfg|
      cfg["plan_review"]["adversarial_min_level"] = "off"
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      orchestrator(task, cfg, adapter:, planner_revision: FakeRevision.new(revised)).advance!

      refute_includes adapter.calls.map(&:kind), "adversarial"
    end
  end

  def test_adversarial_min_level_standard_restores_the_adversarial_leg
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan, shipped_defaults: true) do |task, cfg|
      cfg["plan_review"]["adversarial_min_level"] = "standard"
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      orchestrator(task, cfg, adapter:, planner_revision: FakeRevision.new(revised)).advance!

      assert_equal %w[primary adversarial verification], adapter.calls.map(&:kind)
    end
  end

  def test_shipped_defaults_allow_one_standard_revision_round
    with_task(standard_plan, shipped_defaults: true) do |task, cfg|
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        result = successful_result(request, findings: request.kind == "primary" ?
          [ finding("safe_auto", "Clarify tests") ] : [])
        if request.kind == "verification"
          verification_calls += 1
          result = successful_result(request, findings: [ finding("safe_auto", "Another edge", line: verification_calls + 1) ])
        end
        result
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised"))
      record = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!.record

      assert_equal "blocked", record.state
      assert_equal 1, revision.calls.size
      assert_equal [ { "owner" => "planner", "reason" => "revision_round_limit" } ], record["blockers"]
      assert_equal "start a new linked plan: hive run demo-task --project hivedev (operator decisions carry forward)",
                   record.required_action
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

  def test_planner_revision_falls_back_after_a_transient_failure_without_rekeying
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["routes"]["planner_revision_fallback"] = {
        "agent" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
        "effort" => "high", "route" => "native_codex"
      }
      revision = TransientRevision.new(revised, failures: 2)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])

      first = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!.record
      second = orchestrator(
        task, cfg, adapter:, planner_revision: revision,
        clock: -> { Time.utc(2026, 8, 12, 13) }
      ).advance!.record
      cleared = orchestrator(
        task, cfg, adapter:, planner_revision: revision,
        clock: -> { Time.utc(2026, 8, 12, 14) }
      ).advance!.record

      assert_equal first.review_id, second.review_id
      assert_equal first.review_id, cleared.review_id
      providers = revision.calls.map do |call|
        call.fetch(:planner_identity).fetch("provider")
      end
      assert_equal %w[claude codex codex], providers
      assert revision.calls.all? do |call|
        call.fetch(:planner_authority).fetch("provider") == "claude"
      end
      fallback_routes = cleared["routes"].select do |route|
        route["role"] == "planner_revision" && route["planner_revision_fallback"] == true
      end
      assert_equal 2, fallback_routes.length
      assert fallback_routes.all? do |route|
        route.dig("planner_authority", "provider") == "claude" &&
          route.fetch("fallback_reason") == "captured_planner_transient_failure"
      end
      assert_equal "cleared", cleared.state
    end
  end

  def test_planner_revision_opens_cooled_retry_series_until_provider_recovers
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      revision = TransientRevision.new(revised, failures: 2)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])

      first = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!.record

      assert_equal "retry_scheduled", first.state
      first_due = Time.iso8601(first["retry_at"])

      second = orchestrator(
        task, cfg, adapter:, planner_revision: revision, clock: -> { first_due }
      ).advance!.record

      assert_equal "retry_scheduled", second.state
      second_due = Time.iso8601(second["retry_at"])
      assert_operator second_due - first_due, :>=, 10 * 60

      cleared = orchestrator(
        task, cfg, adapter:, planner_revision: revision, clock: -> { second_due }
      ).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 3, revision.calls.length
      recoveries = cleared["routes"].select do |route|
        route["role"] == "planner_revision" && route["transient_series_recovery"]
      end
      assert_equal [ 1, 2 ], recoveries.map { |route| route.fetch("transient_series") }
    end
  end

  def test_newly_exhausted_past_due_planner_revision_retries_in_the_same_advance
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      base = Time.utc(2026, 8, 12, 12)
      failed = false
      anchored = false
      clock = lambda do
        next base unless failed
        next base + (24 * 60 * 60) if anchored

        anchored = true
        base
      end
      revision = TransientRevision.new(
        revised, after_failure: -> { failed = true }
      )
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])

      cleared = orchestrator(
        task, cfg, adapter:, planner_revision: revision, clock:
      ).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 2, revision.calls.length
      assert cleared["routes"].any? { |route| route["transient_series_recovery"] }
    end
  end

  def test_legacy_exhausted_past_due_planner_revision_retries_in_the_same_advance
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      revision = TransientRevision.new(revised)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)
      scheduled = runner.advance!.record
      routes = scheduled["routes"].reject { |route| route["transient_series_recovery"] }
      legacy = Hive::PlanReview::Record.new(
        scheduled.to_h.merge(
          "version" => scheduled.version + 1,
          "routes" => routes,
          "retry_at" => routes.last.fetch("retry_at"),
          "updated_at" => "2026-08-12T12:01:00.000000Z"
        )
      )
      store = runner.instance_variable_get(:@store)
      store.publish_current!(legacy, expected_version: scheduled.version)

      cleared = orchestrator(
        task, cfg, adapter:, planner_revision: revision,
        clock: -> { Time.utc(2026, 8, 13, 12) }
      ).advance!.record

      assert_equal "cleared", cleared.state
      assert_equal 2, revision.calls.length
      assert cleared["routes"].any? { |route| route["transient_series_recovery"] }
    end
  end

  def test_current_contract_blocked_planner_revision_enters_cooled_recovery
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      revision = TransientRevision.new(revised)
      adapter = success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ])
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)
      scheduled = runner.advance!.record
      routes = scheduled["routes"].reject { |route| route["transient_series_recovery"] }
      legacy = Hive::PlanReview::Record.new(
        scheduled.to_h.merge(
          "version" => scheduled.version + 1,
          "state" => "blocked", "outcome" => "blocked", "routes" => routes,
          "blockers" => [
            { "owner" => "planner", "reason" => "planner_revision_retryable_failure" }
          ],
          "required_action" => "repair the planner route and start a linked plan generation",
          "retry_at" => nil,
          "updated_at" => "2026-08-12T12:01:00.000000Z"
        )
      )
      store = runner.instance_variable_get(:@store)
      store.publish_current!(legacy, expected_version: scheduled.version)

      recovered = runner.advance!.record

      assert_equal "retry_scheduled", recovered.state
      assert_equal 1, revision.calls.length
      reset = recovered["routes"].last
      assert_equal "planner_revision", reset.fetch("role")
      assert_equal true, reset.fetch("transient_series_recovery")
      assert_equal Hive::PlanReview::PlannerRevision::RESULT_CONTRACT_VERSION,
                   reset.fetch("planner_revision_contract_version")
    end
  end

  # `Integer()` refuses both a non-numeric string and a non-numeric type. A
  # route carrying either is unreadable adjudication evidence, so the series
  # must re-run under the current contract instead of trusting a version the
  # orchestrator never compared.

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

  # hivedev f2-follow-up: the dependency first appeared in a plan-review
  # revision, after the planner-run adoption point, so meta.yml never learned
  # it and admission parked the cleared task on plan_dependency_missing. The
  # operator's hand copy then staled the review and restarted critique.
  # Promotion now adopts it, and the cleared review stays current.
  def test_candidate_promotion_adopts_a_dependency_added_by_the_revision
    revised = standard_plan.sub("files:", "depends_on: hivedev:base-task\nfiles:")
    with_task(standard_plan) do |task, cfg|
      seed_prerequisite(task.project_root, "base-task", id: 10)
      with_registered_hivedev(task.project_root) do
        projection = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: FakeRevision.new(revised)
        ).advance!

        assert_equal "cleared", projection.record.state
        assert_equal revised, File.binread(File.join(task.folder, "plan.md"))
        assert_equal "hivedev:base-task", YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
        assert Hive::PlanReview::Identity.task_generation_current?(task, projection.record.task_generation)
        assert_equal "current", Hive::PlanReview::TransitionGuard.freshness(
          task:, projection:, config: cfg
        ).fetch("status")
      end
    end
  end

  # hivedev c5: meta.yml already carried one dependency and the revision added
  # a second, spelled with the project qualifier.
  def test_candidate_promotion_adopts_a_strict_superset_of_meta_dependencies
    revised = standard_plan.sub(
      "files:", "depends_on:\n  - hivedev:base-task\n  - other-task\nfiles:"
    )
    with_task(standard_plan, meta_depends_on: "base-task") do |task, cfg|
      seed_prerequisite(task.project_root, "base-task", id: 10)
      seed_prerequisite(task.project_root, "other-task", id: 11)
      with_registered_hivedev(task.project_root) do
        projection = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: FakeRevision.new(revised)
        ).advance!

        assert_equal "cleared", projection.record.state
        assert_equal %w[hivedev:base-task other-task],
                     YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
        assert Hive::PlanReview::Identity.task_generation_current?(task, projection.record.task_generation)
      end
    end
  end

  def test_candidate_promotion_never_replaces_an_existing_meta_dependency
    revised = standard_plan.sub("files:", "depends_on: other-task\nfiles:")
    with_task(standard_plan, meta_depends_on: "base-task") do |task, cfg|
      seed_prerequisite(task.project_root, "base-task", id: 10)
      seed_prerequisite(task.project_root, "other-task", id: 11)
      with_registered_hivedev(task.project_root) do
        revision = FakeRevision.new(revised)
        projection = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: revision
        ).advance!

        assert_equal "blocked", projection.record.state
        refute projection.record.execution_allowed?
        assert_equal 2, revision.calls.length
        assert_includes revision.calls.last[:dependency_diagnostic].to_s, "plan_dependency_mismatch"
        assert_equal "plan_dependency_correction_exhausted",
                     projection.record["blockers"].first["reason"]
        assert_equal "operator", projection.record["blockers"].first["owner"]
        assert_equal standard_plan, File.binread(File.join(task.folder, "plan.md"))
        assert_equal "base-task", YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
      end
    end
  end

  def test_revision_invalid_dependency_gets_one_correction_then_adopts_and_preserves_identity
    invalid_candidate = standard_plan.sub("files:", "depends_on:\n  - C4\n  - F2\nfiles:")
    fixed_candidate = standard_plan.sub("files:", "depends_on:\n  - c4-base-task\n  - f2-next-task\nfiles:")
    with_task(standard_plan) do |task, cfg|
      seed_prerequisite(task.project_root, "c4-base-task", id: 10)
      seed_prerequisite(task.project_root, "f2-next-task", id: 11)
      with_registered_hivedev(task.project_root) do
        calls = []
        revision = Object.new
        revision.define_singleton_method(:call) do |**args|
          calls << args
          bytes = calls.length == 1 ? invalid_candidate : fixed_candidate
          Hive::PlanReview::PlannerRevision::Result.new(
            outcome: "success", candidate_bytes: bytes,
            candidate_digest: Digest::SHA256.hexdigest(bytes),
            route_receipt: args.fetch(:planner_identity), diagnostic: nil
          )
        end

        projection = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: revision
        ).advance!

        assert_equal "cleared", projection.record.state
        assert_equal 2, calls.length
        assert_nil calls.first[:dependency_diagnostic]
        assert_includes calls.last[:dependency_diagnostic], "C4"
        assert_includes calls.last[:dependency_diagnostic], "F2"
        assert_includes calls.last[:dependency_diagnostic], "c4-base-task"
        assert_includes calls.last[:dependency_diagnostic], "f2-next-task"
        assert_equal fixed_candidate, File.binread(File.join(task.folder, "plan.md"))
        assert_equal %w[c4-base-task f2-next-task],
                     YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
        assert Hive::PlanReview::Identity.task_generation_current?(task, projection.record.task_generation)
      end
    end
  end

  def test_revision_unknown_target_exhausts_after_one_correction_without_mutating_plan_or_meta_or_retrying
    bad_candidate = standard_plan.sub("files:", "depends_on: unknown-prereq\nfiles:")
    with_task(standard_plan) do |task, cfg|
      with_registered_hivedev(task.project_root) do
        revision = FakeRevision.new(bad_candidate)
        projection = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: revision
        ).advance!

        assert_equal "blocked", projection.record.state
        refute projection.record.execution_allowed?
        assert_equal 2, revision.calls.length
        assert_equal "plan_dependency_correction_exhausted",
                     projection.record["blockers"].first["reason"]
        assert_equal standard_plan, File.binread(File.join(task.folder, "plan.md"))
        assert_nil YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
        assert_empty projection.record["routes"].select { |r| r["transient_series_recovery"] }

        # Re-entering orchestrator on the same exhausted review spawns zero additional revisions.
        reentered = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: revision
        ).advance!
        assert_equal "blocked", reentered.record.state
        assert_equal 2, revision.calls.length
      end
    end
  end

  def test_revision_environmental_failure_blocks_without_spending_correction
    cross_candidate = standard_plan.sub("files:", "depends_on: missingproj:some-task\nfiles:")
    with_task(standard_plan) do |task, cfg|
      with_registered_hivedev(task.project_root) do
        revision = FakeRevision.new(cross_candidate)
        projection = orchestrator(
          task, cfg,
          adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
          planner_revision: revision
        ).advance!

        assert_equal "blocked", projection.record.state
        refute projection.record.execution_allowed?
        assert_equal 1, revision.calls.length
        assert_equal "dependency_project_unknown",
                     projection.record["blockers"].first["reason"]
        assert_equal standard_plan, File.binread(File.join(task.folder, "plan.md"))
        refute File.exist?(Hive::PlanDependencyCorrection.path(task.folder))
      end
    end
  end

  def test_direct_clearance_paths_refuse_invalid_existing_plan_for_skipped_cleared_and_degraded
    invalid_skip = skip_plan.sub("files:", "depends_on:\n  - F2\n  - F3\nfiles:")
    with_task(invalid_skip) do |task, cfg|
      with_registered_hivedev(task.project_root) do
        projection = orchestrator(task, cfg, adapter: success_adapter).advance!
        assert_equal "blocked", projection.record.state
        refute projection.record.execution_allowed?
        assert_equal "plan_dependency_invalid", projection.record["blockers"].first["reason"]
        assert_equal invalid_skip, File.binread(File.join(task.folder, "plan.md"))
        assert_nil YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
      end
    end

    invalid_standard = standard_plan.sub("files:", "depends_on: F2\nfiles:")
    with_task(invalid_standard) do |task, cfg|
      with_registered_hivedev(task.project_root) do
        projection = orchestrator(task, cfg, adapter: success_adapter).advance!
        assert_equal "blocked", projection.record.state
        refute projection.record.execution_allowed?
        assert_equal "plan_dependency_invalid", projection.record["blockers"].first["reason"]
      end
    end

    with_task(invalid_standard) do |task, cfg|
      with_registered_hivedev(task.project_root) do
        degraded_adapter = FakeAdapter.new do |request|
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "unsupported",
            findings: [],
            coverage: request.required_coverage.map { |name| { "name" => name, "status" => "missing" } },
            route_receipt: { "actual" => request.reviewer, "capability_result" => "unsupported" },
            diagnostic: "missing reviewer"
          )
        end
        projection = orchestrator(task, cfg, adapter: degraded_adapter).advance!
        assert_equal "blocked", projection.record.state
        refute projection.record.execution_allowed?
        assert_equal "plan_dependency_invalid", projection.record["blockers"].first["reason"]
      end
    end
  end

  def test_clearance_custody_rejects_stale_rewrite_and_restores_canonical_plan
    revised = standard_plan.sub("files:", "depends_on: base-task\nfiles:")
    with_task(standard_plan) do |task, cfg|
      seed_prerequisite(task.project_root, "base-task", id: 10)
      with_registered_hivedev(task.project_root) do
        stale_result = Struct.new(:stale?).new(true)
        original_rewrite = Hive::TaskMeta.method(:rewrite)
        stub_rewrite = lambda do |folder, updates, **kwargs|
          if updates.key?(:depends_on)
            stale_result
          else
            original_rewrite.call(folder, updates, **kwargs)
          end
        end

        with_replaced_singleton_method(Hive::TaskMeta, :rewrite, stub_rewrite) do
          projection = orchestrator(
            task, cfg,
            adapter: success_adapter(primary_findings: [ finding("safe_auto", "Clarify tests") ]),
            planner_revision: FakeRevision.new(revised)
          ).advance!

          refute projection.record.execution_allowed?
          assert_equal standard_plan, File.binread(File.join(task.folder, "plan.md"))
          assert_nil YAML.safe_load(File.read(task.meta_yml_path))["depends_on"]
        end
      end
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
      assert_equal %w[primary adversarial decision_triage], adapter.calls.map(&:kind)
      assert_empty revision.calls
      assert_equal 1, projection.summary.dig("finding_counts", "open_manual")
    end
  end

  # Two gated findings open at once used to cost a revision round per
  # approval, so the second approval could hit revision_round_limit after the
  # operator had answered everything (todero, 2026-11-16).
  def test_simultaneous_gated_findings_are_integrated_in_one_revision_round
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter(primary_findings: [
        finding("gated_auto", "Keep the v1 token format"),
        finding("gated_auto", "Version the public endpoint", line: 2)
      ])
      revision = FakeRevision.new(revised)
      advance = -> { orchestrator(task, cfg, adapter:, planner_revision: revision).advance! }

      initial = advance.call
      assert_equal "awaiting_decision", initial.record.state
      first, second = open_findings(initial.record).map { |entry| entry.fetch("fingerprint") }
      assert_equal "approve gated plan finding #{first}", initial.record.required_action

      decide(task, initial.record, "approve_finding", first)
      waiting = advance.call
      assert_equal "awaiting_decision", waiting.record.state
      assert_empty revision.calls, "an approval with another gate still open must not spend a round"
      assert_equal "approve gated plan finding #{second}", waiting.record.required_action
      assert_equal [ second ], waiting.record["blockers"].map { |blocker| blocker["finding_fingerprint"] }
      assert_equal "approved", waiting.record["findings"].find { |entry| entry["fingerprint"] == first }["lifecycle"]
      refute waiting.record.execution_allowed?

      decide(task, waiting.record, "approve_finding", second)
      cleared = advance.call
      assert_equal "cleared", cleared.record.state
      assert_equal 1, revision.calls.size
      assert_equal [ first, second ].sort, revision.calls.first[:findings].map(&:fingerprint).sort
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }
      assert_equal 2, cleared.summary.dig("finding_counts", "verified")
      assert_equal revised, File.read(File.join(task.folder, "plan.md"))
    end
  end

  # The batched revision's verification can hit a provider quota wall. It
  # retries hourly without exhausting the transient budget or spending another
  # round, then clears once the provider recovers.
  def test_batched_revision_verification_rides_out_a_provider_limit_hourly
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      walls = 2
      adapter = FakeAdapter.new do |request|
        if request.kind == "verification" && (walls -= 1) >= 0
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "provider_limit", retry_at: "2026-08-19T00:00:00Z")
        else
          successful_result(request, findings: request.kind == "primary" ? [
            finding("gated_auto", "Keep the v1 token format"),
            finding("gated_auto", "Version the public endpoint", line: 2)
          ] : [])
        end
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised plan"))
      now = Time.utc(2026, 8, 12, 12)
      advance = ->(clock = now) { orchestrator(task, cfg, adapter:, planner_revision: revision, clock: -> { clock }).advance! }

      initial = advance.call
      first, second = open_findings(initial.record).map { |entry| entry.fetch("fingerprint") }
      decide(task, initial.record, "approve_finding", first)
      waiting = advance.call
      assert_equal "awaiting_decision", waiting.record.state
      decide(task, waiting.record, "approve_finding", second)

      2.times do |hour|
        clock = now + (hour * 3600)
        walled = advance.call(clock)
        assert_equal "retry_scheduled", walled.record.state
        assert_equal (clock + 3600).utc.iso8601(6), walled.record["retry_at"]
        assert_equal 1, revision.calls.size
      end
      cleared = advance.call(now + 7200)
      assert_equal "cleared", cleared.record.state
      assert_equal 1, revision.calls.size
      assert_equal [ first, second ].sort, revision.calls.first[:findings].map(&:fingerprint).sort
      assert_equal 3, adapter.calls.count { |request| request.kind == "verification" }
    end
  end

  # A manual answer and a gated approval, decided in either order, plus a safe
  # fix accepted automatically: nothing revises until both choices are made,
  # then one round integrates all three.
  def test_mixed_manual_and_gated_decisions_share_one_round_with_deferred_safe_fixes
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter(primary_findings: [
        finding("safe_auto", "Name the rollback test"),
        finding("gated_auto", "Approve the schema migration", line: 2),
        finding("manual", "Choose the retention window", line: 3)
      ])
      revision = FakeRevision.new(revised)
      advance = -> { orchestrator(task, cfg, adapter:, planner_revision: revision).advance! }

      initial = advance.call
      assert_equal "awaiting_decision", initial.record.state
      assert_empty revision.calls, "the safe fix waits for the open choices"
      safe = open_finding(initial.record, "safe_auto").fetch("fingerprint")
      gated = open_finding(initial.record, "gated_auto").fetch("fingerprint")
      manual = open_finding(initial.record, "manual").fetch("fingerprint")
      assert_equal "approve gated plan finding #{gated}", initial.record.required_action

      decide(task, initial.record, "answer_finding", manual, answer: "Keep 30 days")
      waiting = advance.call
      assert_equal "awaiting_decision", waiting.record.state
      assert_empty revision.calls
      assert_equal "approve gated plan finding #{gated}", waiting.record.required_action
      assert_equal [ "gated_approval_required" ], waiting.record["blockers"].map { |blocker| blocker["reason"] }

      decide(task, waiting.record, "approve_finding", gated)
      cleared = advance.call
      assert_equal "cleared", cleared.record.state
      assert_equal 1, revision.calls.size
      integrated = revision.calls.first[:findings]
      assert_equal [ safe, gated, manual ].sort, integrated.map(&:fingerprint).sort
      assert_equal "Keep 30 days", integrated.find { |entry| entry.fingerprint == manual }["answer"]
      assert_empty revision.calls.first[:pending_findings]
      assert_equal revised, File.read(File.join(task.folder, "plan.md"))
    end
  end

  # The live failure: safe fixes spent the base budget, then verification
  # raised two gates at once. Both decisions now share the single
  # operator-decision round instead of the second one blocking.
  def test_decisions_raised_at_the_base_cap_share_the_operator_decision_round
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["max_revision_rounds"] = { "standard" => 1, "mandatory" => 1 }
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        findings = case request.kind
        when "primary" then [ finding("safe_auto", "Clarify tests") ]
        when "verification"
          (verification_calls += 1) == 1 ?
            [ finding("gated_auto", "Keep the v1 token format", line: 2),
              finding("gated_auto", "Version the public endpoint", line: 3) ] : []
        else []
        end
        successful_result(request, findings:)
      end
      revision = SequencedRevision.new(
        standard_plan.sub("# Plan", "# Revised once"), standard_plan.sub("# Plan", "# Revised twice")
      )
      advance = -> { orchestrator(task, cfg, adapter:, planner_revision: revision).advance! }

      gated = advance.call
      assert_equal "awaiting_decision", gated.record.state
      assert_equal 1, revision.calls.size, "the safe fix used the whole base budget"
      first, second = open_findings(gated.record).map { |entry| entry.fetch("fingerprint") }

      decide(task, gated.record, "approve_finding", first)
      waiting = advance.call
      assert_equal "awaiting_decision", waiting.record.state
      assert_equal 1, revision.calls.size

      decide(task, waiting.record, "approve_finding", second)
      cleared = advance.call
      assert_equal "cleared", cleared.record.state,
                   "the second decision must not hit revision_round_limit"
      assert_equal 2, revision.calls.size
      assert_equal [ first, second ].sort, revision.calls.last[:findings].map(&:fingerprint).sort
      assert_equal standard_plan.sub("# Plan", "# Revised twice"), File.read(File.join(task.folder, "plan.md"))
    end
  end

  # The verification follow-up is the second place a round can start. A new
  # gate raised next to a reopened safe residual parks the review; the
  # approval then revises both in one round from the latest candidate.
  def test_verification_followup_holds_accepted_residuals_behind_a_new_gate
    revised_once = standard_plan.sub("# Plan", "# Revised once")
    revised_twice = standard_plan.sub("# Plan", "# Revised twice")
    with_task(standard_plan) do |task, cfg|
      residual = finding("safe_auto", "Clarify tests")
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        findings = case request.kind
        when "primary" then [ residual ]
        when "verification"
          (verification_calls += 1) == 1 ? [ residual, finding("gated_auto", "New regression", line: 2) ] : []
        else []
        end
        successful_result(request, findings:)
      end
      revision = SequencedRevision.new(revised_once, revised_twice)
      advance = -> { orchestrator(task, cfg, adapter:, planner_revision: revision).advance! }

      parked = advance.call
      assert_equal "awaiting_decision", parked.record.state
      assert_equal 1, revision.calls.size
      safe = open_finding(parked.record, "safe_auto").fetch("fingerprint")
      gate = open_finding(parked.record, "gated_auto").fetch("fingerprint")
      assert_equal "approve gated plan finding #{gate}", parked.record.required_action

      decide(task, parked.record, "approve_finding", gate)
      cleared = advance.call
      assert_equal "cleared", cleared.record.state
      assert_equal 2, revision.calls.size
      assert_equal revised_once, revision.calls.last.fetch(:plan_bytes)
      assert_equal [ safe, gate ].sort, revision.calls.last[:findings].map(&:fingerprint).sort
      assert_equal revised_twice, File.read(File.join(task.folder, "plan.md"))
    end
  end

  # Past the operator-decision round the fence still blocks at the follow-up,
  # even with a gate open, and names the replan command.
  def test_followup_at_the_ceiling_blocks_with_the_replan_command
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["max_revision_rounds"] = { "standard" => 1, "mandatory" => 1 }
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        findings = case request.kind
        when "primary" then [ finding("safe_auto", "Clarify tests") ]
        when "verification"
          case verification_calls += 1
          when 1 then [ finding("gated_auto", "Keep the v1 token format", line: 2) ]
          when 2 then [ finding("safe_auto", "Another edge", line: 3), finding("gated_auto", "Late gate", line: 4) ]
          else []
          end
        else []
        end
        successful_result(request, findings:)
      end
      revision = SequencedRevision.new(
        standard_plan.sub("# Plan", "# Revised once"), standard_plan.sub("# Plan", "# Revised twice")
      )
      advance = -> { orchestrator(task, cfg, adapter:, planner_revision: revision).advance! }

      gated = advance.call
      decide(task, gated.record, "approve_finding", open_finding(gated.record, "gated_auto").fetch("fingerprint"))
      capped = advance.call.record

      assert_equal "blocked", capped.state
      assert_equal 2, revision.calls.size
      assert_equal [ { "owner" => "planner", "reason" => "revision_round_limit" } ], capped["blockers"]
      assert_equal "start a new linked plan: hive run demo-task --project hivedev (operator decisions carry forward)",
                   capped.required_action
      calls = adapter.calls.size
      assert_equal capped.to_h, advance.call.record.to_h
      assert_equal calls, adapter.calls.size
      assert_equal 2, revision.calls.size
    end
  end

  def test_legacy_decisions_are_reassessed_and_routine_fixes_wait_for_real_choices
    with_task(standard_plan) do |task, cfg|
      correction = finding("gated_auto", "Add successful delivery test")
      duplicate = Hive::PlanReview::Finding.new(correction.to_h.except("fingerprint").merge("source" => "adversarial"))
      choice = finding("manual", "Choose refresh replay behavior", line: 2)
      initial = success_adapter(primary_findings: [ correction, duplicate, choice ])
      old = with_replaced_singleton_method(Hive::PlanReview::DecisionTriage, :pending, ->(*) { [] }) do
        orchestrator(task, cfg, adapter: initial).advance!
      end
      assert_equal "awaiting_decision", old.record.state
      original_attempts = old.record["attempt_ids"]
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised plan"))
      adapter = FakeAdapter.new do |request|
        result = successful_result(request)
        if request.kind == "decision_triage"
          rows = [
            { "sources" => [ correction.fingerprint, duplicate.fingerprint ], "classification" => "safe_auto",
              "title" => "Add success-path test", "disposition" => "Test the existing delivery requirement",
              "rationale" => "The contract already requires successful delivery", "boundary" => nil },
            { "sources" => [ choice.fingerprint ], "classification" => "manual", "title" => choice["title"],
              "disposition" => "Keep the replay choice unresolved", "rationale" => "The plan explicitly asks the operator",
              "boundary" => { "requirement" => "Replay behavior is unanswered", "change" => "Retries can revoke access",
                              "alternatives" => [ "Strict revocation", "Bounded grace" ] } }
          ]
          result = result.with(decision_assessments: rows)
        end
        result
      end
      repaired = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!
      assert_equal "awaiting_decision", repaired.record.state
      refute repaired.record.execution_allowed?
      assert_equal "current", Hive::PlanReview::TransitionGuard.freshness(
        task:, projection: repaired, config: cfg
      ).fetch("status")
      assert_equal %w[decision_triage], adapter.calls.map(&:kind)
      assert_empty revision.calls, "the routine fix waits for the open choice instead of spending a round"
      assert_equal standard_plan, File.read(File.join(task.folder, "plan.md")), "pending choices must prevent promotion"
      assert_equal original_attempts, repaired.record["attempt_ids"].take(original_attempts.size)
      assert_empty repaired.record["decisions"]
      assert_equal 1, repaired.summary.dig("finding_counts", "open_manual")
      assert_equal 0, repaired.summary.dig("finding_counts", "open_gated")
      assert_equal 0, repaired.summary.dig("finding_counts", "verified")
      assert_empty Hive::PlanReview::DecisionTriage.pending(repaired.record)
      reentered = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!
      assert_equal 1, adapter.calls.size, "settled triage must not run again on daemon re-entry"
      assert_empty revision.calls

      manual = open_finding(reentered.record, "manual")
      answered = decide(task, reentered.record, "answer_finding", manual.fetch("fingerprint"),
                        answer: "Bounded grace")
      cleared = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!
      assert_equal "cleared", cleared.record.state
      assert_equal %w[decision_triage verification], adapter.calls.map(&:kind)
      assert_equal 1, revision.calls.size
      assert_equal open_findings(repaired.record).map { |entry| entry.fetch("fingerprint") }.sort,
                   revision.calls.first[:findings].map(&:fingerprint).sort,
                   "one round integrates the answer together with the deferred routine fix"
      assert_empty revision.calls.first[:pending_findings]
      assert_equal 1, answered["decisions"].size
      assert_equal 2, cleared.summary.dig("finding_counts", "verified")
    end
  end

  def test_pending_choice_does_not_interrupt_verification_retry_after_revision
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 1
      initial_findings = [ finding("safe_auto", "Clarify tests"), finding("manual", "Choose replay", line: 2) ]
      adapter = FakeAdapter.new do |request|
        if request.kind == "verification"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "provider_limit")
        else
          successful_result(request, findings: request.kind == "primary" ? initial_findings : [])
        end
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised plan"))
      first = unbatched(orchestrator(task, cfg, adapter:, planner_revision: revision)).advance!
      assert_equal "retry_scheduled", first.record.state
      assert_equal 1, first.summary.dig("finding_counts", "incorporated")
      retry_at = Time.parse(first.record["retry_at"])
      held = orchestrator(task, cfg, adapter:, planner_revision: revision, clock: -> { retry_at - 1 }).advance!
      assert_equal "retry_scheduled", held.record.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }

      # Reproduce a record parked by the older build after the retry was saved.
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      parked = held.record.to_h.merge("state" => "awaiting_decision", "retry_at" => nil,
                                     "version" => held.record.version + 1)
      store.publish_current!(Hive::PlanReview::Record.new(parked), expected_version: held.record.version)

      recovered_adapter = success_adapter
      recovered = orchestrator(task, cfg, adapter: recovered_adapter, planner_revision: revision,
                               clock: -> { retry_at + 1 }).advance!
      assert_equal "awaiting_decision", recovered.record.state
      assert_equal [ "verification" ], recovered_adapter.calls.map(&:kind)
      assert_equal 1, revision.calls.size
      assert_equal 1, recovered.summary.dig("finding_counts", "verified")
      assert_equal 1, recovered.summary.dig("finding_counts", "open_manual")
      assert_empty recovered.record["decisions"]
      refute recovered.record.execution_allowed?
      assert_equal standard_plan, File.read(File.join(task.folder, "plan.md"))
    end
  end

  def test_degraded_coverage_does_not_clear_pending_choice_or_unverified_candidate
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 1
      initial_findings = [ finding("safe_auto", "Clarify tests"), finding("manual", "Choose replay", line: 2) ]
      adapter = FakeAdapter.new do |request|
        if request.kind == "adversarial"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "unsupported")
        elsif request.kind == "verification"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "provider_limit")
        else
          successful_result(request, findings: request.kind == "primary" ? initial_findings : [])
        end
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised plan"))
      first = unbatched(orchestrator(task, cfg, adapter:, planner_revision: revision)).advance!
      assert_equal "retry_scheduled", first.record.state
      assert_equal 1, first.summary.dig("finding_counts", "incorporated")
      retry_at = Time.parse(first.record["retry_at"])
      held = orchestrator(task, cfg, adapter:, planner_revision: revision, clock: -> { retry_at - 1 }).advance!
      assert_equal "retry_scheduled", held.record.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "verification" }

      # Reproduce a record parked by the older build after the retry was saved.
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      parked = held.record.to_h.merge("state" => "awaiting_decision", "retry_at" => nil,
                                     "version" => held.record.version + 1)
      store.publish_current!(Hive::PlanReview::Record.new(parked), expected_version: held.record.version)

      recovered_adapter = success_adapter
      recovered = orchestrator(task, cfg, adapter: recovered_adapter, planner_revision: revision,
                               clock: -> { retry_at + 1 }).advance!
      assert_equal "awaiting_decision", recovered.record.state
      assert_equal [ "verification" ], recovered_adapter.calls.map(&:kind)
      assert_equal 1, revision.calls.size
      assert_equal 1, recovered.summary.dig("finding_counts", "verified")
      assert_equal 1, recovered.summary.dig("finding_counts", "open_manual")
      assert_empty recovered.record["decisions"]
      refute recovered.record.execution_allowed?
      assert_equal standard_plan, File.read(File.join(task.folder, "plan.md"))
    end
  end

  # A provider quota wall never exhausts the transient budget: even with
  # max_transient=0 the leg stays retry_scheduled on the hourly cadence.
  def test_provider_limit_never_exhausts_the_transient_budget
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "verification"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "provider_limit")
        else
          successful_result(request, findings: request.kind == "primary" ?
            [ finding("safe_auto", "Clarify tests"), finding("manual", "Choose replay", line: 2) ] : [])
        end
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised"))
      now = Time.utc(2026, 8, 12, 12)
      3.times do |hour|
        clock = now + (hour * 3600)
        runner = orchestrator(task, cfg, adapter:, planner_revision: revision, clock: -> { clock })
        # The candidate was revised mid-decision by an older build; the
        # current build keeps verifying it hourly while the choice is open.
        runner = unbatched(runner) if hour.zero?
        projection = runner.advance!
        assert_equal "retry_scheduled", projection.record.state
        assert_equal (clock + 3600).utc.iso8601(6), projection.record["retry_at"]
        refute projection.record.execution_allowed?
      end
      assert_equal 3, adapter.calls.count { |request| request.kind == "verification" }
      assert_equal 1, revision.calls.size
    end
  end

  def test_pending_choice_does_not_hide_exhausted_verification
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "verification"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "timeout")
        else
          successful_result(request, findings: request.kind == "primary" ?
            [ finding("safe_auto", "Clarify tests"), finding("manual", "Choose replay", line: 2) ] : [])
        end
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised"))
      blocked = unbatched(orchestrator(task, cfg, adapter:, planner_revision: revision)).advance!
      assert_equal "blocked", blocked.record.state
      assert_equal 1, blocked.summary.dig("finding_counts", "open_manual")
      assert blocked.record["blockers"].any? { |entry| entry["reason"] == "candidate_verification_timeout" }
      refute blocked.record.execution_allowed?
      calls = adapter.calls.size
      assert_equal "blocked", orchestrator(task, cfg, adapter:, planner_revision: revision).advance!.record.state
      assert_equal calls, adapter.calls.size
    end
  end

  def test_verifier_conflict_reconciles_automatic_disposition_without_answering_manual_choice
    with_task(standard_plan) do |task, cfg|
      automatic = finding("safe_auto", "Default to strict revocation")
      gate = finding("manual", "Choose replay policy", line: 2)
      conflict = finding("manual", "Automatic default contradicts unanswered policy", line: 3)
      triage_calls = 0
      adapter = FakeAdapter.new do |request|
        result = successful_result(request, findings: request.kind == "primary" ? [ automatic, gate ] : [])
        if request.kind == "decision_triage" && (triage_calls += 1) > 1
          result = result.with(decision_assessments: [ {
            "sources" => request.pending_findings.map { |entry| entry.fetch("fingerprint") },
            "classification" => "manual", "title" => "Choose replay policy",
            "disposition" => "Preserve the unresolved policy; retire the contradictory default instruction",
            "rationale" => "The plan explicitly reserves the policy choice",
            "boundary" => { "requirement" => "Replay behavior remains unanswered", "change" => "Revocation semantics",
                            "alternatives" => [ "Strict revocation", "Bounded grace" ] }
          } ])
        elsif request.kind == "verification"
          result = successful_result(request, findings: [ conflict ]).with(residual_evidence: [])
        end
        result
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised"))
      result = unbatched(orchestrator(task, cfg, adapter:, planner_revision: revision)).advance!
      assert_equal 1, revision.calls.size
      assert_equal "awaiting_decision", result.record.state
      assert_equal 1, result.summary.dig("finding_counts", "open_manual")
      assert_equal 0, result.summary.dig("finding_counts", "incorporated")
      assert_equal [ "manual_answer_required" ], result.record["blockers"].map { |entry| entry["reason"] }
      assert_empty result.record["decisions"]
      refute result.record.execution_allowed?
      assert_equal standard_plan, File.read(File.join(task.folder, "plan.md"))
      calls = adapter.calls.size
      orchestrator(task, cfg, adapter:, planner_revision: revision).advance!
      assert_equal calls, adapter.calls.size
    end
  end

  def test_decision_triage_provider_outage_retries_without_approving_or_dropping_findings
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      adapter = FakeAdapter.new do |request|
        if request.kind == "decision_triage"
          Hive::PlanReview::Adapters::Base::Result.new(outcome: "provider_limit")
        else
          successful_result(request, findings: request.kind == "primary" ? [ finding("manual", "Choose replay") ] : [])
        end
      end
      first = orchestrator(task, cfg, adapter:).advance!
      assert_equal "retry_scheduled", first.record.state
      assert_equal 1, first.summary.dig("finding_counts", "open_manual")
      assert_empty first.record["decisions"]
      assert first.record["retry_at"]
      adapter = success_adapter
      recovered = orchestrator(task, cfg, adapter:, clock: -> { Time.parse(first.record["retry_at"]) + 1 }).advance!
      assert_equal "awaiting_decision", recovered.record.state
      assert_equal [ "decision_triage" ], adapter.calls.map(&:kind)
      assert_equal 1, recovered.summary.dig("finding_counts", "open_manual")
      assert_empty recovered.record["decisions"]
    end
  end

  def test_decision_triage_uses_its_own_route_only_when_one_is_configured
    [ false, true ].each do |configured|
      with_task(standard_plan) do |task, cfg|
        cfg["plan_review"]["attempts"]["max_transient"] = 0
        if configured
          cfg["plan_review"]["routes"]["decision_triage"] = {
            "agent" => "claude", "model" => "claude-sonnet-5-5", "family" => "anthropic",
            "effort" => "low", "route" => "claude-code/v1"
          }
        end
        roles = []
        resolver = lambda do |role:, **options|
          roles << role
          resolve_route(role:, **options)
        end
        adapter = FakeAdapter.new do |request|
          if request.kind == "decision_triage"
            Hive::PlanReview::Adapters::Base::Result.new(outcome: "provider_limit")
          else
            successful_result(request, findings: request.kind == "primary" ? [ finding("manual", "Choose replay") ] : [])
          end
        end

        orchestrator(task, cfg, adapter:, route_resolver: resolver).advance!

        assert_includes adapter.calls.map(&:kind), "decision_triage"
        assert_equal configured, roles.include?("decision_triage"), "configured=#{configured}: #{roles.inspect}"
      end
    end
  end

  def test_malformed_triage_output_stops_after_the_bounded_attempts_with_original_findings_intact
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["attempts"]["max_transient"] = 0
      original = finding("manual", "Choose replay")
      adapter = FakeAdapter.new do |request|
        if request.kind == "decision_triage"
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "retryable_failure", diagnostic: "invalid decision triage disposition",
            route_receipt: { "diagnostic_source" => "parser" })
        else
          successful_result(request, findings: request.kind == "primary" ? [ original ] : [])
        end
      end
      runner = orchestrator(task, cfg, adapter:)
      result = runner.advance!
      assert_equal "blocked", result.record.state
      assert_equal "terminal_failure", result.record["routes"].last["outcome"]
      assert_equal [ original.to_h ], result.record["findings"]
      assert_empty result.record["decisions"]
      runner.advance!
      assert_equal 1, adapter.calls.count { |request| request.kind == "decision_triage" }
    end
  end

  def test_decision_after_a_triage_crash_invalidates_the_saved_source_set_without_erasing_authority
    with_task(standard_plan) do |task, cfg|
      approved = finding("gated_auto", "Compatibility decision")
      pending = finding("manual", "Replay decision", line: 2)
      adapter = success_adapter(primary_findings: [ approved, pending ])
      assert_raises(IOError) do
        with_replaced_singleton_method(Hive::PlanReview::DecisionTriage, :apply, ->(*, **) { raise IOError, "crash" }) do
          orchestrator(task, cfg, adapter:).advance!
        end
      end
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      record = store.current_validated
      service = Hive::PlanReview::DecisionService.new(
        task:, task_locker: ->(&block) { block.call }, commit_locker: ->(&block) { block.call },
        committer: ->(*) { }, freshness_checker: ->(*) { }
      )
      service.apply(action: "approve_finding", review_id: record.review_id,
                    task_generation: record.task_generation, policy_fingerprint: record.policy_fingerprint,
                    expected_artifact_digest: Hive::PlanReview::Projection.new(record).observation_digest,
                    target_fingerprint: approved.fingerprint, origin: "cli", operator: "test", authorized: true)
      revision = FakeRevision.new(standard_plan)
      result = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!
      assert_equal "awaiting_decision", result.record.state
      assert_equal 2, adapter.calls.count { |request| request.kind == "decision_triage" }
      assert_equal [ pending.fingerprint ], adapter.calls.select { |request| request.kind == "decision_triage" }.last.pending_findings.map { |f| f.fetch("fingerprint") }
      assert_equal 1, result.record["decisions"].size
      assert_equal approved.fingerprint, result.record["decisions"].first["target_fingerprint"]
      assert_equal "approved", result.record["findings"].find { |f| f["fingerprint"] == approved.fingerprint }["lifecycle"]
      assert_empty revision.calls, "the approval waits for the open manual choice"
    end
  end

  def test_completed_triage_result_is_replayed_after_crash_before_application
    with_task(standard_plan) do |task, cfg|
      adapter = success_adapter(primary_findings: [ finding("manual", "Choose replay") ])
      assert_raises(IOError) do
        with_replaced_singleton_method(Hive::PlanReview::DecisionTriage, :apply, ->(*, **) { raise IOError, "crash" }) do
          orchestrator(task, cfg, adapter:).advance!
        end
      end
      recovered = orchestrator(task, cfg, adapter:).advance!
      assert_equal "awaiting_decision", recovered.record.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "decision_triage" }
      assert_empty recovered.record["decisions"]
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

  def test_approval_policy_cannot_skip_duplicate_decision_reassessment
    with_task(standard_plan) do |task, cfg|
      cfg["plan_review"]["approval_policies"] = [ {
        "id" => "routine", "version" => 1, "action" => "approve_finding", "risk" => "low",
        "paths" => [ "plan.md" ], "valid_from" => "2026-08-12T00:00:00Z",
        "valid_until" => "2026-08-13T00:00:00Z", "revoked" => false
      } ]
      first = finding("gated_auto", "Add successful delivery test")
      second = Hive::PlanReview::Finding.new(first.to_h.except("fingerprint").merge("source" => "adversarial"))
      adapter = FakeAdapter.new do |request|
        result = successful_result(request, findings: request.kind == "primary" ? [ first, second ] : [])
        if request.kind == "decision_triage"
          result = result.with(decision_assessments: [ {
            "sources" => request.pending_findings.map { |f| f.fetch("fingerprint") },
            "classification" => "safe_auto", "title" => "Test successful delivery",
            "disposition" => "Add the acceptance test", "rationale" => "Already required by the contract",
            "boundary" => nil
          } ])
        end
        result
      end
      revision = FakeRevision.new(standard_plan)
      result = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!
      assert_equal "cleared", result.record.state
      assert_equal 1, adapter.calls.count { |request| request.kind == "decision_triage" }
      assert_equal 1, revision.calls.first[:findings].size
      assert_empty result.record["decisions"], "routine correction must not acquire unnecessary policy approvals"
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

  # A waiver of the adversarial coverage, or a downgrade below
  # adversarial_min_level, ends the wait for an unavailable adversarial family.
  %w[waive_coverage downgrade_level].each do |action|
    define_method("test_#{action}_ends_the_wait_for_an_unavailable_adversarial_family") do
      with_task(mandatory_plan) do |task, cfg|
        # The shipped default: the adversarial lens applies only at mandatory.
        cfg["plan_review"]["adversarial_min_level"] = "mandatory"
        resolver = lambda do |role:, **|
          next resolve_route(role:) unless role == "adversarial"

          requested = route_identity("grok", "grok-4.6", "grok", "native_adversarial")
          Hive::PlanReview::RouteResolver::Resolution.new(
            status: "unsupported", candidate: nil,
            receipt: {
              "role" => role, "requested" => requested, "actual" => {},
              "capability_result" => "unsupported", "independence_verified" => false,
              "independence_reason" => "reviewer_family_unavailable",
              "attempts" => [ { "candidate" => requested, "status" => "unsupported" } ]
            }
          )
        end
        adapter = success_adapter
        waiting = orchestrator(task, cfg, adapter:, route_resolver: resolver).advance!.record
        assert_equal "reviewing", waiting.state

        coverage = waiting["coverage"].find { |entry| entry.fetch("name") == "adversarial" }
        service = Hive::PlanReview::DecisionService.new(
          task:, task_locker: ->(&block) { block.call }, commit_locker: ->(&block) { block.call },
          committer: ->(*) { }, freshness_checker: ->(*) { }
        )
        value, target = if action == "waive_coverage"
          fingerprint = coverage["fingerprint"] || Hive::PlanReview::Identity.coverage(
            review_id: waiving_id = waiting.review_id, name: "adversarial",
            policy_fingerprint: waiting.policy_fingerprint
          )
          [ { "coverage" => "adversarial" }, fingerprint ]
        else
          [ { "level" => "standard" }, nil ]
        end
        service.apply(
          action:, review_id: waiting.review_id, task_generation: waiting.task_generation,
          policy_fingerprint: waiting.policy_fingerprint,
          expected_artifact_digest: Hive::PlanReview::Projection.new(waiting).observation_digest,
          target_fingerprint: target, value:, reason: "No adversarial family in this install.",
          origin: "cli", operator: "test", authorized: true
        )

        resumed = orchestrator(task, cfg, adapter:, route_resolver: resolver).advance!.record

        refute_includes %w[reviewing retry_scheduled], resumed.state, resumed.required_action
        assert_equal 0, adapter.calls.count { |request| request.kind == "adversarial" }
      end
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

  def test_reclassified_verifier_gates_cannot_clear_an_exhausted_revision_budget
    with_task(standard_plan) do |task, cfg|
      verification_calls = 0
      adapter = FakeAdapter.new do |request|
        result = successful_result(request, findings: request.kind == "primary" ?
          [ finding("safe_auto", "Clarify tests") ] : [])
        if request.kind == "verification"
          verification_calls += 1
          result = successful_result(request, findings: [ finding("manual", "Routine correction", line: verification_calls + 1) ])
        elsif request.kind == "decision_triage"
          result = result.with(decision_assessments: request.pending_findings.map { |entry|
            { "sources" => [ entry.fetch("fingerprint") ], "classification" => "safe_auto",
              "title" => "Implement the existing requirement", "disposition" => "Correct the test instructions",
              "rationale" => "No product choice is needed", "boundary" => nil }
          })
        end
        result
      end
      revision = FakeRevision.new(standard_plan.sub("# Plan", "# Revised"))
      runner = orchestrator(task, cfg, adapter:, planner_revision: revision)
      2.times { assert_equal "revising", runner.advance!.record.state }
      capped = runner.advance!.record
      assert_equal "blocked", capped.state
      refute capped.execution_allowed?
      assert_equal 3, revision.calls.size
      assert_equal standard_plan, File.read(File.join(task.folder, "plan.md"))
      calls = adapter.calls.size
      assert_equal capped.to_h, runner.advance!.record.to_h
      assert_equal calls, adapter.calls.size
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

      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      legacy = Hive::PlanReview::Record.new(replay.to_h.merge(
        "version" => replay.version + 1, "state" => "awaiting_decision", "outcome" => nil
      ))
      store.publish_current!(legacy, expected_version: replay.version)
      recovered = runner.advance!.record
      assert_equal "blocked", recovered.state
      assert_equal "revision_round_limit", recovered["blockers"].first.fetch("reason")
      assert_equal Hive::PlanReview::Orchestrator::MAX_VERIFICATION_REVISION_ROUNDS,
                   revision.calls.length
    end
  end

  # Safe fixes can spend the whole revision budget before an operator decides a
  # gated or manual finding. Those late decisions earn exactly one integration
  # round past the cap; safe-only residue does not, and the ceiling is fixed.
  def test_operator_decisions_earn_one_integration_round_past_the_cap
    with_task(standard_plan) do |task, cfg|
      runner = orchestrator(task, cfg, adapter: FakeAdapter.new { |request| successful_result(request) })
      max = Hive::PlanReview::Orchestrator::MAX_VERIFICATION_REVISION_ROUNDS
      extra = Hive::PlanReview::Orchestrator::OPERATOR_DECISION_ROUNDS
      outcome = Hive::PlanReview::Orchestrator::SUCCESS_OUTCOMES.first
      record = lambda do |rounds|
        { "routes" => Array.new(rounds) { { "role" => "planner_revision", "outcome" => outcome } } }
      end
      decided = ->(classification, lifecycle) do
        Hive::PlanReview::Finding.new(finding(classification, "Decided").to_h.merge("lifecycle" => lifecycle))
      end
      safe = [ finding("safe_auto", "Safe residue") ]
      approved = [ decided.call("gated_auto", "approved") ]
      answered = [ decided.call("manual", "answered") ]

      refute runner.send(:revision_round_limit_reached?, record.call(max - 1), safe)
      assert runner.send(:revision_round_limit_reached?, record.call(max), safe)
      refute runner.send(:revision_round_limit_reached?, record.call(max), approved)
      refute runner.send(:revision_round_limit_reached?, record.call(max), answered)
      assert runner.send(:revision_round_limit_reached?, record.call(max + extra), approved),
             "the integration round is bounded"

      # An open gate holds the round until the operator decides it, so safe
      # residue accepted meanwhile waits for that round instead of blocking
      # at the base cap. The ceiling still holds.
      open_gate = [ finding("gated_auto", "Undecided") ]
      refute runner.send(:revision_round_limit_reached?, record.call(max), safe, pending: open_gate)
      assert runner.send(:revision_round_limit_reached?, record.call(max + extra), safe, pending: open_gate)
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
    gated = finding("gated_auto", "Undecided residual", line: 5)
    reopened = [ safe, manual, fyi, gated ].map do |finding|
      runner.send(:reopen_verification_finding, finding, finding)
    end
    assert_equal %w[open open open open], reopened.map { |finding| finding.fetch("lifecycle") }

    declined = Hive::PlanReview::Finding.new(existing.to_h.merge(
      "lifecycle" => "incorporated", "decision_id" => "prd-#{'b' * 64}",
      "answer" => "Decline; keep the hold."
    ))
    reopened = runner.send(:reopen_verification_finding, declined, existing)
    assert_equal "answered", reopened.fetch("lifecycle")
    assert_equal "Decline; keep the hold.", reopened.fetch("answer")
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
        elsif request.kind == "decision_triage"
          successful_result(request)
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
      assert_equal "verified", projection.record["findings"].last.fetch("lifecycle")
      assert_equal revised, File.binread(File.join(task.folder, "plan.md"))
    end
  end

  def test_verification_provider_limit_waits_then_retries_within_the_same_bound
    revised = standard_plan.sub("# Plan", "# Revised plan")
    with_task(standard_plan) do |task, cfg|
      finding = finding("safe_auto", "Clarify tests")
      verification_calls = 0
      # The provider announces a reset days away; Hive retries hourly anyway.
      provider_reset = "2026-08-19T00:00:00Z"
      retry_at = "2026-08-12T13:00:00.000000Z"
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          successful_result(request, findings: [ finding ])
        elsif request.kind == "verification" && (verification_calls += 1) == 1
          Hive::PlanReview::Adapters::Base::Result.new(
            outcome: "provider_limit", retry_at: provider_reset
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

  def test_metered_review_usage_survives_publication_on_the_original_attempt
    usage = { "input" => 120, "output" => 45, "reasoning" => 20, "cache_read" => 0 }
    with_task(mandatory_plan) do |task, cfg|
      adapter = FakeAdapter.new do |request|
        result = successful_result(request)
        result.with(route_receipt: result.route_receipt.merge("usage" => usage))
      end
      record = orchestrator(task, cfg, adapter:).advance!.record
      store = Hive::PlanReview::Store.new(task_folder: task.folder)
      receipt = JSON.parse(store.read_reference(record["artifacts"].fetch("adversarial_route")))
      assert_equal usage, receipt["usage"]
      assert_equal receipt, record["routes"].find { |r| r["attempt_id"] == receipt["attempt_id"] }
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

  # A resolved review keeps its verdict when only reviewer routing moves, both
  # when the reviewed plan is the original (identity path) and when a revised
  # candidate was promoted (candidate path); a verdict-relevant change still
  # starts a linked review.
  def test_reviewer_reroute_keeps_a_cleared_review_but_a_level_raise_rekeys_it
    revised = standard_plan.sub("# Plan", "# Revised plan")
    [ [], [ finding("safe_auto", "Clarify tests") ] ].each do |findings|
      with_task(standard_plan) do |task, cfg|
        adapter = success_adapter(primary_findings: findings)
        revision = FakeRevision.new(revised)
        first = orchestrator(task, cfg, adapter:, planner_revision: revision).advance!.record
        assert_equal "cleared", first.state
        calls = adapter.calls.length

        rerouted = reroute(cfg)
        kept = orchestrator(task, rerouted, adapter:, planner_revision: revision).advance!.record
        assert_equal [ first.review_id, first.version, "cleared" ], [ kept.review_id, kept.version, kept.state ]
        assert_equal calls, adapter.calls.length, "a kept verdict must not call a reviewer"

        rerouted["plan_review"]["minimum_level"] = "mandatory"
        raised = orchestrator(task, rerouted, adapter:, planner_revision: revision).advance!.record
        refute_equal first.review_id, raised.review_id
        assert_equal first.review_id, raised.prior_review_id
        assert_equal "mandatory", raised.effective_level
      end
    end
  end

  # An unresolved review is still waiting on its reviewers: a reroute (here
  # the fix for an unlaunchable reviewer) starts a linked review on the new
  # route instead of replaying the old one.
  def test_reviewer_reroute_rekeys_an_unresolved_review
    with_task(mandatory_plan) do |task, cfg|
      unavailable = FakeAdapter.new(capability: ->(**) { { "status" => "unsupported" } }) do
        Hive::PlanReview::Adapters::Base::Result.new(
          outcome: "unsupported", diagnostic: "missing reviewer",
          route_receipt: { "capability_result" => "unsupported" }
        )
      end
      waiting = orchestrator(task, cfg, adapter: unavailable).advance!.record
      refute waiting.execution_allowed?

      rerouted = orchestrator(task, reroute(cfg), adapter: success_adapter).advance!.record

      refute_equal waiting.review_id, rerouted.review_id
      assert_equal waiting.review_id, rerouted.prior_review_id
      assert_equal "cleared", rerouted.state
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

  def test_concurrent_entries_serialize_through_lifecycle_custody
    with_task(standard_plan) do |task, cfg|
      entered = Queue.new
      release = Queue.new
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          entered << true
          release.pop
        end
        successful_result(request)
      end
      first = Thread.new do
        orchestrator(task, cfg, adapter:).advance!
      end
      entered.pop

      assert_raises(Hive::ConcurrentRunError) do
        orchestrator(task, cfg, adapter:).advance!
      end

      release << true
      first_projection = first.value
      retried_projection = orchestrator(task, cfg, adapter: success_adapter).advance!

      assert_equal first_projection.record.review_id, retried_projection.record.review_id
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
      assert_equal "retry_scheduled", runner.advance!.record.state
      assert_equal "retry_scheduled", runner.advance!.record.state
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
      assert record.execution_allowed?
      moved_policy = Struct.new(:policy_fingerprint).new("0" * 64)
      refute runner.send(:policy_identity_current?, no_policy, moved_policy, nil)
      refute runner.send(:policy_identity_current?, invalid_policy, moved_policy, nil)
      list_policy = store.write_review_artifact!(
        review_id: record.review_id, basename: "list-policy.json", content: "[]"
      )
      refute runner.send(
        :policy_identity_current?,
        Hive::PlanReview::Record.new(
          record.to_h.merge("artifacts" => record["artifacts"].merge("policy" => list_policy))
        ),
        moved_policy, nil
      )
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
        runner.advance!
      end
      assert_includes error.message, "metadata is invalid"
    end
  end

  def test_advance_rejects_a_task_missing_before_observation
    with_task(standard_plan) do |task, cfg|
      FileUtils.rm_rf(task.folder)

      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        orchestrator(task, cfg, adapter: success_adapter).advance!
      end

      assert_includes error.message, "stale or missing"
    end
  end

  def test_advance_translates_stale_observation_errors
    with_task(standard_plan) do |task, cfg|
      observation = Hive::TaskMeta.observe(task.folder)
      FileUtils.rm_rf(task.folder)
      runner = orchestrator(
        task, cfg, adapter: success_adapter, task_observation: observation
      )

      error = assert_raises(Hive::PlanReview::InvalidRecord) { runner.advance! }

      assert_includes error.message, "plan review task is stale"
    ensure
      observation&.close
    end
  end

  def test_review_requirement_rejects_a_same_path_replacement_even_when_already_true
    with_task(standard_plan) do |task, cfg|
      Hive::TaskMeta.rewrite(task.folder, plan_review_required: true)
      copied = Dir.children(task.folder).to_h do |name|
        path = File.join(task.folder, name)
        [ name, File.file?(path) ? File.binread(path) : nil ]
      end
      observation = Hive::TaskMeta.observe(task.folder)
      FileUtils.rm_rf(task.folder)
      FileUtils.mkdir_p(task.folder)
      copied.each do |name, bytes|
        File.binwrite(File.join(task.folder, name), bytes) if bytes
      end
      runner = orchestrator(
        task, cfg, adapter: success_adapter, task_observation: observation
      )

      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        runner.send(:ensure_review_requirement!)
      end

      assert_includes error.message, "stale task"
      assert_equal true, Hive::TaskMeta.read(task.folder)[:plan_review_required]
    ensure
      observation&.close
    end
  end

  def test_review_requirement_rejects_a_task_deleted_before_update_custody
    with_task(standard_plan) do |task, cfg|
      observation = Hive::TaskMeta.observe(task.folder)
      FileUtils.rm_rf(task.folder)
      runner = orchestrator(
        task, cfg, adapter: success_adapter, task_observation: observation
      )

      error = assert_raises(Hive::PlanReview::InvalidRecord) do
        runner.send(:ensure_review_requirement!)
      end

      assert_includes error.message, "stale task"
      refute File.exist?(task.folder)
    ensure
      observation&.close
    end
  end

  def test_review_requirement_rejects_deletion_after_metadata_read
    with_task(standard_plan) do |task, cfg|
      observation = Hive::TaskMeta.observe(task.folder)
      runner = orchestrator(
        task, cfg, adapter: success_adapter, task_observation: observation
      )
      boundary_reached = false
      original = Hive::TaskMeta.method(:read_for_update!)
      delete_after_read = lambda do |folder|
        result = original.call(folder)
        boundary_reached = true
        FileUtils.rm_rf(folder)
        result
      end

      error = with_replaced_singleton_method(
        Hive::TaskMeta, :read_for_update!, delete_after_read
      ) do
        with_runner_custody(runner, task, observation: observation) do
          assert_raises(Hive::PlanReview::InvalidRecord) do
            runner.send(:ensure_review_requirement!)
          end
        end
      end

      assert boundary_reached, "metadata-read boundary must be exercised"
      assert_includes error.message, "stale task"
      refute File.exist?(task.folder)
    ensure
      observation&.close
    end
  end

  def test_stale_review_requirement_rewrite_fails_closed
    with_task(standard_plan) do |task, cfg|
      runner = orchestrator(task, cfg, adapter: success_adapter)
      stale = ->(*, **) { Hive::TaskMeta::UpdateResult.new(status: :stale, value: nil) }

      error = with_replaced_singleton_method(Hive::TaskMeta, :rewrite, stale) do
        with_runner_custody(runner, task) do
          assert_raises(Hive::PlanReview::InvalidRecord) do
            runner.send(:ensure_review_requirement!)
          end
        end
      end

      assert_includes error.message, "stale task"
      refute Hive::TaskMeta.plan_review_required?(task.folder)
    end
  end

  def test_advance_claims_the_observed_lease_under_project_commit_custody
    with_task(standard_plan) do |task, cfg|
      claims = []
      claim = lambda do |folder, *, **kwargs|
        claims << [ folder, kwargs ]
        raise Hive::ConcurrentRunError.new("stop after the claim")
      end

      with_replaced_singleton_method(Hive::Lock, :with_task_lock, claim) do
        assert_raises(Hive::ConcurrentRunError) do
          orchestrator(task, cfg, adapter: success_adapter).advance!
        end
      end

      folder, kwargs = claims.fetch(0)
      assert_equal task.folder, folder
      assert_equal File.dirname(File.dirname(File.dirname(task.folder))),
                   kwargs.fetch(:acquire_under_commit_lock)
      assert_equal false, kwargs.fetch(:create)
      assert_kind_of Hive::TaskMeta::Observation, kwargs.fetch(:observation)
    end
  end

  def test_review_requirement_refuses_mutation_without_lifecycle_custody
    with_task(standard_plan) do |task, cfg|
      observation = Hive::TaskMeta.observe(task.folder)
      runner = orchestrator(
        task, cfg, adapter: success_adapter, task_observation: observation
      )

      error = assert_raises(Hive::ConcurrentRunError) do
        runner.send(:ensure_review_requirement!)
      end

      assert_includes error.message, "requires lifecycle custody"
      refute Hive::TaskMeta.plan_review_required?(task.folder)
    ensure
      observation&.close
    end
  end

  def test_review_requirement_reports_invalid_metadata_under_custody
    with_task(standard_plan) do |task, cfg|
      runner = orchestrator(task, cfg, adapter: success_adapter)
      invalid = ->(*) { raise Hive::TaskMeta::InvalidMetadata, "corrupt" }

      error = with_runner_custody(runner, task) do
        with_replaced_singleton_method(Hive::TaskMeta, :plan_review_required?, invalid) do
          assert_raises(Hive::PlanReview::InvalidRecord) do
            runner.send(:ensure_review_requirement!)
          end
        end
      end

      assert_includes error.message, "could not be persisted: corrupt"
    end
  end

  # hivedev F4: a reviewer whose output the parser refuses the same way every
  # time used to retry forever (mandatory initial legs recover their transient
  # series automatically) with nothing kept to diagnose it.
  def test_identical_parser_rejections_stop_retrying_and_name_the_kept_output
    with_task(mandatory_plan) do |task, cfg|
      now = Time.utc(2026, 8, 12, 12)
      clock = -> { now }
      diagnostic = "invalid plan review coverage entry 0: unknown keys notes"
      adapter = FakeAdapter.new do |request|
        if request.kind == "primary"
          rejected_result(diagnostic, "{\"coverage\":[{\"notes\":\"x\"}]}")
        else
          successful_result(request)
        end
      end

      states = 3.times.map do
        now += 3600
        orchestrator(task, cfg, adapter:, clock:).advance!.record.state
      end

      assert_equal %w[retry_scheduled retry_scheduled blocked], states
      record = Hive::PlanReview::Store.new(task_folder: task.folder).current_validated
      blocker = record["blockers"].first
      assert_equal "reviewer_output_rejected", blocker.fetch("reason")
      assert_equal "operator", blocker.fetch("owner")
      assert_includes blocker.fetch("diagnostic"), "primary output was rejected 3 times in a row: #{diagnostic}"
      latest = record["routes"].reverse.find { |route| route["role"] == "primary" }.fetch("attempt_id")
      reference = record["artifacts"].fetch("primary_rejected_output_#{latest}")
      assert_includes blocker.fetch("diagnostic"), "raw output: plan-review/#{reference.fetch('path')}"
      assert_includes File.read(File.join(task.folder, "plan-review", reference.fetch("path"))), "notes"
      assert_match(/repair the primary reviewer output contract/, record.required_action)

      now += 86_400
      replay = orchestrator(task, cfg, adapter:, clock:).advance!.record
      assert_equal 3, adapter.calls.count { |request| request.kind == "primary" }, "no further paid attempt"
      assert_equal record.version, replay.version, "an unchanged block is not republished"

      # An operator retry is a plain reset: it starts a fresh rejection run.
      service = Hive::PlanReview::DecisionService.new(
        task:, task_locker: ->(&block) { block.call }, commit_locker: ->(&block) { block.call },
        committer: ->(*) { }, freshness_checker: ->(*) { }
      )
      service.apply(action: "retry", review_id: record.review_id, task_generation: record.task_generation,
                    policy_fingerprint: record.policy_fingerprint,
                    expected_artifact_digest: Hive::PlanReview::Projection.new(record).observation_digest,
                    origin: "cli", operator: "test", authorized: true)
      resumed = orchestrator(task, cfg, adapter:, clock:).advance!.record
      assert_equal 4, adapter.calls.count { |request| request.kind == "primary" }
      assert_equal "retry_scheduled", resumed.state
    end
  end

  def test_different_parser_rejections_do_not_trip_the_identical_rejection_limit
    with_task(mandatory_plan) do |task, cfg|
      now = Time.utc(2026, 8, 12, 12)
      count = 0
      adapter = FakeAdapter.new do |request|
        next successful_result(request) unless request.kind == "primary"

        count += 1
        rejected_result("invalid plan review coverage entry #{count}: unknown keys notes", nil)
      end

      3.times do
        now += 3600
        orchestrator(task, cfg, adapter:, clock: -> { now }).advance!
      end

      record = Hive::PlanReview::Store.new(task_folder: task.folder).current_validated
      assert_equal 3, count
      refute_equal "blocked", record.state
      refute record["artifacts"].keys.any? { |key| key.include?("rejected_output") }
    end
  end

  # An operator restart of a review that went stale only through policy
  # configuration drift must still supersede it; resuming the same record
  # would leave it stale and every action rejected.
  def test_restart_decision_supersedes_the_review_even_when_its_identity_still_matches
    with_task(standard_plan) do |task, cfg|
      first = orchestrator(task, cfg, adapter: success_adapter).advance!.record
      service = Hive::PlanReview::DecisionService.new(
        task:, task_locker: ->(&block) { block.call }, commit_locker: ->(&block) { block.call },
        committer: ->(*) { }, freshness_reader: ->(*) { { "status" => "stale", "reason" => "policy drift" } }
      )
      result = service.apply(
        action: "restart", review_id: first.review_id, task_generation: first.task_generation,
        policy_fingerprint: first.policy_fingerprint,
        expected_artifact_digest: Hive::PlanReview::Projection.new(first).observation_digest,
        origin: "cli", operator: "test", authorized: true
      )
      assert_equal "restart-#{first.review_id}", result.decision.target_fingerprint

      second = orchestrator(task, cfg, adapter: success_adapter).advance!.record

      refute_equal first.review_id, second.review_id
      assert_equal first.review_id, second.prior_review_id
      assert_empty second["decisions"]
      assert_equal "cleared", second.state
    end
  end

  private

  # Older builds launched a planner revision for accepted findings while a
  # gated or manual finding was still open. Hiding open choices from one
  # runner's batching guard reproduces the records they left behind.
  def unbatched(runner)
    runner.define_singleton_method(:pending_decision_findings) { |_record| [] }
    runner
  end

  # Applies an operator approval or answer the way `hive plan-review` does
  # and returns the resulting record.
  def decide(task, record, action, fingerprint, answer: nil)
    service = Hive::PlanReview::DecisionService.new(
      task:, task_locker: ->(&block) { block.call }, commit_locker: ->(&block) { block.call },
      committer: ->(*) { }, freshness_checker: ->(*) { }
    )
    service.apply(
      action:, review_id: record.review_id, task_generation: record.task_generation,
      policy_fingerprint: record.policy_fingerprint,
      expected_artifact_digest: Hive::PlanReview::Projection.new(record).observation_digest,
      target_fingerprint: fingerprint, value: answer && { "answer" => answer },
      origin: "cli", operator: "test", authorized: true
    ).projection.record
  end

  def open_findings(record)
    record["findings"].select { |entry| entry.fetch("lifecycle") == "open" }
  end

  def open_finding(record, classification)
    open_findings(record).find { |entry| entry.fetch("classification") == classification }
  end

  def with_runner_custody(runner, task, observation: nil)
    owned = observation.nil?
    current = observation || Hive::TaskMeta.observe(task.folder)
    previous = runner.instance_variable_get(:@task_observation)
    runner.instance_variable_set(:@task_observation, current)
    Hive::Lock.with_task_lock(
      task.folder, slug: task.slug, op: "plan-review-test",
      create: false, observation: current
    ) { yield }
  ensure
    runner.instance_variable_set(:@task_observation, previous) if runner
    current&.close if owned
  end

  def orchestrator(task, cfg, adapter:, planner_revision: FakeRevision.new(standard_plan),
                   route_resolver: method(:resolve_route),
                   clock: -> { Time.utc(2026, 8, 12, 12) }, task_observation: nil)
    options = {
      task:, cfg:, planner_identity: planner_identity, adapter:,
      planner_revision:, route_resolver:,
      clock:
    }
    options[:task_observation] = task_observation if task_observation
    Hive::PlanReview::Orchestrator.new(**options)
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

  # Every reviewer route moved, as an operator does when providers run out
  # of quota.
  def reroute(cfg)
    rerouted = Marshal.load(Marshal.dump(cfg))
    grok = {
      "agent" => "grok", "model" => "grok-4.7", "family" => "grok",
      "effort" => "xhigh", "route" => "native_grok_build"
    }
    rerouted["plan_review"]["routes"].merge!(
      "primary" => grok, "verification" => grok,
      "adversarial" => {
        "agent" => "claude", "model" => "claude-opus-5-5", "family" => "anthropic",
        "effort" => "xhigh", "route" => "native_claude"
      }
    )
    rerouted
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

  def rejected_result(diagnostic, bytes)
    Hive::PlanReview::Adapters::Base::Result.new(
      outcome: "retryable_failure", diagnostic:, rejected_output: bytes,
      route_receipt: { "diagnostic_source" => "parser" }
    )
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
        decision_assessments: request.kind == "decision_triage" ? request.pending_findings.map { |f|
          { "sources" => [ f.fetch("fingerprint") ], "classification" => f.fetch("classification"),
            "title" => f.fetch("title"), "disposition" => f.fetch("description"),
            "rationale" => "The requirement explicitly leaves this material choice unresolved.",
            "boundary" => f.fetch("classification") == "safe_auto" ? nil :
              { "requirement" => "Unanswered requirement", "change" => "Change authorized behavior",
                "alternatives" => [ "Keep existing behavior", "Change behavior" ] } }
        } : [],
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

  def seed_prerequisite(project_root, slug, id:, stage: "8-finalize")
    folder = File.join(project_root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: slug)
    folder
  end

  def with_registered_hivedev(project_root, repository_identity: "github.com/acme/hivedev")
    registry = [
      { "name" => "hivedev", "path" => project_root, "repository_identity" => repository_identity }
    ]
    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { registry }) do
      with_replaced_singleton_method(Hive::RepositoryIdentity, :current, ->(_) { repository_identity }) do
        yield
      end
    end
  end

  def with_task(plan, meta_depends_on: nil, shipped_defaults: false)
    Dir.mktmpdir("hive-plan-orchestrator") do |project|
      folder = File.join(project, ".hive-state", "stages", "3-plan", "demo-task")
      FileUtils.mkdir_p(folder)
      meta = File.join(folder, "meta.yml")
      dependency = meta_depends_on ? "depends_on: #{meta_depends_on}\n" : ""
      File.write(meta, "id: task-1\nslug: demo-task\nworkflow: coding\n#{dependency}")
      prepare_test_task_lease_repository(folder)
      File.write(File.join(folder, "plan.md"), plan)
      task = Task.new(
        folder:, project_root: project, slug: "demo-task", id: "task-1",
        workflow: Workflow.new(id: :coding), meta_yml_path: meta, project_name: "hivedev"
      )
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["project_root"] = project
      # These scenarios exercise the adversarial leg and the three-round
      # revision budget at standard level; the shipped defaults gate both
      # (see the convergence-default tests below).
      cfg["plan_review"]["adversarial_min_level"] = "standard" unless shipped_defaults
      cfg["plan_review"]["max_revision_rounds"] = { "standard" => 3, "mandatory" => 3 } unless shipped_defaults
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
