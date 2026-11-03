require "hive/task_capabilities/resolver"
require "hive/task_journal"
require "hive/task_projection/reader"

module Hive
  module TaskCapabilities
    # Proposals are ordinary, inert outputs. Only the protected accepted chain
    # and current pointer publish controller-validated decisions and versions.
    class Revision
      PROPOSALS = "capability-proposals".freeze
      INPUTS = %w[selections verification_plans approval_references reason checks skill_updates task_approvals approval_previews].freeze

      def initialize(task:, worktree_path: nil)
        @task = task
        @store = Store.new(task.folder)
        @worktree = worktree_path
      end

      def show
        plan = @store.current
        return { "plan" => nil, "history" => [], "proposals" => [] } unless plan
        unavailable = read_only_reason
        begin
          expected = { "expected_identity" => plan.data.fetch("task"), "expected_version" => plan.version, "expected_sha" => sha } unless unavailable
        rescue Hive::Error => error
          unavailable = error.message
        end
        { "plan" => plan.to_h, "execution_plan_digest" => plan.digest,
          "expected" => expected, "mutation_unavailable" => unavailable,
          "history" => @store.history.map { |entry| { "version" => entry.version, "digest" => entry.digest } },
          "proposals" => proposals.map { |digest, value| value.merge("proposal_digest" => digest, "status" => decision(digest)&.fetch("status") || "proposed") },
          "required_stages" => pending_guidance(plan) }
      end

      def propose(expected_identity:, expected_version:, expected_sha:, selections: [], verification_plans: {}, approval_references: [], task_approvals: [], reason: "", checks: [])
        plan = observe!(expected_identity, expected_version, expected_sha)
        invalid!("verification plans must be a map") unless verification_plans.is_a?(Hash)
        verification_plans.each do |id, raw|
          Definition.new({ "id" => id, "kind" => "verification", "stages" => [ "review" ], "checks" => raw }, stages: @task.workflow.stages, source: "declared verification plan")
        end
        input = Plan.redact({ "selections" => selections, "verification_plans" => verification_plans,
          "approval_references" => approval_references, "reason" => reason, "checks" => checks, "skill_updates" => {}, "task_approvals" => task_approvals, "approval_previews" => [] })
        Definition.strings(input.fetch("checks"), label: "QA check IDs").each { |id| Definition.identifier(id, label: "QA check ID") }
        invalid!("revision reason must be text") unless input.fetch("reason").is_a?(String)
        candidate(plan, input, discover: true)
        value = proposal_value(plan, input, expected_sha)
        digest = Result.digest(value)
        directory = proposal_directory
        FileUtils.mkdir_p(directory)
        Hive::AtomicFile.write(File.join(directory, "#{digest}.json"), canonical(value), mode: 0o600, create: false)
        { "status" => "proposed", "proposal_digest" => digest, "approval_previews" => input.fetch("approval_previews") }
      end

      def accept(proposal_digest:, expected_identity:, expected_version:, expected_sha:)
        Admission.authorize_operator!
        boundary(expected_identity, expected_version, expected_sha, proposal_digest: proposal_digest) do |plan, previous|
          if previous
            invalid!("proposal was already rejected") unless previous["status"] == "accepted"
            next complete(previous)
          end
          proposal = read_proposal(proposal_digest)
          validate_proposal!(proposal, plan, expected_sha)
          revised, approvals = candidate(plan, proposal.fetch("input"))
          publish(plan, revised, approvals, proposal_digest, "accepted", "operator", proposal.fetch("input").fetch("reason"))
        end
      end

      def reject(proposal_digest:, expected_identity:, expected_version:, expected_sha:, reason:)
        Admission.authorize_operator!
        boundary(expected_identity, expected_version, expected_sha, proposal_digest: proposal_digest) do |plan, previous|
          if previous
            invalid!("proposal was already accepted") unless previous["status"] == "rejected"
            next complete(previous)
          end
          validate_proposal!(read_proposal(proposal_digest), plan, expected_sha)
          publish(plan, nil, [], proposal_digest, "rejected", "operator", reason)
        end
      end

      def waive(reason:, checks:, **expected)
        Admission.authorize_operator!
        # Check the boundary before writing even an inert proposal.
        base = @store.history.find { |entry| entry.version == expected.fetch(:expected_version) }
        stale!("waiver plan version is unavailable") unless base
        input = Plan.redact({ "selections" => [ "qa=off" ], "verification_plans" => {}, "approval_references" => [], "reason" => reason, "checks" => checks, "skill_updates" => {}, "task_approvals" => [], "approval_previews" => [] })
        digest = Result.digest(proposal_value(base, input, expected.fetch(:expected_sha)))
        boundary(*boundary_arguments(expected), proposal_digest: digest) do |_plan, previous|
          next complete(previous) if previous
          proposal = propose(selections: [ "qa=off" ], reason: reason, checks: checks, **expected)
          accept(proposal_digest: proposal.fetch("proposal_digest"), **expected)
        end
      end

      def risk_accept(result_digest:, finding_ids:, reason:, **expected)
        Admission.authorize_operator!
        boundary(*boundary_arguments(expected)) do |plan|
          results = ResultStore.new(@task.folder)
          original = results.history.find { |digest, _| digest == result_digest }&.last
          binding = original && plan.data.fetch("bindings").find { |entry| entry["id"] == original.data["capability_id"] }
          check = binding && binding.fetch("checks").find { |entry| entry["id"] == original.data["check_id"] }
          current = check && results.current(binding: binding, check: check, plan: plan, sha: sha, environment: Verification.environment(plan: plan))
          unless check && current["state"] == "failed" && current["result_digest"] == result_digest && original.state == "failed" && original.data["capability_id"] == "security" && original.data["evaluated_sha"] == sha &&
              original.data["check_digest"] == Result.check_digest(binding, check)
            invalid!("risk acceptance requires actual current failed security findings; restore unavailable routes or archive/cancel without finalization")
          end
          digest = results.record_disposition!(result_digest: result_digest, finding_ids: finding_ids, reference: Hive::SecretPatterns.redact(reason))
          record({ "status" => "risk-accepted", "execution_plan_digest" => plan.digest, "version" => plan.version,
            "result_digest" => digest, "reason" => Hive::SecretPatterns.redact(reason) }, correlation: digest, source: "operator")
          { "status" => "risk-accepted", "result_digest" => digest, "execution_plan_digest" => plan.digest, "version" => plan.version }
        end
      end

      # Planning and changed-path observations create an inert proposal while
      # their parent still owns the work. Admission applies it after terminal publication.
      def propose_from_signals!
        plan = @store.current
        return unless plan && !read_only_reason && plan.data.fetch("choices").dig("ui", "effective") != "on"
        input = { "selections" => [ "ui=automatic" ], "verification_plans" => {}, "approval_references" => [], "checks" => [] }
        return unless automatic?(input, plan)
        propose(selections: [ "ui=automatic" ], reason: "captured UI policy matched planning or diff signals", expected_identity: plan.data.fetch("task"), expected_version: plan.version, expected_sha: sha)
      end

      # Called by pre-attempt admission, never from a proposing agent's CLI.
      def activate_pending!
        return if Hive::Attempts::Context.operator_context?
        plan = @store.current
        return unless plan && !read_only_reason
        proposals.each do |digest, proposal|
          next if decision(digest) || proposal["base_digest"] != plan.digest || !automatic?(proposal.fetch("input"), plan)
          boundary(plan.data.fetch("task"), plan.version, proposal.fetch("expected_sha")) do |current|
            validate_proposal!(proposal, current, proposal.fetch("expected_sha"))
            revised, approvals = candidate(current, proposal.fetch("input"))
            publish(current, revised, approvals, digest, "accepted", "stage_service", "pinned automatic selection policy")
          end
          break
        end
      end

      def pending_guidance(plan = @store.current)
        return [] unless plan
        delivered = @store.blobs("approval").map(&:last).select { |entry| entry["record_type"] == "guidance-delivery" && entry["execution_plan_digest"] == plan.digest }
        plan.data.fetch("choices").flat_map do |id, choice|
          Array(choice["replay_stages"]).reject { |stage| delivered.any? { |entry| entry["capability"] == id && entry["stage"] == stage } }
        end.uniq
      end

      def record_guidance!(stage:, plan_digest:)
        plan = @store.current
        invalid!("guidance plan changed during execution") unless plan&.digest == plan_digest
        return unless plan.data.fetch("choices").any? { |_id, choice| Array(choice["replay_stages"]).include?(stage) }
        context = Hive::Attempts::Context.current
        raise Admission::Error, "guidance delivery requires its owning attempt" unless context
        plan.data.fetch("choices").each do |id, choice|
          next unless Array(choice["replay_stages"]).include?(stage)
          @store.accept_blob("approval", { "schema_version" => 1, "record_type" => "guidance-delivery", "task" => plan.data.fetch("task"),
            "execution_plan_digest" => plan.digest, "capability" => id, "stage" => stage, "attempt_id" => context.attempt_id })
        end
      end

      private

      def proposal_value(plan, input, expected_sha)
        { "schema_version" => 1, "task" => plan.data.fetch("task"), "base_digest" => plan.digest,
          "expected_version" => plan.version, "expected_sha" => expected_sha, "input" => input }
      end

      def boundary_arguments(value) = value.values_at(:expected_identity, :expected_version, :expected_sha)
      def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)
      def invalid!(message) = raise(Admission::Error.new(message, reason: "task_capability_policy_conflict"))
      def stale!(message) = raise(Admission::Error.new(message, reason: "task_capability_stale_revision"))

      def worktree
        @worktree ||= (@task.worktree_path if @task.respond_to?(:worktree_path)) || @task.project_root
      end

      def sha
        read = Hive::AgentGitGate.read(worktree, :head_oid)
        stale!("implementation Git revision is unavailable") unless read.success?
        read.stdout.strip
      rescue Hive::AgentGitGate::Error => error
        stale!("implementation Git revision is unavailable: #{error.message}")
      end

      def read_only_reason
        return "retained terminal task is read-only; inspect its immutable history" if @task.respond_to?(:stage_index) && @task.stage_index == @task.workflow.stages.last.index
        return "closed or cancelled task is read-only; inspect its immutable history" if ResultStore.new(@task.folder).terminal_history.any?
        nil
      end

      def observe!(identity, version, expected_sha)
        unavailable = read_only_reason
        stale!(unavailable) if unavailable
        plan = @store.current
        actual = Hive::WorkflowPackage::CanonicalJSON.normalize(Hive::TaskMeta.stable_identity(Hive::TaskMeta.read(@task.folder)))
        unless plan && actual == identity && plan.data.fetch("task") == identity && @task.id.to_s == identity["id"].to_s &&
            @task.slug == identity["slug"] && plan.version == version && sha == expected_sha
          stale!("task identity, execution-plan version or Git revision changed; refresh before accepting")
        end
        plan
      end

      def boundary(identity, version, expected_sha, proposal_digest: nil)
        Hive::TaskMeta.with_observation(@task.folder, nil) do |observation|
          Hive::Lock.with_task_lock(@task.folder, create: false, observation: observation, operation: "task-capabilities-revision") do
            if Hive::Attempts::Repository.open_default(create_directories: false).live_attempt_for(task_id: @task.id.to_s)
              raise Admission::Error.new("task still has an owning attempt; wait for terminal publication before accepting", reason: "task_capability_running_attempt")
            end
            previous = proposal_digest && decision(proposal_digest)
            if previous
              unavailable = read_only_reason
              stale!(unavailable) if unavailable
              current = @store.current
              stale!("accepted revision is no longer current") unless current.data.fetch("task") == identity && sha == expected_sha && previous["evaluated_sha"] == expected_sha &&
                @store.read_plan(previous.fetch("base_digest")).version == version &&
                (current.digest == accepted_plan(previous)&.digest || current.digest == previous["base_digest"])
              yield current, previous
            else
              yield observe!(identity, version, expected_sha), nil
            end
          end
        end
      end

      def proposal_directory
        path = File.join(@task.folder, PROPOSALS)
        invalid!("capability proposal directory must not be a symlink") if File.symlink?(path)
        path
      end

      def proposals
        Dir.glob(File.join(proposal_directory, "*.json")).sort.map { |path| [ File.basename(path, ".json"), read_proposal(File.basename(path, ".json")) ] }
      end

      def read_proposal(digest)
        invalid!("invalid capability proposal reference") unless Plan::DIGEST.match?(digest.to_s)
        path = File.join(proposal_directory, "#{digest}.json")
        invalid!("capability proposal must be a regular file") unless File.file?(path) && !File.symlink?(path)
        value = JSON.parse(File.binread(path))
        invalid!("capability proposal identity changed") unless Result.digest(value) == digest && value.keys.sort == %w[base_digest expected_sha expected_version input schema_version task] &&
          value["schema_version"] == 1 && value["input"].is_a?(Hash) && value["input"].keys.sort == INPUTS.sort
        value
      rescue JSON::ParserError
        invalid!("invalid capability proposal JSON")
      end

      def validate_proposal!(proposal, plan, expected_sha)
        unless proposal.values_at("task", "base_digest", "expected_version", "expected_sha") == [ plan.data.fetch("task"), plan.digest, plan.version, expected_sha ]
          stale!("proposal targets an older task, plan or Git revision")
        end
      end

      def decision(digest)
        @store.blobs("approval").map(&:last).find { |entry| entry["record_type"] == "revision-decision" && entry["proposal_digest"] == digest }
      end

      def publish(before, revised, approvals, proposal_digest, status, source, reason)
        receipt = Plan.redact({ "schema_version" => 1, "record_type" => "revision-decision", "task" => before.data.fetch("task"),
          "proposal_digest" => proposal_digest, "base_digest" => before.digest, "status" => status, "source" => source,
          "reason" => reason, "evaluated_sha" => sha, "plan" => revised&.to_h, "version" => revised&.version || before.version, "audit" => audit_identity })
        digest = Result.digest(receipt)
        if revised
          revised = Plan.new(revised.to_h.merge("approvals" => revised.data.fetch("approvals") + [ { "digest" => digest } ]))
          @store.activate(revised, expected_version: before.version, approvals: approvals + [ receipt ])
        else
          @store.accept_blob("approval", receipt)
        end
        complete(receipt)
      end

      def accepted_plan(receipt)
        Plan.new(receipt.fetch("plan").merge("approvals" => receipt.fetch("plan").fetch("approvals") + [ { "digest" => Result.digest(receipt) } ])) if receipt["plan"]
      end

      def complete(receipt)
        revised = accepted_plan(receipt)
        @store.activate(revised, expected_version: revised.version - 1) if revised && @store.current.digest != revised.digest
        payload = receipt.slice("status", "proposal_digest", "version", "reason").merge("execution_plan_digest" => @store.current.digest)
        record(payload, correlation: receipt.fetch("proposal_digest"), source: receipt.fetch("source"), audit: receipt.fetch("audit"))
        payload
      end

      def audit_identity
        projection = Hive::TaskProjection::Reader.new(task_folder: @task.folder, task: @task).read.to_h
        { "stage" => "#{@task.stage_index}-#{@task.stage_name}", "task_generation" => projection.dig("identity", "task_generation") || 0,
          "commit_generation" => projection.dig("identity", "commit_generation") }
      end

      def record(payload, correlation:, source:, audit: nil)
        unless audit
          existing = Hive::TaskProjection.read_journal(File.join(@task.folder, Hive::TaskJournal::JOURNAL_BASENAME)).reverse.find do |entry|
            entry.dig("payload", "idempotency_key") == "capability-revision:#{correlation}"
          end
          audit = existing&.slice("stage", "task_generation", "commit_generation") || audit_identity
        end
        Hive::TaskJournal::Writer.new(task_folder: @task.folder).append_idempotent({
          "event_type" => "activity_recorded", "task" => @store.current.data.fetch("task").slice("id", "slug"),
          "workflow" => @task.workflow.id.to_s, "stage" => audit.fetch("stage"),
          "attempt_id" => "capability-controller", "task_generation" => audit.fetch("task_generation"),
          "commit_generation" => audit.fetch("commit_generation"), "reason" => "execution-plan #{payload.fetch('status')}",
          "provenance" => { "source" => source }, "payload" => Plan.redact(payload).merge("activity_kind" => "capability_revision", "operation_id" => "capability-revision:#{correlation}")
        }, idempotency_key: "capability-revision:#{correlation}")
      end

      def automatic?(input, plan)
        return false unless input.fetch("selections") == [ "ui=automatic" ] && input.fetch("verification_plans").empty? && input.fetch("approval_references").empty? && input.fetch("task_approvals", []).empty? && input.fetch("checks").empty?
        templates = plan.data.dig("policy", "catalog_bindings") || []
        return false unless templates.any? { |entry| entry["id"] == "ui" } && templates.select { |entry| entry["id"] == "ui" }.all? { |entry| entry["available"] == true }
        catalog = Catalog.from_snapshot(workflow: @task.workflow, definitions: plan.data.fetch("definitions"))
        policy = Policy.new(plan.data.dig("policy", "policy") || {}, catalog: catalog)
        text = %w[task.md plan.md].filter_map do |name|
          path = File.join(@task.folder, name)
          File.binread(path) if File.file?(path)
        end.join("\n")
        paths, _error, status = Open3.capture3("git", "-C", worktree, "ls-files", "-z")
        delta = Result.task_delta(worktree, sha: sha)
        matches = policy.matches(task_text: text, repository_paths: status.success? ? paths.split("\0") : [], changed_paths: delta ? delta.fetch("base_blobs").keys : [])
        policy.required?("ui") || matches.any? { |match| match["capability"] == "ui" }
      end

      def verify_captured_actor!(binding)
        cfg = Hive::Config.load(@task.project_root)
        actor = binding.fetch("actor")
        profile = Hive::AgentProfiles.lookup(actor.fetch("profile"), cfg: cfg)
        route_matches = begin
          ActorRunner.route_matches?(binding.fetch("actor_route"), Hive::ProviderRouting::Configuration.capability_route(cfg: cfg, actor: actor), actor)
        rescue Hive::ConfigError
          binding.dig("actor_route", "unavailable") == true && binding.dig("actor_route", "approved_actor") == actor
        end
        unless binding["actor_fingerprint"] == Hive::WorkflowPackage::Configuration.profile_fingerprint(profile) &&
            binding["actor_binary"] == ActorRunner.runtime_identity(profile) && route_matches
          invalid!("operator corrections cannot change the captured actor, runtime or route")
        end
        cfg
      end

      def missing_skill_updates(plan, selections)
        templates = plan.data.dig("policy", "catalog_bindings") || []
        templates.each_with_object({}) do |binding, updates|
          next unless selections[binding["id"]] == "on" && binding["skill"] && binding["actor"] && !binding["skill_identity"]
          cfg = verify_captured_actor!(binding)
          begin
            updates["#{binding.fetch('id')}:#{binding.fetch('stage')}"] = Plan.redact(Admission.skill_identity(binding, project_root: @task.project_root, cfg: cfg))
          rescue Admission::Error => error
            raise unless error.reason == "task_capability_missing_skill"
          end
        end
      end

      def candidate(plan, input, discover: false)
        catalog = Catalog.from_snapshot(workflow: @task.workflow, definitions: plan.data.fetch("definitions"))
        selections = pairs(input.fetch("selections"), catalog, choices: true)
        references = pairs(input.fetch("approval_references"), catalog)
        task_references = pairs(input.fetch("task_approvals"), catalog)
        invalid!("choose either a project or task approval for each capability") unless (references.keys & task_references.keys).empty?
        invalid!("verification plans must be a map") unless input.fetch("verification_plans").is_a?(Hash)
        data = Marshal.load(Marshal.dump(plan.to_h))
        templates = data.dig("policy", "catalog_bindings") || []
        updates = missing_skill_updates(plan, selections)
        if discover
          input["skill_updates"] = updates
        elsif updates != input.fetch("skill_updates")
          stale!("installed skill identity changed after proposal; refresh and explicitly accept its exact content")
        end
        templates.each do |binding|
          identity = updates["#{binding.fetch('id')}:#{binding.fetch('stage')}"]
          next unless identity
          binding["skill_identity"] = identity
          binding["blockers"].reject! { |entry| entry["reason"] == "task_capability_missing_skill" }
          binding["available"] = binding["blockers"].empty?
        end
        approvals = []
        selections.each do |id, value|
          current = data.fetch("choices").fetch(id)
          if id == "security" && current["effective"] == "on" && value != "on"
            invalid!("selected security cannot be removed; restore its approved route or archive/cancel without finalization")
          end
          effective = value == "automatic" ? (id == "qa" || automatic?(input, plan) ? "on" : "off") : value
          invalid!("#{id} is required by pinned policy") if effective == "off" && Array(data.dig("policy", "policy", "required")).include?(id)
          invalid!("QA Off requires the audited QA waiver action") if id == "qa" && effective == "off" && input.fetch("reason").to_s.strip.empty?
          data.fetch("inputs")[id] = value
          data.fetch("choices")[id] = current.merge("input" => value, "effective" => effective, "source" => "execution-plan-revision", "reason" => input.fetch("reason"), "state" => "pending")
          data.fetch("bindings").reject! { |binding| binding["id"] == id }
          data.fetch("blockers").reject! { |blocker| blocker["capability"] == id }
          data.fetch("waivers").reject! { |waiver| waiver["capability"] == id }
          if effective == "on"
            pinned = templates.select { |entry| entry["id"] == id }
            invalid!("#{id} has no captured execution template; current configuration cannot authorize it") if pinned.empty?
            pinned.each { |entry| data.fetch("bindings") << entry.except("available", "blockers") }
            blockers = pinned.flat_map { |entry| entry.fetch("blockers", []) }
            blockers = blockers.reject { |entry| entry["reason"] == "task_capability_policy_conflict" && entry["message"].start_with?("automatic UI selection") } if value == "on"
            data.fetch("blockers").concat(blockers)
            data.fetch("choices")[id]["replay_stages"] = catalog.fetch(id).stages if catalog.fetch(id).kind == "guidance" && current["effective"] != "on"
          end
        end
        references.each do |id, reference|
          envelope = data.dig("policy", "approvals", reference)
          invalid!("approval must be captured for the selected capability") unless envelope && envelope["capability"] == id && data.fetch("choices").dig(id, "effective") == "on"
          bindings = data.fetch("bindings").select { |entry| entry["id"] == id }
          invalid!("approval differs from the pinned executor template") unless bindings.all? { |binding| binding["approval_reference"] == reference && Approval.new(reference: reference, envelope: envelope).covers?(binding.merge("capability" => id)) }
          blob = Approval.new(reference: reference, envelope: envelope).blob(task_identity: data.fetch("task"))
          approvals << blob
          data.fetch("approvals") << { "digest" => Result.digest(blob) } unless data.fetch("approvals").include?({ "digest" => Result.digest(blob) })
        end
        task_references.each do |id, reference|
          binding = data.fetch("bindings").find { |entry| entry["id"] == id }
          invalid!("task approval requires a selected configured verifier") unless binding && catalog.fetch(id).kind == "verification"
          envelope = binding.slice("actor", "permissions", "targets", "budget_usd", "timeout_sec").merge("capability" => id)
          unless %w[actor permissions targets budget_usd timeout_sec].all? { |key| envelope.key?(key) } &&
              envelope["permissions"].is_a?(Hash) && !envelope["permissions"].key?("preset") && !envelope.fetch("targets").empty?
            invalid!("task approval requires an already captured exact actor, bounded permissions, local targets, budget and timeout")
          end
          verify_captured_actor!(binding)
          Definition.permissions(envelope.fetch("permissions"), actor: envelope.fetch("actor"), label: "task approval")
          Definition.targets(envelope.fetch("targets"), label: "task approval")
          Definition.positive(envelope.fetch("budget_usd"), label: "task approval budget")
          Definition.positive(envelope.fetch("timeout_sec"), label: "task approval timeout", integer: true)
          known = data.dig("policy", "approvals", reference)
          invalid!("approval reference already authorizes a different envelope") if known && known != envelope
          blob = Approval.new(reference: reference, envelope: envelope).blob(task_identity: data.fetch("task")).merge("source" => "task-operator")
          approvals << blob
          data.fetch("approvals") << { "digest" => Result.digest(blob) }
          data.fetch("policy")["approvals"] ||= {}
          data.fetch("policy").fetch("approvals")[reference] = envelope
          (data.fetch("bindings") + templates).select { |entry| entry["id"] == id }.each do |entry|
            entry["approval_reference"] = reference
            entry.fetch("checks").each { |check| check.fetch("runner").fetch("configuration")["approval_reference"] = reference }
            if entry["blockers"]
              entry["blockers"].reject! { |blocker| blocker["reason"] == "task_capability_approval_required" }
              entry["available"] = entry["blockers"].empty?
            end
          end
          data.fetch("blockers").reject! { |entry| entry["capability"] == id && entry["reason"] == "task_capability_approval_required" }
        end
        additions = data.fetch("bindings").select { |binding| binding["id"] == "security" && plan.data.fetch("choices").dig("security", "effective") != "on" }
        invalid!("security addition requires its pinned operator approval reference") if additions.any? && !references.key?("security") && !task_references.key?("security")
        input.fetch("verification_plans").each { |id, checks| revise_checks!(data, id, checks, catalog) }
        waive_qa!(data, plan, input) if data.fetch("inputs")["qa"] == "off" && selections.key?("qa")
        selected = data.fetch("choices").select { |_id, choice| choice["effective"] == "on" }.keys
        ordered = @task.workflow.stages.flat_map { |stage| catalog.ordered(selected, stage: stage.name).map { |definition| [ definition.id, stage.name ] } }
        data.fetch("blockers").reject! { |blocker| blocker["capability"] == "composition" }
        previews = approvals.map { |blob| blob.slice("reference", "envelope").merge("digest" => Result.digest(blob)) }
        if discover
          input["approval_previews"] = previews
        elsif input.fetch("approval_previews") != previews
          stale!("proposed operator approval identity changed; refresh before accepting")
        end
        data["bindings"].sort_by! { |binding| ordered.index([ binding.fetch("id"), binding.fetch("stage") ]) }
        data["version"] = plan.version + 1
        [ Plan.new(data), approvals ]
      end

      def pairs(values, catalog, choices: false)
        invalid!("capability inputs must be ID=VALUE strings") unless values.is_a?(Array)
        values.each_with_object({}) do |entry, output|
          invalid!("capability inputs must be unique ID=VALUE strings") unless entry.is_a?(String) && entry.count("=") == 1
          id, value = entry.split("=", 2)
          catalog.fetch(id)
          invalid!("capability input is duplicate or invalid") if output.key?(id) || value.empty? || choices && !%w[automatic on off].include?(value)
          output[id] = value
        end
      end

      def revise_checks!(data, id, raw, catalog)
        definition = catalog.fetch(id)
        binding = data.fetch("bindings").find { |entry| entry["id"] == id }
        authority = data.dig("policy", "verification_authority", id)
        invalid!("verification changes require a selected verifier and captured authority") unless binding && definition.kind == "verification" && authority
        normalized = Definition.new({ "id" => id, "kind" => "verification", "stages" => [ "review" ], "checks" => raw }, stages: @task.workflow.stages, source: "declared verification plan").checks
        if id == "security" && (binding.fetch("checks").map { |check| check.fetch("id") } - normalized.map { |check| check.fetch("id") }).any?
          invalid!("selected security checks cannot be removed")
        end
        binding["checks"] = normalized.map do |check|
          existing = binding.fetch("checks").find { |entry| entry.except("runner") == check }
          next existing if existing
          runner = Marshal.load(Marshal.dump(authority.fetch("runner")))
          if binding["actor"]
            runner.merge!("type" => "actor", "configuration" => binding.slice("actor", "actor_route", "actor_fingerprint", "permissions", "targets", "budget_usd", "timeout_sec", "approval_reference"))
          else
            scope = authority.fetch("permissions")
            command = check["command"]
            permitted = scope == "yolo" || scope.is_a?(Hash) && !scope.key?("preset") && command &&
              Hive::Scripts::WorkflowPolicyHook.command_declared?(scope, Shellwords.shellsplit(command)) && !command.match?(/[\n\r;|&`$<>]/)
            invalid!("declared command exceeds the captured stage permission envelope") unless permitted && command
            runner["type"] = "command"
          end
          runner.merge!("command" => check["command"], "provider" => check["provider"], "environment" => Verification.environment(commands: normalized.filter_map { |entry| entry["command"] }))
          check.merge("runner" => runner)
        end
        invalid!("QA requires at least one behavior check") if id == "qa" && binding.fetch("checks").none? { |check| check["kind"] == "behavior" }
        data.fetch("blockers").reject! { |entry| entry["capability"] == id && entry["reason"] == "task_capability_verification_unavailable" }
      end

      def waive_qa!(data, plan, input)
        binding = plan.data.fetch("bindings").find { |entry| entry["id"] == "qa" } || data.dig("policy", "catalog_bindings")&.find { |entry| entry["id"] == "qa" }
        invalid!("QA waiver requires its captured current checks") unless binding
        checks = binding.fetch("checks")
        ids = checks.map { |check| check.fetch("id") }
        invalid!("QA waiver must acknowledge every current check ID") unless input.fetch("checks") == [ "all" ] || input.fetch("checks").sort == ids.sort && input.fetch("checks").uniq == input.fetch("checks")
        data.fetch("waivers") << { "capability" => "qa", "reason" => input.fetch("reason"), "checks" => ids,
          "check_fingerprints" => checks.to_h { |check| [ check.fetch("id"), Result.check_digest(binding, check) ] }, "whole_gate" => ids.empty?, "state" => "waived", "source" => "operator" }
        data.fetch("choices")["qa"]["state"] = "waived"
      end
    end
  end
end
