require "digest"
require "fileutils"
require "json"
require "time"
require "hive/atomic_file"
require "hive/plan_review/approval_policy"
require "hive/plan_review/adapters/base"
require "hive/plan_review/adapters/ce_doc_review"
require "hive/plan_review/clearance"
require "hive/plan_review/decision"
require "hive/plan_review/identity"
require "hive/plan_review/planner_revision"
require "hive/plan_review/plan_signals"
require "hive/plan_review/policy"
require "hive/plan_review/projection"
require "hive/plan_review/route_resolver"
require "hive/plan_review/store"

module Hive
  module PlanReview
    class Orchestrator
      TRANSIENT_OUTCOMES = %w[provider_limit timeout retryable_failure].freeze
      SUCCESS_OUTCOMES = %w[success partial_coverage].freeze
      TERMINAL_OUTCOMES = (SUCCESS_OUTCOMES + %w[unsupported terminal_failure]).freeze

      class << self
        def run!(task:, cfg:, planner_identity:, **options)
          new(task:, cfg:, planner_identity:, **options).advance!
        end
      end

      def initialize(task:, cfg:, planner_identity:, adapter: nil, route_resolver: nil,
                     planner_revision: nil, clock: -> { Time.now.utc })
        @task = task
        @cfg = cfg
        @planner_identity = stringify(planner_identity)
        @store = Store.new(task_folder: task.folder)
        @adapter = adapter || Adapters::CeDocReview.new(
          runner: Adapters::CeDocReview::HiveRunner.new(task:, cfg:)
        )
        @route_resolver = route_resolver || lambda do |**arguments|
          RouteResolver.resolve(**arguments, cfg: @cfg)
        end
        @planner_revision = planner_revision || PlannerRevision.new(task:, cfg:)
        @clock = clock
      end

      def advance!
        plan_path = File.join(@task.folder, "plan.md")
        canonical_digest = safe_plan_digest(plan_path)
        return nil unless canonical_digest

        current = @store.current(optional: true)
        if current && current["candidate_plan_digest"] == canonical_digest
          return Projection.new(current) if current.execution_allowed?

          return resume_review(current, File.binread(plan_path))
        end

        signals = PlanSignals.analyze(
          plan_path:, task_folder: @task.folder,
          max_bytes: @cfg.dig("plan_review", "skip", "max_bytes"),
          max_files: @cfg.dig("plan_review", "skip", "max_files"),
          protected_paths: @cfg.dig("plan_review", "protected_paths")
        )
        return nil unless signals.valid?

        policy = Policy.evaluate(
          workflow_id: @task.workflow.id, signals:, config: @cfg,
          run_level: persisted_run_level
        )
        return nil unless policy.applicable?

        generation = task_generation
        review_id = Identity.logical(
          task_id: task_id,
          plan_generation: "#{generation}:#{signals.plan_digest}",
          policy_fingerprint: policy.policy_fingerprint
        )
        if current&.review_id == review_id
          return Projection.new(current) if current.execution_allowed?

          return resume_review(current, File.binread(plan_path))
        end

        record = begin_review(current, policy, signals, generation, review_id)
        return terminal(record, state: "skipped", outcome: "skipped") if
          record.effective_level == "skip"

        resume_review(record, File.binread(plan_path))
      rescue StaleObservation
        Projection.load(task_folder: @task.folder)
      end

      private

      def resume_review(record, original_plan_bytes)
        %w[primary adversarial].each do |role|
          record, pending = ensure_leg(record, role, original_plan_bytes)
          return Projection.new(record) if pending
        end

        outcomes = latest_initial_outcomes(record)
        initial_coverage = CoverageEvaluator.evaluate(
          level: record.effective_level, coverage: record["coverage"],
          adapter_outcomes: outcomes
        )
        if record.effective_level == "mandatory" && initial_coverage.blocked?
          return terminal(
            record, state: "blocked", outcome: "blocked",
            blockers: initial_coverage.blockers,
            required_action: "waive named coverage or restore required reviewer capability"
          )
        end
        if record.effective_level == "standard" && initial_coverage.degraded? &&
           initial_coverage.degradation_reason != "partial_coverage"
          return terminal(
            record, state: "degraded_cleared", outcome: "degraded_cleared",
            degradation_reason: initial_coverage.degradation_reason
          )
        end

        record = consume_approval_policies(record)
        pending = pending_decision_findings(record)
        unless pending.empty?
          blockers = pending.map { |finding| Clearance.send(:finding_blocker, finding) }
          action = pending.first.classification == "manual" ?
            "answer manual plan finding #{pending.first.fingerprint}" :
            "approve gated plan finding #{pending.first.fingerprint}"
          return Projection.new(publish(
            record, "state" => "awaiting_decision", "outcome" => nil,
            "blockers" => blockers, "required_action" => action,
            "execution_allowed" => false
          ))
        end

        accepted = accepted_findings(record)
        candidate_bytes = candidate_bytes(record)
        if !accepted.empty? && candidate_bytes.nil?
          record = publish(
            record, "state" => "revising", "outcome" => nil, "blockers" => [],
            "required_action" => "revise plan with accepted findings",
            "execution_allowed" => false
          )
          revision = @planner_revision.call(
            review_id: record.review_id, plan_bytes: original_plan_bytes,
            findings: accepted, planner_identity: planner_identity(record),
            timeout_sec: @cfg.dig("plan_review", "attempts", "timeout_sec")
          )
          unless revision.success?
            return terminal(
              record, state: "blocked", outcome: "blocked",
              blockers: [ { "owner" => "planner", "reason" => "planner_revision_#{revision.outcome}" } ],
              required_action: "repair the planner route and start a linked plan generation"
            )
          end
          candidate_ref = @store.write_review_artifact!(
            review_id: record.review_id, basename: "candidate-plan.md",
            content: revision.candidate_bytes
          )
          candidate_bytes = @store.read_reference(candidate_ref)
          candidate_digest = Digest::SHA256.hexdigest(candidate_bytes.b)
          incorporated = incorporate_findings(record["findings"], accepted)
          record = publish(
            record,
            "candidate_plan_digest" => candidate_digest,
            "findings" => incorporated,
            "routes" => record["routes"] + [ planner_revision_route(revision, record) ],
            "artifacts" => record["artifacts"].merge("candidate_plan" => candidate_ref),
            "state" => "verifying", "required_action" => "run disposition verification",
            "blockers" => [], "execution_allowed" => false
          )
        end

        candidate_bytes ||= original_plan_bytes
        record = publish(
          record, "state" => "verifying", "outcome" => nil, "blockers" => [],
          "required_action" => "run disposition verification", "execution_allowed" => false
        ) unless record.state == "verifying"

        verification_route = latest_route(record, "verification")
        verification_result = nil
        unless verification_route
          record, verification_result = dispatch_attempt(
            record, "verification", candidate_bytes,
            [ { "name" => "verification", "required" => true } ],
            merge_coverage: false, merge_findings: false
          )
          verification_route = latest_route(record, "verification")
        end
        verification_outcome = verification_route.fetch("outcome")
        verification_findings = verification_result ? verification_result.findings :
          persisted_result_findings(record, "verification")
        findings, verification_blockers = apply_verification(
          record["findings"], verification_findings, verification_outcome
        )
        if record["candidate_plan_digest"] && !SUCCESS_OUTCOMES.include?(verification_outcome)
          verification_blockers << {
            "owner" => "reviewer", "reason" => "candidate_verification_#{verification_outcome}"
          }
        end
        clearance = Clearance.evaluate(
          level: record.effective_level, coverage: record["coverage"], findings:,
          adapter_outcomes: outcomes, verification_outcome:,
          revision_required: !accepted.empty?,
          revision_complete: accepted.empty? || !record["candidate_plan_digest"].nil?,
          verification_complete: true, verification_blockers:
        )
        promote_candidate!(record, candidate_bytes) if
          clearance.execution_allowed && record["candidate_plan_digest"]
        terminal(
          record, state: clearance.state, outcome: clearance.outcome,
          findings:, blockers: clearance.blockers,
          required_action: clearance.required_action,
          degradation_reason: clearance.degradation_reason
        )
      end

      def begin_review(current, policy, signals, generation, review_id)
        created_at = timestamp
        manifest = Record.new(
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION, "kind" => "manifest",
          "review_id" => review_id, "prior_review_id" => current&.review_id,
          "task_id" => task_id, "task_generation" => generation,
          "plan_digest" => signals.plan_digest,
          "policy_fingerprint" => policy.policy_fingerprint,
          "computed_level" => policy.computed_level,
          "effective_level" => policy.effective_level,
          "created_at" => created_at
        )
        @store.create_review!(manifest)
        policy_ref = @store.write_review_artifact!(
          review_id:, basename: "policy-#{policy.policy_fingerprint}.json",
          content: policy.to_h.merge("signals" => signals.to_h), json: true
        )
        version = current ? current.version + 1 : 1
        projection = Record.new(
          manifest.to_h.merge(
            "kind" => "projection", "version" => version,
            "candidate_plan_digest" => nil, "state" => "uninitialized", "outcome" => nil,
            "attempt_ids" => [], "current_attempt_id" => nil,
            "coverage" => requested_coverage(review_id, policy.policy_fingerprint),
            "findings" => [], "decisions" => [],
            "routes" => [ planner_route(@planner_identity) ],
            "artifacts" => { "policy" => policy_ref }, "blockers" => [],
            "required_action" => policy.effective_level == "skip" ? nil : "start plan review",
            "degradation_reason" => nil, "execution_allowed" => false,
            "policy_reasons" => policy.matched_reasons,
            "level_sources" => policy.level_sources, "retry_at" => nil,
            "updated_at" => timestamp
          )
        )
        @store.publish_current!(projection, expected_version: current&.version)
      end

      def ensure_leg(record, role, plan_bytes)
        max_attempts = 1 + Integer(@cfg.dig("plan_review", "attempts", "max_transient"))
        loop do
          route = latest_route(record, role)
          return [ record, false ] if route && TERMINAL_OUTCOMES.include?(route["outcome"])

          if route
            attempts = record["routes"].count { |entry| entry["role"] == role }
            return [ record, false ] if attempts >= max_attempts
            if retry_in_future?(route["retry_at"])
              scheduled = publish(
                record, "state" => "retry_scheduled", "outcome" => nil,
                "required_action" => "retry plan review after #{route.fetch('retry_at')}",
                "retry_at" => route.fetch("retry_at"), "execution_allowed" => false
              )
              return [ scheduled, true ]
            end
          end

          record, = dispatch_attempt(
            record, role, plan_bytes,
            coverage_for(role, record.review_id, record.policy_fingerprint)
          )
        end
      end

      def dispatch_attempt(record, role, plan_bytes, requested, merge_coverage: true,
                           merge_findings: true)
        resolution = @route_resolver.call(role:, planner_identity: planner_identity(record))
        attempt_id = Identity.attempt(record.review_id)
        if resolution.resolved?
          attempt_dir = File.join(
            @store.root, "reviews", record.review_id, "adapter-output", attempt_id
          )
          FileUtils.mkdir_p(attempt_dir, mode: 0o700)
          input_path = File.join(attempt_dir, "controller-input.md")
          File.binwrite(input_path, plan_bytes)
          File.chmod(0o400, input_path)
          request = Adapters::Base::Request.new(
            plan_path: input_path, plan_digest: Digest::SHA256.hexdigest(plan_bytes.b),
            document_type: "executable_plan", level: record.effective_level,
            required_coverage: requested.map { |entry| entry.fetch("name") },
            policy_fingerprint: record.policy_fingerprint,
            planner_identity: planner_identity(record), reviewer: resolution.candidate,
            output_directory: attempt_dir,
            timeout_sec: @cfg.dig("plan_review", "attempts", "timeout_sec"),
            attempt_id:, kind: role, project_root: @task.project_root
          )
          adapter_result = @adapter.call(request)
        else
          adapter_result = Adapters::Base::Result.new(
            outcome: "unsupported", diagnostic: "review route is unavailable",
            route_receipt: resolution.receipt
          )
        end
        coverage = CoverageEvaluator.merge(
          requested:, observed: adapter_result.coverage, outcome: adapter_result.outcome
        )
        route = merge_route_receipts(
          resolution.receipt, adapter_result.route_receipt,
          role:, attempt_id:, outcome: adapter_result.outcome,
          retry_at: adapter_result.retry_at
        )
        refs = @store.write_attempt!(
          review_id: record.review_id, attempt_id:, plan_bytes:,
          result: adapter_result.to_h, coverage:, route_receipt: route
        )
        artifacts = record["artifacts"].merge(
          "#{role}_input" => refs.fetch("input_plan"),
          "#{role}_result" => refs.fetch("result"),
          "#{role}_coverage" => refs.fetch("coverage"),
          "#{role}_route" => refs.fetch("route_receipt")
        )
        findings = merge_findings ? merge_findings(record["findings"], adapter_result.findings) :
          record["findings"]
        combined_coverage = merge_coverage ? CoverageEvaluator.combine(record["coverage"], coverage) :
          record["coverage"]
        state = TRANSIENT_OUTCOMES.include?(adapter_result.outcome) ? "retry_scheduled" :
          (role == "verification" ? "verifying" : "reviewing")
        updated = publish(
          record,
          "state" => state, "outcome" => nil,
          "attempt_ids" => record["attempt_ids"] + [ attempt_id ],
          "current_attempt_id" => attempt_id,
          "coverage" => combined_coverage, "findings" => findings,
          "routes" => record["routes"] + [ route ], "artifacts" => artifacts,
          "blockers" => [], "required_action" => nil,
          "retry_at" => adapter_result.retry_at, "execution_allowed" => false
        )
        [ updated, adapter_result ]
      end

      def terminal(record, state:, outcome:, findings: record["findings"], blockers: [],
                   required_action: nil, degradation_reason: nil)
        next_version = record.version + 1
        resolution = {
          "review_id" => record.review_id, "version" => next_version,
          "state" => state, "outcome" => outcome,
          "plan_digest" => record.plan_digest,
          "candidate_plan_digest" => record["candidate_plan_digest"],
          "policy_fingerprint" => record.policy_fingerprint,
          "computed_level" => record.computed_level,
          "effective_level" => record.effective_level,
          "coverage" => record["coverage"], "findings" => findings,
          "decisions" => record["decisions"], "routes" => record["routes"],
          "blockers" => blockers, "required_action" => required_action,
          "degradation_reason" => degradation_reason,
          "execution_allowed" => %w[skipped cleared degraded_cleared].include?(state),
          "resolved_at" => timestamp
        }
        reference = @store.write_review_artifact!(
          review_id: record.review_id, basename: "resolution-v#{next_version}.json",
          content: resolution, json: true
        )
        Projection.new(publish(
          record,
          "state" => state, "outcome" => outcome, "findings" => findings,
          "blockers" => blockers, "required_action" => required_action,
          "degradation_reason" => degradation_reason,
          "artifacts" => record["artifacts"].merge("resolution" => reference),
          "retry_at" => nil,
          "execution_allowed" => %w[skipped cleared degraded_cleared].include?(state)
        ))
      end

      def publish(record, attributes)
        data = record.to_h.merge(stringify(attributes))
        data["version"] = record.version + 1
        data["updated_at"] = timestamp
        @store.publish_current!(Record.new(data), expected_version: record.version)
      end

      def requested_coverage(review_id, policy_fingerprint)
        required = Array(@cfg.dig("plan_review", "coverage", "required"))
        optional = Array(@cfg.dig("plan_review", "coverage", "optional"))
        (required.map { |name| [ name, true ] } + optional.map { |name| [ name, false ] })
          .uniq { |name, _required| name }
          .map do |name, required_value|
            {
              "name" => name, "required" => required_value, "status" => "requested",
              "fingerprint" => Identity.coverage(
                review_id:, name:, policy_fingerprint:
              )
            }.freeze
          end.freeze
      end

      def coverage_for(role, review_id, policy_fingerprint)
        rows = requested_coverage(review_id, policy_fingerprint)
        if role == "adversarial"
          row = rows.find { |entry| entry.fetch("name") == "adversarial" }
          [ row || coverage_row(review_id, policy_fingerprint, "adversarial", required: true) ]
        else
          selected = rows.reject { |entry| entry.fetch("name") == "adversarial" }
          selected.empty? ?
            [ coverage_row(review_id, policy_fingerprint, "whole_document", required: true) ] :
            selected
        end
      end

      def coverage_row(review_id, policy_fingerprint, name, required:)
        {
          "name" => name, "required" => required, "status" => "requested",
          "fingerprint" => Identity.coverage(
            review_id:, name:, policy_fingerprint:
          )
        }.freeze
      end

      def consume_approval_policies(record)
        findings = record["findings"].map { |entry| Finding.new(entry) }
        decisions = record["decisions"].dup
        artifacts = record["artifacts"].dup
        changed = false
        findings.map! do |finding|
          unless finding.classification == "gated_auto" && finding.lifecycle == "open"
            next finding
          end
          match = ApprovalPolicy.match(
            finding:, policies: @cfg.dig("plan_review", "approval_policies"),
            review_id: record.review_id, policy_fingerprint: record.policy_fingerprint,
            now: @clock.call
          )
          next finding unless match

          decision = Decision.new(
            "schema" => Decision::SCHEMA, "schema_version" => Decision::SCHEMA_VERSION,
            "review_id" => record.review_id,
            "task_generation" => record.task_generation.to_s,
            "policy_fingerprint" => record.policy_fingerprint,
            "expected_artifact_digest" => Projection.new(record).observation_digest,
            "target_fingerprint" => finding.fingerprint,
            "action" => "approve_finding", "value" => {}, "reason" => nil,
            "origin" => "policy", "operator" => "policy:#{match.receipt.fetch('policy_id')}",
            "policy_receipt" => match.receipt, "decided_at" => timestamp
          )
          reference = @store.write_decision!(
            review_id: record.review_id, target_fingerprint: finding.fingerprint,
            decision_id: decision.decision_id, data: decision.to_h
          )
          decisions << decision.to_h
          artifacts["decision_#{decision.decision_id}"] = reference
          changed = true
          Finding.new(finding.to_h.merge(
            "lifecycle" => "approved", "decision_id" => decision.decision_id
          ))
        end
        return record unless changed

        publish(
          record, "findings" => findings.map(&:to_h), "decisions" => decisions,
          "artifacts" => artifacts, "state" => "reviewing", "outcome" => nil,
          "blockers" => [], "required_action" => nil, "execution_allowed" => false
        )
      end

      def pending_decision_findings(record)
        record["findings"].map { |entry| Finding.new(entry) }.select do |finding|
          finding.classification == "gated_auto" && finding.lifecycle == "open" ||
            finding.classification == "manual" && finding.lifecycle == "open"
        end
      end

      def accepted_findings(record)
        record["findings"].map { |entry| Finding.new(entry) }.select do |finding|
          finding.classification == "safe_auto" && finding.lifecycle == "open" ||
            %w[approved answered].include?(finding.lifecycle)
        end
      end

      def incorporate_findings(entries, accepted)
        accepted_ids = accepted.map(&:fingerprint)
        entries.map do |entry|
          finding = Finding.new(entry)
          next finding.to_h unless accepted_ids.include?(finding.fingerprint)

          finding.to_h.merge("lifecycle" => "incorporated", "incorporated_at" => timestamp)
        end
      end

      def apply_verification(entries, observed, outcome)
        existing = entries.map { |entry| Finding.new(entry) }
        verification = Array(observed).map { |entry| entry.is_a?(Finding) ? entry : Finding.new(entry) }
        observed_ids = verification.map(&:fingerprint)
        updated = existing.map do |finding|
          if SUCCESS_OUTCOMES.include?(outcome) &&
             %w[incorporated approved answered].include?(finding.lifecycle) &&
             !observed_ids.include?(finding.fingerprint)
            finding.to_h.merge("lifecycle" => "verified", "verified_at" => timestamp)
          else
            finding.to_h
          end
        end
        known = updated.to_h { |entry| [ entry.fetch("fingerprint"), true ] }
        verification.each do |finding|
          updated << finding.to_h unless known[finding.fingerprint]
        end
        blockers = if SUCCESS_OUTCOMES.include?(outcome)
          verification.reject { |finding| finding.classification == "fyi" || finding.resolved? }.map do |finding|
            {
              "owner" => "operator", "reason" => "verification_finding",
              "finding_fingerprint" => finding.fingerprint
            }
          end
        else []
        end
        [ updated, blockers ]
      end

      def merge_findings(existing, observed)
        by_id = existing.to_h do |entry|
          finding = Finding.new(entry)
          [ finding.fingerprint, finding.to_h ]
        end
        Array(observed).each do |entry|
          finding = entry.is_a?(Finding) ? entry : Finding.new(entry)
          by_id[finding.fingerprint] ||= finding.to_h
        end
        by_id.values.sort_by { |entry| [ entry.fetch("display_order"), entry.fetch("fingerprint") ] }
      end

      def candidate_bytes(record)
        reference = record["artifacts"]["candidate_plan"]
        reference && @store.read_reference(reference)
      end

      def persisted_result_findings(record, role)
        reference = record["artifacts"]["#{role}_result"]
        return [] unless reference

        parsed = JSON.parse(@store.read_reference(reference))
        Array(parsed["findings"])
      rescue JSON::ParserError
        raise InvalidRecord, "persisted #{role} result is invalid JSON"
      end

      def latest_initial_outcomes(record)
        %w[primary adversarial].map { |role| latest_route(record, role)&.fetch("outcome") }
      end

      def latest_route(record, role)
        record["routes"].reverse.find { |entry| entry["role"] == role }
      end

      def merge_route_receipts(base, adapter, role:, attempt_id:, outcome:, retry_at:)
        base = stringify(base)
        adapter = stringify(adapter)
        {
          "role" => role,
          "requested" => adapter["requested"] || base["requested"] || {},
          "actual" => adapter["actual"] || base["actual"] || {},
          "capability_result" => adapter["capability_result"] || base["capability_result"],
          "independence_verified" => adapter.fetch(
            "independence_verified", base.fetch("independence_verified", false)
          ),
          "independence_reason" => adapter["independence_reason"] || base["independence_reason"],
          "attempt_id" => attempt_id, "outcome" => outcome, "retry_at" => retry_at
        }.compact
      end

      def planner_route(identity)
        {
          "role" => "planner", "requested" => identity, "actual" => identity,
          "capability_result" => "captured", "independence_verified" => false,
          "independence_reason" => "authority_source"
        }
      end

      def planner_revision_route(revision, record)
        actual = revision.route_receipt.empty? ? planner_identity(record) : revision.route_receipt
        {
          "role" => "planner_revision", "requested" => planner_identity(record),
          "actual" => actual, "capability_result" => "present",
          "independence_verified" => false, "independence_reason" => "same_plan_authority",
          "outcome" => revision.outcome
        }
      end

      def planner_identity(record)
        route = record["routes"].find { |entry| entry["role"] == "planner" }
        stringify(route&.fetch("actual", nil) || @planner_identity)
      end

      def promote_candidate!(record, candidate_bytes)
        path = File.join(@task.folder, "plan.md")
        observed = safe_plan_digest(path)
        allowed = [ record.plan_digest, record["candidate_plan_digest"] ].compact
        unless allowed.include?(observed)
          raise StaleObservation, "canonical plan changed before candidate promotion"
        end
        unless Digest::SHA256.hexdigest(candidate_bytes.b) == record["candidate_plan_digest"]
          raise InvalidRecord, "candidate digest changed before promotion"
        end
        mode = File.stat(path).mode & 0o777
        Hive::AtomicFile.write(path, candidate_bytes, mode:)
        File.chmod(mode, path)
      end

      def persisted_run_level
        path = File.join(@store.root, "level.json")
        return nil unless File.file?(path) && !File.symlink?(path)

        JSON.parse(File.binread(path))["level"]
      rescue JSON::ParserError, SystemCallError, IOError
        nil
      end

      def task_generation
        meta = File.file?(@task.meta_yml_path) ? File.binread(@task.meta_yml_path) : ""
        Digest::SHA256.hexdigest(JSON.generate(
          "task_id" => task_id, "slug" => @task.slug,
          "workflow" => @task.workflow.id.to_s,
          "meta_digest" => Digest::SHA256.hexdigest(meta)
        ))
      end

      def task_id = (@task.id || @task.slug).to_s

      def retry_in_future?(value)
        value && Time.iso8601(value) > @clock.call
      rescue ArgumentError
        false
      end

      def safe_plan_digest(path)
        stat = File.lstat(path)
        return nil if stat.symlink? || !stat.file?

        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError, IOError
        nil
      end

      def timestamp = @clock.call.utc.iso8601(6)

      def stringify(value)
        case value
        when Hash then value.to_h { |key, child| [ key.to_s, stringify(child) ] }
        when Array then value.map { |child| stringify(child) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
