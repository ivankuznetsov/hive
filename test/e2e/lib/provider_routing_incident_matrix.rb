require "digest"
require "fileutils"
require "stringio"
require "time"
require "hive/attempts/contracts"
require "hive/attempts/dispatcher"
require "hive/attempts/evidence_channel"
require "hive/attempts/repository"
require "hive/attempts/supervisor"
require "hive/daemon/recovery_coordinator"
require "hive/lock"
require "hive/markers"
require "hive/provider_health/attempt_observer"
require "hive/provider_health/repository"
require "hive/provider_routing"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/task_meta"

module Hive
  module E2E
    # Durable, hermetic AE2-AE8 companion to the real-process AE1 incident.
    # Every route decision crosses Dispatcher and the durable attempt ledger;
    # terminal observations are backed by immutable v4 receipts, and restart
    # cells reopen both ownership stores before making their next decision.
    class ProviderRoutingIncidentMatrix
      NOW = Time.utc(2026, 8, 11, 12)
      ACTOR = "uid:1000"
      CLAIM_CAPABILITY = "c" * 64
      FakeGeneration = Data.define(:progress_token, :task_generation)
      FakeTask = Data.define(
        :id, :slug, :folder, :state_file, :stage_index, :stage_name, :workflow
      )

      class Launcher
        attr_reader :launched

        def initialize
          @launched = {}
        end

        def preflight! = true

        def launch(record, claim_capability:)
          @launched[record.attempt_id] = claim_capability
          { "claimed" => true }
        end

        def capability(attempt_id)
          @launched.fetch(attempt_id)
        end
      end

      def initialize(root:)
        @root = File.expand_path(root)
        FileUtils.mkdir_p(@root)
      end

      def run!
        previous_leases = Hive::Lock.task_lease_repository
        half_open_restart_and_fencing!
        strict_pin_and_capacity!
        exhaustion_reuses_recovery!
        operator_and_corruption!
        implicit_and_explicit_one_route!
        true
      ensure
        @store&.database&.disconnect
        Hive::Lock.task_lease_repository = previous_leases if previous_leases
      end

      private

      def half_open_restart_and_fencing!
        start_cell("ae2-ae3")
        open_scopes(
          [
            [ provider_scope, "account_quota", 0 ],
            [ model_scope, "model_capacity", 0 ]
          ]
        )
        probe = dispatch("probe-success", policy: policy)
        assert!(probe.accepted?, "AE2 probe was not durably admitted")
        assert!(
          probe.attempt["routing"].fetch("probe_bindings").size == 2,
          "AE2 did not claim both enclosing probes"
        )

        restart_cell!
        fallback = dispatch("probe-follower", policy: policy)
        assert!(fallback.accepted?, "AE2 follower was not durably admitted after restart")
        assert!(fallback.decision.route.id == "account-b/model-b", "AE2 restart did not select B")
        assert!(
          fallback.decision.exclusions.map(&:reason).uniq == [ "half_open_probe_owned" ],
          "AE2 restart did not preserve the multi-scope probe owner"
        )
        completed = supervise(probe)
        generations = [ provider_scope, model_scope ].map do |scope|
          @health.inspect_scope(scope).generation
        end
        duplicate = @observer.observe(completed)
        assert!(duplicate == :acknowledged, "AE3 duplicate completion was not acknowledged")
        assert!(generations == [ 3, 3 ], "AE2 owning success did not close every scope")
        assert!(
          [ provider_scope, model_scope ].map { |scope| @health.inspect_scope(scope).generation } == generations,
          "AE3 duplicate completion advanced health"
        )
        finish(fallback, outcome: "succeeded")
        assert!(
          @health.evaluate_route(account_id: "account-a", model_id: "model-a", now: NOW).eligible?,
          "AE2 success did not restore configured preference"
        )

        start_cell("ae2-failure")
        open_scopes([ [ provider_scope, "account_quota", 0 ] ])
        failed_probe = dispatch("probe-failure", policy: policy)
        terminal = finish(failed_probe, outcome: "failed")
        assert!(terminal.outcome == "failed", "AE2 failed probe lost its terminal outcome")
        assert!(
          @health.inspect_scope(provider_scope).circuit.automatic_state == "open",
          "AE2 failed probe did not reopen"
        )
        assert!(@health.inspect_scope(model_scope).generation.zero?, "AE2 changed a sibling scope")

        start_cell("ae3-fenced")
        open_scopes([ [ provider_scope, "account_quota", 0 ] ])
        fenced_probe = dispatch("probe-fenced", policy: policy)
        blocked = @health.block(
          scope: provider_scope, expected_generation: 2,
          actor: ACTOR, reason: "fence the live probe"
        )
        terminal = finish(fenced_probe, outcome: "succeeded", observe: false)
        late = @health.complete_probe(
          attempt: attempt_binding(terminal),
          terminal_receipt: receipt_identity(terminal), outcome: "success"
        ).fetch(0)
        assert!(blocked.current.probe.nil?, "AE3 operator fence retained probe ownership")
        assert!(late.reason == "fenced_attempt", "AE3 late completion was not fenced")
      end

      def strict_pin_and_capacity!
        %w[
          circuit_cooldown manual_block requirements_incompatible
          half_open_probe_owned provider_concurrency_saturated
        ].each do |reason|
          start_cell("ae4-#{reason}")
          requirements = Hive::ProviderRouting::Requirements.empty
          case reason
          when "circuit_cooldown"
            open_scopes([ [ model_scope, "model_capacity", 300 ] ])
          when "manual_block"
            @health.block(
              scope: model_scope, expected_generation: 0,
              actor: ACTOR, reason: "strict pin maintenance"
            )
          when "requirements_incompatible"
            requirements = Hive::ProviderRouting::Requirements.new(tools: %w[browser])
          when "half_open_probe_owned"
            open_scopes([ [ model_scope, "model_capacity", 0 ] ])
            dispatch("strict-pin-owner", policy: policy(routes: [ routes.first ]))
          when "provider_concurrency_saturated"
            dispatch("strict-pin-capacity-owner", policy: policy(routes: [ routes.first ]))
          end

          strict_policy = policy(
            pin: Hive::ProviderRouting::Pin.new(account: "account-a", model: "model-a"),
            requirements: requirements
          )
          if reason == "requirements_incompatible"
            begin
              dispatch("strict-pin-#{reason}", policy: strict_policy)
            rescue Hive::ProviderRouting::PolicyRepository::InvalidSnapshot
              assert!(@store.active_attempts.empty?, "AE4 invalid requirements created an attempt")
              next
            end
            raise "AE4 impossible pinned requirements crossed durable policy validation"
          end

          result = dispatch("strict-pin-#{reason}", policy: strict_policy)
          pinned = result.decision.candidates.find { |candidate| candidate.route.account == "account-a" }
          outside = result.decision.candidates.find { |candidate| candidate.route.account == "account-b" }
          assert!(result.status == :no_route, "AE4 #{reason} selected outside a strict pin")
          assert!(result.reason == "no_eligible_provider_route", "AE4 #{reason} returned wrong disposition")
          expected = reason == "circuit_cooldown" ? %w[circuit_open circuit_cooldown] : [ reason ]
          actual = pinned.exclusions.map(&:reason)
          assert!(actual == expected,
                  "AE4 #{reason} lost its exact exclusion: expected #{expected.inspect}, got #{actual.inspect}")
          assert!(outside.exclusions.map(&:reason).include?("hard_pin_mismatch"), "AE4 crossed pin boundary")
          assert_decision_persisted!(result)
        end

        start_cell("ae5-capacity")
        before = all_scopes.map { |scope| @health.inspect_scope(scope).generation }
        owner_a = dispatch("capacity-owner-a", policy: policy(routes: [ routes.first ]))
        partial = dispatch("capacity-partial", policy: policy)
        total = dispatch("capacity-total", policy: policy)
        assert!(owner_a.accepted?, "AE5 did not create the durable A reservation")
        assert!(partial.attempt["routing"].dig("route", "route_id") == "account-b/model-b",
                "AE5 partial saturation did not select B")
        assert!(total.status == :deferred && total.decision.capacity_saturated?,
                "AE5 total saturation was not scheduler-owned")
        assert!(total.decision.next_action_owner == "scheduler", "AE5 total saturation owner changed")
        assert!(
          all_scopes.map { |scope| @health.inspect_scope(scope).generation } == before,
          "AE5 capacity mutated health"
        )
        assert_decision_persisted!(total)
      end

      def exhaustion_reuses_recovery!
        root = start_cell("ae6-recovery")
        task = build_task("route-exhausted")
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
          state_file_content: File.binread(task.state_file)
        )
        routes.each do |route|
          @health.block(
            scope: provider_scope(route.account), expected_generation: 0,
            actor: ACTOR, reason: "exhaust every route"
          )
        end
        routed = dispatch_task(task, policy: policy, generation: generation.task_generation)
        assert!(routed.status == :no_route, "AE6 exhaustion did not cross durable admission")
        assert_decision_persisted!(routed)
        coordinator = Hive::Daemon::RecoveryCoordinator.new(
          state_home: root,
          task_resolver: ->(**) { task },
          safety: ->(_row) { [ true, "safe" ] },
          generation_resolver: generation_resolver,
          attempt_store: @store, dispatch_repository: @dispatch_repository
        )
        request = Hive::RuntimeControlPlane::DispatchRepository::Request.new(
          request_id: "initial-route-admission", created_at: NOW,
          project: "demo", slug: task.slug,
          argv: [ "hive", "run", task.slug, "--stage", "4-execute", "--project", "demo" ],
          requestor: "daemon", trigger: "auto_advance", task_id: task.id,
          inherited_outputs: []
        )
        first = coordinator.request_admission_failure(
          request: request, decision: routed.decision, now: NOW
        )
        pending = @dispatch_repository.pending
        assert!(!pending.empty?, "AE6 recovery was not persisted: #{first.inspect}")
        persisted = pending.fetch(0)
        observed = coordinator.observe_admission_result(
          request: persisted, result: routed, now: NOW + 1
        )
        pending = @dispatch_repository.pending
        assert!(first.retry_count == 1 && observed.retry_count == 1, "AE6 charged exhaustion twice")
        assert!(pending.size == 1, "AE6 created a second recovery request")
        assert!(
          pending.fetch(0).recovery.dig("admission_observation", "reason") ==
            "no_eligible_provider_route",
          "AE6 did not update the existing recovery explanation"
        )
      end

      def operator_and_corruption!
        start_cell("ae7-operators")
        [ provider_scope, model_scope ].each do |scope|
          blocked = @health.block(
            scope: scope, expected_generation: 0,
            actor: ACTOR, reason: "planned maintenance"
          )
          unblocked = @health.unblock(
            scope: scope, expected_generation: blocked.generation,
            actor: ACTOR, reason: "maintenance complete"
          )
          reset = @health.reset(
            scope: scope, expected_generation: unblocked.generation,
            actor: ACTOR, reason: "clear stale observations"
          )
          assert!(reset.generation == 3, "AE7 operator generations did not advance exactly")
          assert!(
            [ blocked, unblocked, reset ].all?(&:audit_receipt),
            "AE7 operator mutation omitted an audit receipt"
          )
        end
        eligible = dispatch("operator-restored", policy: policy(routes: [ routes.first ]))
        assert!(eligible.accepted?, "AE7 operator reset did not restore durable admission")
      end

      def implicit_and_explicit_one_route!
        start_cell("ae8-one-route")
        @health.block(
          scope: provider_scope, expected_generation: 0,
          actor: ACTOR, reason: "exclude explicit route"
        )
        legacy_dispatcher = build_dispatcher(
          health_store: nil,
          health_store_factory: -> { raise "AE8 legacy admission touched provider health" }
        )
        legacy = dispatch(
          "legacy-one-route",
          policy: Hive::ProviderRouting::Policy.legacy(stage: "execute"),
          dispatcher: legacy_dispatcher,
          argv: [ "/bin/true" ]
        )
        assert!(legacy.accepted?, "AE8 implicit route did not create a durable attempt")
        assert!(legacy.attempt["routing"] == { "mode" => "legacy" }, "AE8 implicit route touched health")
        supervise(legacy)

        explicit = dispatch(
          "explicit-one-route",
          policy: policy(routes: [ routes.first ]),
          argv: [ "/bin/true" ]
        )
        assert!(explicit.status == :no_route, "AE8 explicit one-route pool ignored shared health")
        assert!(explicit.decision.exclusions.map(&:reason) == [ "manual_block" ],
                "AE8 explicit exclusion drifted")
        assert_decision_persisted!(explicit)
      end

      def start_cell(name)
        @cell_name = name
        @cell_root = cell(name)
        @attempt_counter = 0
        @decision_counter = 0
        @task_counter = 0
        @launcher = Launcher.new
        restart_cell!
        @cell_root
      end

      def restart_cell!
        @store&.database&.disconnect
        database = Hive::RuntimeControlPlane::Database.new(
          path: File.join(@cell_root, "runtime-control-plane.sqlite3")
        ).migrate!
        @store = Hive::Attempts::Repository.new(
          root: File.join(@cell_root, "attempts"), database: database
        )
        register_project!
        Hive::Lock.task_lease_repository = Hive::RuntimeControlPlane::TaskLeaseRepository.new(
          database: database,
          process_start_time: Hive::Lock.method(:process_start_time),
          process_alive: lambda do |pid, recorded_start_time:|
            Hive::Lock.send(
              :process_identity_alive?, pid, recorded_start_time: recorded_start_time
            )
          end
        )
        @health = Hive::ProviderHealth::Repository.new(
          database: @store.database, clock: -> { NOW }
        )
        @dispatch_repository = Hive::RuntimeControlPlane::DispatchRepository.new(
          database: @store.database
        )
        @observer = Hive::ProviderHealth::AttemptObserver.new(store: @health)
        @dispatcher = build_dispatcher
      end

      def build_dispatcher(health_store: @health, health_store_factory: nil)
        Hive::Attempts::Dispatcher.new(
          store: @store, launcher: @launcher,
          limits: { max_global: 50, max_per_project: 50, max_daily: 100 },
          clock: -> { NOW },
          id_generator: -> { next_attempt_id },
          decision_id_generator: -> { next_decision_id },
          capability_generator: -> { CLAIM_CAPABILITY },
          health_store: health_store,
          health_store_factory: health_store_factory
        )
      end

      def dispatch(slug, policy:, generation: nil, dispatcher: @dispatcher,
                   argv: [ "/bin/true" ])
        dispatch_task(
          build_task(slug), policy: policy, generation: generation,
          dispatcher: dispatcher, argv: argv
        )
      end

      def dispatch_task(task, policy:, generation: nil, dispatcher: @dispatcher,
                        argv: [ "/bin/true" ])
        generation = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute",
          progress_token: Hive::Attempts::Generation.artifact_token(task),
          task_generation: generation, task_input_epoch: 0
        )
        dispatcher.dispatch(
          task: task, project: "demo", intended_stage: "4-execute",
          argv: argv, request_id: "request-#{task.slug}", provider: "codex",
          generation: generation, routing_policy: policy, now: NOW
        )
      end

      def build_task(slug)
        @task_counter += 1
        folder = File.join(@cell_root, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        File.binwrite(state_file, "# Task\n\n<!-- WAITING -->\n")
        Hive::TaskMeta.write(
          folder, id: @task_counter, slug: slug,
          display_name: slug, workflow: "coding"
        )
        FakeTask.new(
          id: @task_counter, slug: slug, folder: folder,
          state_file: state_file, stage_index: 4, stage_name: "execute",
          workflow: "coding"
        )
      end

      def register_project!
        @store.database.transaction do |db|
          installation = db[:installations].first.fetch(:installation_id)
          db[:projects].insert_conflict.insert(
            project_id: "matrix-demo", installation_id: installation,
            registration_id: "matrix-demo", name: "demo",
            observed_path: @cell_root,
            state_root_path: File.join(@cell_root, ".hive-state"),
            active: 1, registered_at: NOW.iso8601(6),
            last_observed_at: NOW.iso8601(6)
          )
        end
      end

      def open_scopes(entries)
        setup_policy = policy(routes: [ routes.first ], max_concurrent: entries.size)
        admitted = entries.each_with_index.map do |(_scope, _failure_class, _reset), index|
          result = dispatch("open-scope-#{index}", policy: setup_policy)
          assert!(result.accepted?, "incident setup did not durably admit evidence attempt #{index}")
          result
        end
        admitted.zip(entries).each do |result, (scope, failure_class, reset)|
          terminal = finish(
            result, outcome: "failed", observe: false,
            evidence: evidence_signal(scope, failure_class, reset)
          )
          assert!(@observer.observe(terminal) == :acknowledged,
                  "incident setup could not open #{scope.key}")
        end
      end

      def finish(result, outcome:, observe: true, evidence: nil)
        record = @store.fetch_hot(result.attempt.attempt_id)
        capability = @launcher.capability(record.attempt_id)
        owner = {
          "pid" => Process.pid,
          "start_fingerprint" => Hive::Lock.process_start_time(Process.pid),
          "session_id" => Process.getsid(Process.pid),
          "process_group_id" => Process.getpgrp
        }
        running = @store.claim(
          record, owner: owner, claim_capability: capability,
          first_heartbeat_timeout_sec: 30, now: NOW
        )
        running = @store.first_heartbeat(running, stale_sec: 30, now: NOW)
        log_reference = output_reference(record.attempt_id)
        provider_evidence = Hive::Attempts::EvidenceChannel.materialize(
          evidence, record: running, source_reference: log_reference
        )
        terminal = @store.terminalize(
          running, outcome: outcome,
          exit_status: outcome == "succeeded" ? 0 : 1,
          final_checkpoint: running.checkpoint,
          output_references: running["current_outputs"],
          log_reference: log_reference,
          provider_evidence: provider_evidence,
          now: NOW + 1
        )
        @observer.observe(terminal) if observe
        terminal
      end

      def supervise(result)
        capability = @launcher.capability(result.attempt.attempt_id)
        status = Hive::Attempts::Supervisor.new(
          store: @store, attempt_id: result.attempt.attempt_id,
          claim_io: StringIO.new(capability), heartbeat_sec: 0.01,
          stale_sec: 1, first_heartbeat_timeout_sec: 1,
          clock: -> { NOW + 1 }
        ).run
        terminal = @store.fetch_hot(result.attempt.attempt_id)
        assert!(status.zero?, "durable supervisor worker failed")
        assert!(terminal&.state == "terminal", "durable supervisor did not terminalize")
        @observer.observe(terminal)
        terminal
      end

      def evidence_signal(scope, failure_class, reset_hint_seconds)
        {
          "failure_class" => failure_class,
          "scope" => scope.to_h,
          "provenance" => "provider_diagnostic",
          "reset_hint_seconds" => reset_hint_seconds
        }
      end

      def output_reference(attempt_id)
        {
          "path" => "logs/#{attempt_id}.frames",
          "size" => 0,
          "sha256" => Digest::SHA256.hexdigest("")
        }
      end

      def attempt_binding(record)
        route = record["routing"].fetch("route")
        Hive::ProviderHealth::AttemptBinding.new(
          attempt_id: record.attempt_id,
          task_generation: record.task_generation,
          ownership_fence: record.ownership_generation,
          route: Hive::ProviderHealth::RouteIdentity.new(
            route_id: route.fetch("route_id"),
            account_id: route.fetch("provider_account_id"),
            adapter: route.fetch("adapter"),
            launch_binding_id: route.fetch("launch_binding_id"),
            model_id: route.fetch("model")
          ),
          probe_bindings: record["routing"].fetch("probe_bindings").map do |binding|
            Hive::ProviderHealth::ProbeBinding.new(
              scope: Hive::ProviderHealth.scope_from_h(binding.fetch("scope")),
              journal_epoch: binding.fetch("journal_epoch"),
              observed_generation: binding.fetch("observed_generation"),
              claim_generation: binding.fetch("claim_generation"),
              attempt_id: binding.fetch("attempt_id"),
              task_generation: binding.fetch("task_generation"),
              ownership_fence: binding.fetch("ownership_fence")
            )
          end
        )
      end

      def receipt_identity(record)
        {
          "attempt_id" => record.receipt.fetch("attempt_id"),
          "receipt_version" => record.receipt.fetch("receipt_version"),
          "terminal_lease_version" => record.receipt.fetch("terminal_lease_version")
        }
      end

      def assert_decision_persisted!(result)
        persisted = @store.routing_decisions.find do |entry|
          entry.fetch("decision").fetch("decision_id") == result.decision.decision_id
        end&.fetch("decision")
        assert!(persisted == result.decision.to_h, "routing decision was not durably indexed")
      end

      def policy(routes: self.routes, accounts: nil, pin: nil,
                 requirements: Hive::ProviderRouting::Requirements.empty,
                 max_concurrent: 1)
        accounts ||= routes.map(&:account).uniq
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
                "max_concurrent" => max_concurrent,
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

      def provider_scope(account = "account-a")
        Hive::ProviderHealth::Scope.provider_account(account_id: account)
      end

      def model_scope(account = "account-a", model = "model-a")
        Hive::ProviderHealth::Scope.model(account_id: account, model_id: model)
      end

      def all_scopes
        routes.flat_map do |route|
          [ provider_scope(route.account), model_scope(route.account, route.model) ]
        end
      end

      def next_attempt_id
        @attempt_counter += 1
        "#{@cell_name}-attempt-#{@attempt_counter}"
      end

      def next_decision_id
        @decision_counter += 1
        "#{@cell_name}-decision-#{@decision_counter}"
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
