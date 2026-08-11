require "digest"
require "fileutils"
require "time"
require "hive/attempts/contracts"
require "hive/daemon/dispatch_request_queue"
require "hive/daemon/recovery_coordinator"
require "hive/markers"
require "hive/provider_health/store"
require "hive/provider_routing/router"

module Hive
  module E2E
    # Durable, hermetic AE2-AE8 companion to the real-process AE1 incident.
    # Each assertion raises into the scenario runner so the ordinary E2E
    # forensic bundle captures the exact durable state on failure.
    class ProviderRoutingIncidentMatrix
      NOW = Time.utc(2026, 8, 11, 12)
      Actor = "uid:1000"
      FakeGeneration = Data.define(:progress_token, :task_generation)
      FakeTask = Data.define(:id, :slug, :folder, :state_file, :stage_index, :stage_name)

      def initialize(root:)
        @root = File.expand_path(root)
        FileUtils.mkdir_p(@root)
      end

      def run!
        half_open_restart_and_fencing!
        strict_pin_and_capacity!
        exhaustion_reuses_recovery!
        operator_and_corruption!
        implicit_and_explicit_one_route!
        true
      end

      private

      def half_open_restart_and_fencing!
        attempts = {}
        root = cell("ae2-ae3")
        store = health_store(root, attempts)
        open_scope(store, attempts, provider_scope, "account_quota", "provider-open", reset: 0)
        open_scope(store, attempts, model_scope, "model_capacity", "model-open", reset: 0)
        evaluation = store.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW)
        assert!(evaluation.probe_requirements.size == 2, "AE2 did not require both enclosing probes")

        owner = claim_probe(store, attempts, evaluation, "probe-success")
        restarted = health_store(root, attempts)
        blocked = restarted.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW)
        assert!(
          blocked.blockers.map { |entry| entry.fetch("reason") } ==
            %w[half_open_probe_owned half_open_probe_owned],
          "AE2 restart did not preserve the multi-scope probe owner"
        )
        completed = restarted.complete_probe(
          attempt: owner, terminal_receipt: receipt(owner.attempt_id), outcome: "success"
        )
        duplicate = restarted.complete_probe(
          attempt: owner, terminal_receipt: receipt(owner.attempt_id), outcome: "success"
        )
        assert!(completed.all?(&:accepted?), "AE2 owning success did not close every scope")
        assert!(duplicate.all?(&:duplicate?), "AE3 duplicate completion advanced health")
        assert!(
          [ provider_scope, model_scope ].map { |scope| restarted.inspect_scope(scope).generation } == [ 3, 3 ],
          "AE3 restart/duplicate generations diverged"
        )
        assert!(
          restarted.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW).eligible?,
          "AE2 success did not restore configured preference"
        )

        failure_attempts = {}
        failure = health_store(cell("ae2-failure"), failure_attempts)
        open_scope(failure, failure_attempts, provider_scope, "account_quota", "failure-open", reset: 0)
        failure_owner = claim_probe(
          failure,
          failure_attempts,
          failure.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW),
          "probe-failure"
        )
        failed = failure.complete_probe(
          attempt: failure_owner,
          terminal_receipt: receipt(failure_owner.attempt_id),
          outcome: "failure"
        ).fetch(0)
        assert!(failed.current.automatic_state == "open", "AE2 failed probe did not reopen")
        assert!(failure.inspect_scope(model_scope).generation.zero?, "AE2 changed a sibling scope")

        fenced_attempts = {}
        fenced = health_store(cell("ae3-fenced"), fenced_attempts)
        open_scope(fenced, fenced_attempts, provider_scope, "account_quota", "fenced-open", reset: 0)
        fenced_owner = claim_probe(
          fenced,
          fenced_attempts,
          fenced.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW),
          "probe-fenced"
        )
        blocked_result = fenced.block(
          scope: provider_scope, expected_generation: 2,
          actor: Actor, reason: "fence the live probe"
        )
        late = fenced.complete_probe(
          attempt: fenced_owner,
          terminal_receipt: receipt(fenced_owner.attempt_id),
          outcome: "success"
        ).fetch(0)
        assert!(blocked_result.current.probe.nil?, "AE3 operator fence retained probe ownership")
        assert!(late.reason == "fenced_attempt", "AE3 late completion was not fenced")
      end

      def strict_pin_and_capacity!
        %w[
          circuit_cooldown manual_block requirements_incompatible
          half_open_probe_owned provider_concurrency_saturated
        ].each do |reason|
          attempts = {}
          store = health_store(cell("ae4-#{reason}"), attempts)
          requirements = Hive::ProviderRouting::Requirements.empty
          capacity = capacity_snapshot
          case reason
          when "circuit_cooldown"
            open_scope(store, attempts, model_scope, "model_capacity", "pin-open", reset: 300)
          when "manual_block"
            store.block(
              scope: model_scope, expected_generation: 0,
              actor: Actor, reason: "strict pin maintenance"
            )
          when "requirements_incompatible"
            requirements = Hive::ProviderRouting::Requirements.new(tools: %w[browser])
          when "half_open_probe_owned"
            open_scope(store, attempts, model_scope, "model_capacity", "pin-probe", reset: 0)
            claim_probe(
              store,
              attempts,
              store.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW),
              "strict-pin-owner"
            )
          when "provider_concurrency_saturated"
            capacity = capacity_snapshot("account-a" => 1)
          end

          decision = decide(
            store: store,
            policy: policy(
              pin: Hive::ProviderRouting::Pin.new(account: "account-a", model: "model-a"),
              requirements: requirements
            ),
            decision_id: "ae4-#{reason}",
            capacity: capacity
          )
          pinned = decision.candidates.find { |candidate| candidate.route.account == "account-a" }
          outside = decision.candidates.find { |candidate| candidate.route.account == "account-b" }
          assert!(!decision.selected?, "AE4 #{reason} selected outside a strict pin")
          assert!(decision.reason == "no_eligible_provider_route", "AE4 #{reason} returned wrong disposition")
          assert!(pinned.exclusions.map(&:reason) == [ reason ], "AE4 #{reason} lost its exact exclusion")
          assert!(outside.exclusions.map(&:reason).include?("hard_pin_mismatch"), "AE4 crossed pin boundary")
        end

        store = health_store(cell("ae5-capacity"), {})
        before = all_scopes.map { |scope| store.inspect_scope(scope).generation }
        partial = decide(
          store: store, policy: policy, decision_id: "ae5-partial",
          capacity: capacity_snapshot("account-a" => 1)
        )
        total = decide(
          store: store, policy: policy, decision_id: "ae5-total",
          capacity: capacity_snapshot("account-a" => 1, "account-b" => 1)
        )
        assert!(partial.route.id == "account-b/model-b", "AE5 partial saturation did not select B")
        assert!(total.capacity_saturated?, "AE5 total saturation was not scheduler-owned")
        assert!(total.next_action_owner == "scheduler", "AE5 total saturation owner changed")
        assert!(
          all_scopes.map { |scope| store.inspect_scope(scope).generation } == before,
          "AE5 capacity mutated health"
        )
      end

      def exhaustion_reuses_recovery!
        root = cell("ae6-recovery")
        folder = File.join(root, "task")
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        File.binwrite(state_file, "# Task\n\n<!-- WAITING -->\n")
        task = FakeTask.new(
          id: 817, slug: "route-exhausted", folder: folder,
          state_file: state_file, stage_index: 4, stage_name: "execute"
        )
        generation_resolver = lambda do |resolved, project:, intended_stage:, state_file_content:|
          progress = Digest::SHA256.hexdigest([ resolved.state_file, state_file_content ].join("\0"))
          FakeGeneration.new(
            progress_token: progress,
            task_generation: Digest::SHA256.hexdigest(
              [ project, intended_stage, progress ].join("\0")
            )
          )
        end
        generation = generation_resolver.call(
          task, project: "demo", intended_stage: "4-execute",
          state_file_content: File.binread(state_file)
        )
        attempts = {}
        health = health_store(File.join(root, "health"), attempts)
        routes.each do |route|
          health.block(
            scope: provider_scope(route.account), expected_generation: 0,
            actor: Actor, reason: "exhaust every route"
          )
        end
        decision = decide(
          store: health,
          policy: policy,
          decision_id: "ae6-exhausted",
          capacity: capacity_snapshot,
          task_generation: generation.task_generation
        )
        coordinator = Hive::Daemon::RecoveryCoordinator.new(
          state_home: root,
          task_resolver: ->(**) { task },
          safety: ->(_row) { [ true, "safe" ] },
          generation_resolver: generation_resolver
        )
        request = Hive::Daemon::DispatchRequestQueue::Request.new(
          request_id: "initial-route-admission", created_at: NOW,
          project: "demo", slug: task.slug,
          argv: [ "hive", "run", task.slug, "--stage", "4-execute", "--project", "demo" ],
          requestor: "daemon", trigger: "auto_advance", task_id: task.id,
          inherited_outputs: []
        )
        first = coordinator.request_admission_failure(request: request, decision: decision, now: NOW)
        persisted = Hive::Daemon::DispatchRequestQueue.pending(state_home: root).fetch(0)
        result = Hive::Attempts::DispatchResult.new(
          status: :no_route, attempt: nil, receipt: nil, attach_descriptor: nil,
          reason: decision.reason, decision: decision
        )
        observed = coordinator.observe_admission_result(
          request: persisted, result: result, now: NOW + 1
        )
        pending = Hive::Daemon::DispatchRequestQueue.pending(state_home: root)
        assert!(first.retry_count == 1 && observed.retry_count == 1, "AE6 charged exhaustion twice")
        assert!(pending.size == 1, "AE6 created a second recovery request")
        assert!(
          pending.fetch(0).recovery.dig("admission_observation", "reason") ==
            "no_eligible_provider_route",
          "AE6 did not update the existing recovery explanation"
        )
      end

      def operator_and_corruption!
        store = health_store(cell("ae7-operators"), {})
        [ provider_scope, model_scope ].each do |scope|
          blocked = store.block(
            scope: scope, expected_generation: 0,
            actor: Actor, reason: "planned maintenance"
          )
          unblocked = store.unblock(
            scope: scope, expected_generation: blocked.generation,
            actor: Actor, reason: "maintenance complete"
          )
          reset = store.reset(
            scope: scope, expected_generation: unblocked.generation,
            actor: Actor, reason: "clear stale observations"
          )
          assert!(reset.generation == 3, "AE7 operator generations did not advance exactly")
          assert!(
            [ blocked, unblocked, reset ].all? { |entry| entry.audit_receipt },
            "AE7 operator mutation omitted an audit receipt"
          )
        end

        corrupt = health_store(cell("ae7-corruption"), {})
        blocked = corrupt.block(
          scope: provider_scope, expected_generation: 0,
          actor: Actor, reason: "preserve this block"
        )
        journal = corrupt.send(:journal_path, provider_scope)
        path = File.join(corrupt.root, journal)
        File.binwrite(path, File.binread(path) + "corrupt-interior\n")
        unavailable = corrupt.inspect_scope(provider_scope)
        repaired = corrupt.reset(
          scope: provider_scope, corruption_token: unavailable.corruption_token,
          actor: Actor, reason: "repair corrupt health scope"
        )
        assert!(unavailable.unavailable?, "AE7 corruption did not fail closed")
        assert!(repaired.generation == blocked.generation + 1, "AE7 repair lost verified generation")
        assert!(repaired.current.blocked?, "AE7 repair lost the verified manual block")
      end

      def implicit_and_explicit_one_route!
        store = health_store(cell("ae8-one-route"), {})
        store.block(
          scope: provider_scope, expected_generation: 0,
          actor: Actor, reason: "exclude explicit route"
        )
        legacy = Hive::ProviderRouting::Router.new.call(
          request: Hive::ProviderRouting::Request.new(
            policy: Hive::ProviderRouting::Policy.legacy(stage: "execute"),
            task_generation: "legacy-generation"
          )
        )
        explicit = decide(
          store: store,
          policy: policy(routes: [ routes.first ], accounts: [ "account-a" ]),
          decision_id: "ae8-explicit-one",
          capacity: capacity_snapshot
        )
        assert!(legacy.legacy? && legacy.reason == "legacy_bypass", "AE8 implicit route touched health")
        assert!(!explicit.selected?, "AE8 explicit one-route pool ignored shared health")
        assert!(explicit.exclusions.map(&:reason) == [ "manual_block" ], "AE8 explicit exclusion drifted")
      end

      def claim_probe(store, attempts, evaluation, attempt_id)
        intent = Hive::ProviderHealth::ProbeIntent.new(
          intent_id: "intent-#{attempt_id}", attempt_id: attempt_id,
          task_generation: "generation-1", ownership_fence: "fence-1",
          requirements: evaluation.probe_requirements
        )
        owner = nil
        store.with_probe_intent(intent: intent) do |bindings|
          owner = Hive::ProviderHealth::AttemptBinding.new(
            attempt_id: attempt_id, task_generation: intent.task_generation,
            ownership_fence: intent.ownership_fence, route: route_identity("account-a"),
            probe_bindings: bindings
          )
          attempts[attempt_id] = owner
        end
        owner
      end

      def open_scope(store, attempts, scope, failure_class, attempt_id, reset:)
        attempt = Hive::ProviderHealth::AttemptBinding.new(
          attempt_id: attempt_id, task_generation: "generation-1",
          ownership_fence: "fence-1", route: route_identity(scope.account_id)
        )
        attempts[attempt_id] = attempt
        evidence = Hive::ProviderHealth::Evidence.new(
          scope: scope, failure_class: failure_class,
          provenance: "provider_diagnostic", route: attempt.route,
          reset_hint_seconds: reset,
          source_reference: {
            "path" => "logs/#{attempt_id}.frames", "size" => 0,
            "sha256" => Digest::SHA256.hexdigest("")
          },
          attempt_id: attempt_id
        )
        result = store.apply_evidence(
          evidence: evidence, attempt: attempt,
          terminal_receipt: receipt(attempt_id), expected_generation: 0
        )
        assert!(result.accepted?, "incident setup could not open #{scope.key}")
      end

      def decide(store:, policy:, decision_id:, capacity:, task_generation: "generation-1")
        health = policy.routes.to_h do |route|
          [
            route.id,
            store.evaluate_route(account_id: route.account, model_id: route.model, now: NOW)
          ]
        end
        Hive::ProviderRouting::Router.new.call(
          request: Hive::ProviderRouting::Request.new(
            policy: policy, task_generation: task_generation,
            health: health, capacity: capacity
          ),
          decision_id: decision_id,
          decided_at: NOW
        )
      end

      def policy(routes: self.routes, accounts: %w[account-a account-b], pin: nil,
                 requirements: Hive::ProviderRouting::Requirements.empty)
        Hive::ProviderRouting::Policy.explicit(
          stage: "execute", routes: routes, requirements: requirements, pin: pin,
          account_policy: accounts.to_h do |account|
            route = self.routes.find { |candidate| candidate.account == account }
            [
              account,
              {
                "adapter" => route.adapter,
                "launch_binding" => route.launch_binding,
                "models" => [ route.model ],
                "max_concurrent" => 1,
                "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
              }
            ]
          end
        )
      end

      def routes
        @routes ||= [
          route("account-a", "model-a", "codex", "binding-a", 0),
          route("account-b", "model-b", "claude", "binding-b", 1)
        ].freeze
      end

      def route(account, model, adapter, binding, order)
        Hive::ProviderRouting::Route.new(
          id: "#{account}/#{model}", account: account, adapter: adapter,
          launch_binding: binding, model: model, effort: "high", order: order,
          capabilities: {
            "context" => "large", "quality" => "high",
            "tools" => %w[shell], "permissions" => %w[read]
          }
        )
      end

      def route_identity(account)
        route = routes.find { |candidate| candidate.account == account }
        Hive::ProviderHealth::RouteIdentity.new(
          route_id: route.id, account_id: route.account, adapter: route.adapter,
          launch_binding_id: route.launch_binding, model_id: route.model
        )
      end

      def health_store(root, attempts)
        Hive::ProviderHealth::Store.new(
          root: root, clock: -> { NOW },
          attempt_reader: ->(attempt_id) { attempts[attempt_id] }
        )
      end

      def capacity_snapshot(overrides = {})
        { "account-a" => 0, "account-b" => 0 }.merge(overrides).to_h do |account, observed|
          [ account, { "observed" => observed, "max" => 1 } ]
        end
      end

      def provider_scope(account = "account-a")
        Hive::ProviderHealth::Scope.provider_account(account_id: account)
      end

      def model_scope(account = "account-a", model = "model-a")
        Hive::ProviderHealth::Scope.model(account_id: account, model_id: model)
      end

      def all_scopes
        routes.flat_map { |route| [ provider_scope(route.account), model_scope(route.account, route.model) ] }
      end

      def receipt(attempt_id)
        {
          "attempt_id" => attempt_id,
          "receipt_version" => 1,
          "terminal_lease_version" => 2
        }
      end

      def cell(name)
        path = File.join(@root, name)
        FileUtils.mkdir_p(path)
        path
      end

      def assert!(condition, message)
        raise message unless condition
      end
    end
  end
end
