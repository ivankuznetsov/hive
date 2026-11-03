require "hive/task_capabilities/verification"
require "hive/task_activity"
require "hive/worktree"

module Hive
  module TaskCapabilities
    # Transition authority is computed from accepted bytes and the live exact
    # implementation identity. Markers and condition overrides confer none.
    class Gate
      class Blocked < Admission::Error; end

      def initialize(task:, cfg:, worktree_path: nil)
        @task, @cfg, @worktree = task, cfg, worktree_path
      end

      def self.transition!(task:, destination:, cfg:, closure_receipt_digest: nil)
        review = task.workflow.stage_named("review")
        dest = task.workflow.stage_for_dir(destination)
        return true unless review && dest && dest.index > task.stage_index && dest.index > review.index
        if closure_receipt_digest && destination == task.workflow.stages.last.dir
          require "hive/task_closure"
          evidence = Hive::TaskClosure.transition_evidence(task, receipt_digest: closure_receipt_digest)
          return true if evidence
          raise Blocked, "terminal closure receipt is missing or stale"
        end
        new(task: task, cfg: cfg).enforce!
      end

      def self.record_terminal!(task:, disposition:, reference:)
        results = ResultStore.new(task.folder)
        digest = results.record_terminal!(disposition: disposition, reference: reference)
        return nil unless digest
        activity = Hive::TaskActivity.for_task(task)
        activity&.record(kind: "capability_terminal", operation_id: "capability-terminal:#{digest}:#{SecureRandom.hex(6)}",
          reason: "#{disposition}: gate not evaluated", source: "reconciliation",
          payload: { "result_digest" => digest, "disposition" => disposition, "reference" => reference,
            "label" => disposition == "cancelled" ? "Cancelled — gate not evaluated" : "Closed out-of-band — gate not evaluated" })
        digest
      end

      # Viewers read the pinned execution environment, never their Rails/CLI
      # process environment. enforce! always performs a fresh live evaluation.
      def read_state
        evaluate(reader: true).merge("authority" => "read-model")
      end

      def evaluate(reader: false)
        store = Store.new(@task.folder)
        plan = store.current
        validate_task!(plan) if plan || @task.instance_variable_get(:@meta)&.dig(:task_capabilities)
        return { "state" => "legacy", "allowed" => true, "capabilities" => [], "checks" => [] } unless plan
        validate_composition!(plan)
        results = ResultStore.new(@task.folder)
        terminal_dispositions = results.terminal_history.map(&:last)
        @worktree ||= @task.worktree_path
        sha = git!(:head_oid).strip
        environment = reader ? plan.data.fetch("bindings").flat_map { |binding| binding.fetch("checks", []) }.first&.dig("runner", "environment") || {} : Verification.environment(plan: plan)
        delta = Result.task_delta(@worktree, sha: sha, target_branch: target_branch)
        value = results.aggregate(plan: plan, sha: sha, environment: environment, task_delta: delta)
        @equivalences = []
        value.fetch("capabilities").each do |capability|
          binding = plan.data.fetch("bindings").find { |item| item["id"] == capability["id"] }
          next unless binding
          capability.fetch("checks").each do |check|
            if check["state"] == "failed" && binding["id"] == "security"
              dispositions = results.disposition_history.select { |_digest, record| record["result_digest"] == check["result_digest"] && record["execution_plan_digest"] == plan.digest }
              accepted = dispositions.flat_map { |_digest, record| record.fetch("finding_ids") }
              if (check.fetch("result").fetch("findings").map { |finding| finding.fetch("id") } - accepted).empty?
                check.merge!("state" => "waived", "disposition" => "risk-accepted", "dispositions" => dispositions.map(&:first))
              end
            end
            next unless check["state"] == "stale" && check.dig("result", "state") == "passed"
            old = check.fetch("result")
            next unless old["check_digest"] == Result.check_digest(binding, binding.fetch("checks").find { |item| item["id"] == check["check_id"] }) && old["environment_digest"] == Result.digest(environment)
            next unless Result.equivalent_delta?(old["task_delta"], delta)
            proof = { "old_sha" => old.fetch("evaluated_sha"), "new_sha" => sha,
              "old_delta" => old.fetch("task_delta"), "new_delta" => delta }
            @equivalences << { "result_digest" => check.fetch("result_digest"), "proof" => proof }
            check.merge!("state" => "passed", "equivalence" => proof)
          end
          states = capability.fetch("checks").map { |check| check.fetch("state") }
          capability["state"] = "passed" if !states.empty? && states.all? { |state| %w[passed not-applicable waived].include?(state) } &&
            (binding["id"] != "qa" || capability.fetch("checks").any? { |check| check["kind"] == "behavior" && check["state"] == "passed" })
          capability.merge!("state" => "waived", "disposition" => "risk-accepted") if capability["state"] == "passed" && states.include?("waived")
          begin
            validate_binding!(binding, plan, store, environment: environment)
          rescue Hive::Error, KeyError, SystemCallError => error
            capability.merge!("state" => "blocked", "reason" => error.message)
          end
        end
        validate_waivers!(plan, value)
        dirty = !git!(:status).empty?
        states = value.fetch("capabilities").map { |capability| capability.fetch("state") }
        allowed = !dirty && !states.empty? && states.all? { |state| %w[passed waived].include?(state) }
        value.merge!("allowed" => allowed, "state" => allowed ? (states.include?("waived") ? "waived" : "passed") : (dirty ? "stale" : states.find { |state| !%w[passed waived].include?(state) } || "blocked"),
          "reason" => dirty ? "implementation worktree changed; return to review and rerun verification" : nil,
          "terminal_dispositions" => terminal_dispositions)
        value
      rescue Hive::Error, KeyError, TypeError, SystemCallError => error
        { "state" => "blocked", "allowed" => false, "reason" => "capability gate unavailable: #{error.message}", "capabilities" => [], "checks" => [], "terminal_dispositions" => terminal_dispositions || [] }
      end

      def enforce!
        value = evaluate
        if value["evaluated_sha"] && !value.fetch("checks").empty?
          begin
            refresh_target_base!
          rescue Blocked => error
            record(value.merge("state" => "blocked", "allowed" => false, "reason" => error.message))
            raise
          end
          value = evaluate
        end
        if value.fetch("allowed") && value["state"] != "legacy"
          results = ResultStore.new(@task.folder)
          @equivalences.each { |entry| results.record_equivalence!(plan_digest: value.fetch("execution_plan_digest"), **entry.transform_keys(&:to_sym)) }
        end
        record(value)
        return value if value.fetch("allowed")
        reasons = value.fetch("capabilities").reject { |item| %w[passed waived].include?(item["state"]) }.map do |item|
          "#{item.fetch('id')}: #{item['reason'] || item.fetch('state')}"
        end
        raise Blocked.new(([ value["reason"], *reasons ].compact.join("; ") + "; restore required checks and rerun review; an unavailable approved security route must be restored or the task archived/cancelled").strip)
      end

      def record(value)
        return if value["state"] == "legacy"
        summary = self.class.summary(value)
        context = Hive::Attempts::Context.current
        projection = Hive::TaskProjection::Reader.new(task_folder: @task.folder, task: @task).read
        commit_generation = projection["identity"]["commit_generation"]
        activity = context ? Hive::TaskActivity.for_context(@task, context: context, commit_generation: commit_generation) : Hive::TaskActivity.for_task(@task)
        activity&.record(kind: "capability_gate_observed", operation_id: "capability-gate:#{Result.digest(summary)}:#{SecureRandom.hex(6)}",
          reason: "capability gate evaluated", source: "stage_service", payload: summary.merge("head_sha" => value["evaluated_sha"]))
      end

      def self.summary(value)
        value.slice("state", "allowed", "execution_plan_digest", "evaluated_sha", "reason").merge(
          "capabilities" => value.fetch("capabilities").map { |item| item.slice("id", "state", "reason", "disposition") },
          "checks" => value.fetch("checks").map { |item| item.slice("capability_id", "check_id", "state", "result_digest", "dispositions", "disposition") },
          "terminal_dispositions" => value.fetch("terminal_dispositions", []).map { |item| item.slice("disposition", "label", "reference") })
      end

      private

      def target_branch
        (@task.respond_to?(:base_branch) && @task.base_branch) || @cfg["default_branch"]
      end

      def refresh_target_base!
        _url, _error, remote = Open3.capture3("git", "-C", @worktree, "remote", "get-url", "origin")
        return unless remote.success?
        branch = target_branch || Hive::GitOps.new(@worktree).origin_default_branch
        raise Blocked, "verification target branch is unavailable; configure the task's exact base and rerun review" unless branch
        Hive::Worktree.validate_branch_name!(branch)
        unless Hive::Worktree.fetch_origin_branch(@worktree, branch).last.success?
          raise Blocked, "verification target branch refresh failed; restore the existing origin route and rerun review"
        end
      rescue Hive::WorktreeError => error
        raise Blocked, error.message
      end

      def validate_task!(plan)
        read = Hive::TaskMeta.read_for_admission(@task.folder)
        raise Store::InvalidState, "invalid task metadata" unless read.ok?
        actual = Hive::WorkflowPackage::CanonicalJSON.normalize(Hive::TaskMeta.stable_identity(read.data))
        cached = @task.instance_variable_get(:@meta)
        expected = { "id" => @task.id&.to_s, "slug" => @task.slug, "workflow" => cached ? cached[:workflow] : plan&.data&.dig("task", "workflow") }
        raise Store::InvalidState, "task was replaced or its identity changed" unless actual == expected
        if cached && cached[:task_capabilities] != read.data[:task_capabilities]
          raise Store::InvalidState, "task capability adoption metadata changed"
        end
        raise Store::InvalidState, "adopted plan disappeared" if read.data[:task_capabilities] && !plan
      end

      def validate_composition!(plan)
        definitions = plan.data.fetch("definitions")
        ids = plan.data.fetch("bindings").map { |binding| binding.fetch("id") }
        raise Result::Invalid, "duplicate capability binding" unless ids.uniq == ids
        plan.data.fetch("choices").each do |id, choice|
          next unless choice["effective"] == "on" && definitions.any? { |item| item["id"] == id && item["kind"] == "verification" }
          raise Result::Invalid, "selected verifier #{id} has no accepted binding" unless ids.include?(id)
        end
        (plan.data.dig("policy", "policy", "required") || []).each do |id|
          raise Result::Invalid, "hard-required capability #{id} is not selected" unless ids.include?(id)
        end
      end

      def validate_binding!(binding, plan, store, environment:)
        raise Result::Invalid, "selected verifier has no supported review attachment" unless binding["stage"] == "review" && binding["kind"] == "verification"
        binding.fetch("checks").each do |check|
          runner = check.fetch("runner")
          raise Result::Invalid, "selected check environment changed" unless runner["environment"] == environment
          raise Result::Invalid, "selected check runner unavailable" unless %w[command actor].include?(runner["type"])
          actor_binding = runner["actor_binding"] || (binding if binding["actor"])
          ActorRunner.available!(task: @task, cfg: @cfg, binding: actor_binding) if actor_binding
        end
        blockers = plan.data.fetch("blockers").select { |item| item["capability"] == binding["id"] && item["phase"] != "finalization" }
        raise Admission::Error, blockers.map { |item| item.fetch("message") }.join("; ") unless blockers.empty?
      end

      def validate_waivers!(plan, value)
        value.fetch("capabilities").select { |item| item["waiver"] }.each do |item|
          waiver = item.fetch("waiver")
          required = plan.data.dig("policy", "policy", "required") || []
          unless item["id"] == "qa" && !required.include?("qa") && waiver["reason"].is_a?(String) && !waiver["reason"].strip.empty? && (waiver["whole_gate"] == true || (waiver["checks"].is_a?(Array) && !waiver["checks"].empty? && waiver["check_fingerprints"].is_a?(Hash) && waiver["check_fingerprints"].keys.sort == waiver["checks"].sort)) && plan.data.dig("inputs", "qa") == "off" && !plan.data.fetch("bindings").any? { |binding| binding["id"] == "qa" }
            raise Result::Invalid, "capability waiver is not an allowed QA Off disposition"
          end
        end
      end

      def git!(operation)
        result = Hive::AgentGitGate.read(@worktree, operation)
        raise Result::Invalid, "implementation Git identity unavailable" unless result.success?
        result.stdout
      end
    end
  end
end
