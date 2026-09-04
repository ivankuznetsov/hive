require "digest"
require "fileutils"
require "time"
require "hive/attempts/dispatcher"
require "hive/attempts/evidence_channel"
require "hive/attempts/repository"
require "hive/provider_routing"
require "hive/runtime_control_plane"

module Hive
  module E2E
    # Hermetic stateless-routing matrix. Every selection crosses the durable
    # admission boundary, while provider failure history survives only as the
    # failed route on the immediate retry handoff.
    class ProviderRoutingIncidentMatrix
      NOW = Time.utc(2026, 8, 11, 12)
      CLAIM_CAPABILITY = "c" * 64
      FakeTask = Data.define(
        :id, :slug, :folder, :state_file, :stage_index, :stage_name, :workflow
      )

      class Launcher
        attr_reader :capabilities

        def initialize
          @capabilities = {}
        end

        def preflight! = true

        def launch(record, claim_capability:)
          capabilities[record.attempt_id] = claim_capability
          { "claimed" => true }
        end
      end

      class RetryAdmissionView
        def initialize(store)
          @view = Hive::Attempts::AdmissionView.new(
            store: store, records: store.active_attempts
          )
        end

        def successor(**) = nil

        def method_missing(name, *args, **kwargs, &block)
          return super unless @view.respond_to?(name)

          @view.public_send(name, *args, **kwargs, &block)
        end

        def respond_to_missing?(name, include_private = false)
          @view.respond_to?(name, include_private) || super
        end
      end

      def initialize(root:)
        @root = File.expand_path(root)
        FileUtils.mkdir_p(@root)
      end

      def run!
        ordered_rotation!
        current_configuration!
        pin_and_capacity!
        true
      ensure
        @store&.database&.disconnect
      end

      private

      def ordered_rotation!
        start_cell("ordered-rotation")
        task = build_task("rotate")
        first = dispatch(task, request_id: "initial", policy: policy)
        failed_a = fail_attempt(first)
        second = retry_after(failed_a, task, request_id: "retry-b", policy: policy)
        failed_b = fail_attempt(second)
        third = retry_after(failed_b, task, request_id: "retry-a", policy: policy)

        assert!(first.decision.route.id == "account-a/model-a", "new work did not start at A")
        assert!(second.decision.route.id == "account-b/model-b", "failure from A did not rotate to B")
        assert!(third.decision.route.id == "account-a/model-a", "failure from B did not wrap to A")
      end

      def current_configuration!
        start_cell("current-configuration")
        failed_task = build_task("failed")
        failed = fail_attempt(
          dispatch(failed_task, request_id: "before-change", policy: policy)
        )
        current = policy(routes: [ routes.fetch(1).with(order: 0) ])
        retry_result = retry_after(
          failed, failed_task, request_id: "after-change", policy: current
        )
        unrelated = dispatch(
          build_task("unrelated"), request_id: "unrelated", policy: policy
        )

        assert!(retry_result.decision.route.id == "account-b/model-b",
                "removed failed route did not restart at the first current route")
        assert!(unrelated.decision.route.id == "account-a/model-a",
                "prior failure affected unrelated work")
      end

      def pin_and_capacity!
        start_cell("pin-and-capacity")
        owner = dispatch(build_task("owner"), request_id: "owner", policy: policy)
        fallback = dispatch(build_task("fallback"), request_id: "fallback", policy: policy)
        pinned = dispatch(
          build_task("pinned"),
          request_id: "pinned",
          policy: policy(pin: Hive::ProviderRouting::Pin.new(provider: "account-a"))
        )

        assert!(owner.decision.route.id == "account-a/model-a", "first route was not A")
        assert!(fallback.decision.route.id == "account-b/model-b", "live A capacity did not select B")
        assert!(pinned.status == :no_route, "hard pin fell through to another provider")
      end

      def start_cell(name)
        @store&.database&.disconnect
        root = File.join(@root, name)
        FileUtils.mkdir_p(root)
        database = Hive::RuntimeControlPlane::Database.new(
          path: File.join(root, "runtime-control-plane.sqlite3")
        ).migrate!
        @store = Hive::Attempts::Repository.new(
          root: File.join(root, "attempts"), database: database
        )
        @cell_root = root
        @attempt_counter = 0
        @task_counter = 0
        @launcher = Launcher.new
        register_project!
        @dispatcher = Hive::Attempts::Dispatcher.new(
          store: @store,
          launcher: @launcher,
          limits: { max_global: 20, max_per_project: 20, max_daily: 50 },
          clock: -> { NOW },
          id_generator: -> { next_attempt_id },
          decision_id_generator: -> { SecureRandom.uuid },
          capability_generator: -> { CLAIM_CAPABILITY }
        )
      end

      def dispatch(task, request_id:, policy:)
        @dispatcher.dispatch(
          task: task,
          project: "demo",
          intended_stage: "4-execute",
          argv: [ "hive", "run", task.slug ],
          request_id: request_id,
          provider: "codex",
          routing_policy: policy,
          now: NOW
        )
      end

      def retry_after(predecessor, task, request_id:, policy:)
        @dispatcher.dispatch_successor(
          predecessor: predecessor,
          task: task,
          project: "demo",
          argv: [ "hive", "run", task.slug ],
          request_id: request_id,
          provider: "codex",
          routing_policy: policy,
          admission_view: RetryAdmissionView.new(@store),
          now: NOW + 4
        )
      end

      def fail_attempt(result)
        record = result.attempt
        capability = @launcher.capabilities.fetch(record.attempt_id)
        running = @store.claim(
          record,
          owner: { "pid" => Process.pid },
          claim_capability: capability,
          first_heartbeat_timeout_sec: 30,
          now: NOW + 1
        )
        running = @store.first_heartbeat(running, stale_sec: 30, now: NOW + 2)
        reference = output_reference(running.attempt_id)
        route = running["routing"].fetch("route")
        evidence = Hive::Attempts::EvidenceChannel.materialize(
          {
            "failure_class" => "account_quota",
            "scope" => {
              "kind" => "provider_account",
              "provider_account_id" => route.fetch("provider_account_id"),
              "model" => nil
            },
            "provenance" => "provider_diagnostic",
            "reset_hint_seconds" => nil
          },
          record: running,
          source_reference: reference
        )
        @store.terminalize(
          running,
          outcome: "failed",
          exit_status: 70,
          final_checkpoint: running.checkpoint,
          output_references: [],
          log_reference: reference,
          provider_evidence: evidence,
          now: NOW + 3
        )
      end

      def register_project!
        @store.database.transaction do |db|
          installation = db[:installations].first.fetch(:installation_id)
          db[:projects].insert_conflict.insert(
            project_id: "matrix-demo",
            installation_id: installation,
            registration_id: "matrix-demo",
            name: "demo",
            observed_path: @cell_root,
            state_root_path: File.join(@cell_root, ".hive-state"),
            active: 1,
            registered_at: NOW.iso8601(6),
            last_observed_at: NOW.iso8601(6)
          )
        end
      end

      def build_task(slug)
        @task_counter += 1
        folder = File.join(@cell_root, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        File.binwrite(state_file, "# Task\n\n<!-- WAITING -->\n")
        FakeTask.new(
          id: @task_counter,
          slug: slug,
          folder: folder,
          state_file: state_file,
          stage_index: 4,
          stage_name: "execute",
          workflow: nil
        )
      end

      def policy(routes: self.routes, pin: nil)
        Hive::ProviderRouting::Policy.explicit(
          stage: "execute",
          routes: routes,
          requirements: Hive::ProviderRouting::Requirements.empty,
          pin: pin,
          account_policy: routes.to_h do |route|
            [
              route.account,
              {
                "adapter" => route.adapter,
                "launch_binding" => route.launch_binding,
                "models" => [ route.model ],
                "max_concurrent" => 1
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
          id: "#{account}/#{model}",
          account: account,
          adapter: adapter,
          launch_binding: binding,
          model: model,
          effort: "high",
          order: order,
          capabilities: {
            "context" => "large",
            "quality" => "high",
            "tools" => %w[shell],
            "permissions" => %w[read]
          }
        )
      end

      def output_reference(attempt_id)
        {
          "path" => "logs/#{attempt_id}.frames",
          "size" => 0,
          "sha256" => Digest::SHA256.hexdigest("")
        }
      end

      def next_attempt_id
        @attempt_counter += 1
        "attempt-#{@attempt_counter}"
      end

      def assert!(condition, message)
        raise message unless condition
      end
    end
  end
end
