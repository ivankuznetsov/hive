require "test_helper"
require "hive/attempts/repository"
require "hive/provider_health/repository"
require "hive/provider_routing"
require "hive/runtime_control_plane/dispatch_repository"

class RuntimeControlPlaneAdmissionTransitionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 29, 12)
  CLAIM_DIGEST = Hive::Attempts::Capability.digest("c" * 64)

  def test_racing_admissions_atomically_claim_one_request_slot_and_probe
    with_control_plane(task_ids: %w[task-1 task-2]) do |attempts, dispatch, health|
      policy = explicit_policy(max_concurrent: 1)
      seed_half_open_circuits(attempts.database)
      %w[1 2].each do |suffix|
        dispatch.write_request!(
          project: "demo", slug: "task-#{suffix}",
          argv: [ "hive", "run", "task-#{suffix}" ],
          request_id: "request-#{suffix}", task_id: "task-#{suffix}",
          task_generation: "generation-#{suffix}", expected_stage: "4-execute", now: NOW
        )
      end

      path = attempts.database.path
      attempts.database.disconnect
      results = race_in_processes(path, policy)
      attempts.database.open!
      accepted = results.select { |status, *_| status == :accepted }
      assert_equal 1, accepted.length, results.inspect
      assert_equal 1, results.count { |status, *_| status == :rejected }
      winner_id = accepted.fetch(0).fetch(1)
      winner = attempts.fetch(winner_id)
      assert_equal 2, winner["routing"].fetch("probe_bindings").length

      rows = attempts.database.read do |db|
        {
          requests: db[:dispatch_requests].order(:request_id).select_map([ :request_id, :state ]),
          attempts: db[:attempts].select_map(:attempt_id),
          reservations: db[:capacity_reservations].where(state: "reserved").select_map(:attempt_id),
          probes: db[:provider_circuits].exclude(probe_attempt_id: nil).select_map(:probe_attempt_id)
        }
      end
      assert_equal 1, rows.fetch(:requests).count { |_id, state| state == "admitted" }
      assert_equal 1, rows.fetch(:requests).count { |_id, state| state == "queued" }
      assert_includes rows.fetch(:requests), [ winner["request_id"], "admitted" ]
      assert_equal [ winner.attempt_id ], rows.fetch(:attempts)
      assert_equal [ winner.attempt_id ], rows.fetch(:reservations)
      assert_equal [ winner.attempt_id ], rows.fetch(:probes).uniq
    end
  end

  def test_authoritative_task_source_is_rechecked_inside_final_admission
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, dispatch, health|
      policy = explicit_policy(max_concurrent: 1)
      route_decision = decision(policy, health, "generation-1")
      dispatch.write_request!(
        project: "demo", slug: "task-1", argv: %w[hive run task-1],
        request_id: "request-1", task_id: "task-1",
        task_generation: "generation-1", expected_stage: "4-execute", now: NOW
      )
      attempts.database.transaction do |db|
        db[:task_subjects].where(task_id: "task-1").update(
          source_fingerprint: "changed", generation: 2
        )
      end

      assert_raises(Hive::Attempts::StaleTaskSource) do
        create_routed_attempt(attempts, health, policy, route_decision, suffix: 1)
      end
      assert_equal "queued", dispatch.fetch("request-1").state
      assert_equal 0, attempts.database.read { |db| db[:attempts].count }
    end
  end

  def test_task_source_observation_replaces_lease_placeholder_before_admission
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, _dispatch, health|
      state_root = attempts.database.read { |db| db[:projects].first.fetch(:state_root_path) }
      task_folder = File.join(state_root, "stages", "4-execute", "task-1")
      FileUtils.mkdir_p(task_folder)
      task = Struct.new(:folder, :workflow).new(task_folder, nil)
      generation = Struct.new(
        :task_id, :project, :task_slug, :progress_token, :task_input_epoch
      ).new("task-1", "demo", "task-1", "source-1", 1)
      attempts.database.transaction do |db|
        db[:task_subjects].where(task_id: "task-1").update(
          observed_path: task_folder, source_fingerprint: "", generation: 0
        )
      end

      assert attempts.observe_task_source(task: task, generation: generation, observed_at: NOW)
      observed = attempts.database.read do |db|
        db[:task_subjects].where(task_id: "task-1").first
      end
      assert_equal "source-1", observed.fetch(:source_fingerprint)
      assert_equal 1, observed.fetch(:generation)

      policy = explicit_policy(max_concurrent: 1)
      route_decision = decision(policy, health, "generation-1")
      accepted = create_routed_attempt(attempts, health, policy, route_decision, suffix: 1)
      assert_equal "attempt-1", accepted.attempt_id
    end
  end

  def test_older_task_source_observation_cannot_replace_a_newer_one
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, _dispatch, _health|
      state_root = attempts.database.read { |db| db[:projects].first.fetch(:state_root_path) }
      folder = File.join(state_root, "stages", "4-execute", "task-1")
      FileUtils.mkdir_p(folder)
      task = Struct.new(:folder, :workflow).new(folder, nil)
      generation = Struct.new(
        :task_id, :project, :task_slug, :progress_token, :task_input_epoch
      )
      newer = generation.new("task-1", "demo", "task-1", "source-new", 2)
      older = generation.new("task-1", "demo", "task-1", "source-old", 1)

      assert attempts.observe_task_source(task: task, generation: newer, observed_at: NOW + 2)
      assert_raises(Hive::Attempts::StaleTaskSource) do
        attempts.observe_task_source(task: task, generation: older, observed_at: NOW + 1)
      end
      row = attempts.database.read { |db| db[:task_subjects].where(task_id: "task-1").first }
      assert_equal "source-new", row.fetch(:source_fingerprint)
      assert_equal 2, row.fetch(:generation)
    end
  end

  def test_module_hook_binds_to_registered_project_without_fabricating_a_task
    with_control_plane(task_ids: []) do |attempts, _dispatch, _health|
      subject = {
        "kind" => "module_hook", "project_id" => "project-1", "module" => "demo",
        "hook" => "task", "event_id" => "event-1", "occurrence_id" => "event-1",
        "event_name" => "task.completed", "module_generation" => "a" * 40,
        "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
      }
      record = attempts.create_launching(
        attempt_id: "module-attempt", request_id: "module-request",
        predecessor_attempt_id: nil, task_id: nil, project: "demo",
        task_slug: "module-demo-task-event-1", intended_stage: "module-hook",
        task_generation: "module-generation", ownership_generation: "module-owner",
        task_input_epoch: 1, progress_token: "event-1", provider: "module",
        worker_argv: %w[hive __module-hook demo task],
        claim_capability_digest: CLAIM_DIGEST, starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], subject: subject,
        launch_timeout_sec: 30, now: NOW
      )

      row = attempts.database.read do |db|
        db[:attempts].where(attempt_id: record.attempt_id).first
      end
      assert_nil row.fetch(:task_id)
      assert_equal "project-1", row.fetch(:project_id)
      assert_equal 0, attempts.database.read { |db| db[:task_subjects].count }
    end
  end

  def test_provider_capacity_is_revalidated_inside_the_admission_transaction
    with_control_plane(task_ids: %w[task-1 task-2]) do |attempts, dispatch, health|
      policy = explicit_policy(max_concurrent: 1)
      decisions = %w[generation-1 generation-2].map do |generation|
        decision(policy, health, generation)
      end
      %w[1 2].each do |suffix|
        dispatch.write_request!(
          project: "demo", slug: "task-#{suffix}",
          argv: [ "hive", "run", "task-#{suffix}" ],
          request_id: "request-#{suffix}", task_id: "task-#{suffix}",
          task_generation: "generation-#{suffix}", expected_stage: "4-execute", now: NOW
        )
      end

      create_routed_attempt(attempts, health, policy, decisions.fetch(0), suffix: 1)
      assert_raises(Hive::Attempts::CapacityExceeded) do
        create_routed_attempt(attempts, health, policy, decisions.fetch(1), suffix: 2)
      end

      request_state = attempts.database.read do |db|
        db[:dispatch_requests].where(request_id: "request-2").get(:state)
      end
      assert_equal "queued", request_state
      assert_equal 1, attempts.database.read { |db| db[:attempts].count }
    end
  end

  private

  def with_control_plane(task_ids:)
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "runtime.sqlite3")
      ).migrate!
      timestamp = NOW.iso8601(6)
      database.transaction do |db|
        installation = db[:installations].first.fetch(:installation_id)
        db[:projects].insert(
          project_id: "project-1", installation_id: installation,
          registration_id: "registration-1", name: "demo", observed_path: root,
          state_root_path: File.join(root, ".hive-state"), active: 1,
          registered_at: timestamp, last_observed_at: timestamp
        )
        task_ids.each do |task_id|
          suffix = task_id.delete_prefix("task-")
          db[:task_subjects].insert(
            task_id: task_id, project_id: "project-1", workflow_id: "coding",
            task_slug: task_id, observed_path: File.join(root, task_id),
            source_fingerprint: "source-#{suffix}",
            generation: 1, created_at: timestamp, last_observed_at: timestamp
          )
        end
      end
      attempts = Hive::Attempts::Repository.new(
        root: File.join(root, "payloads"), database: database
      )
      yield(
        attempts,
        Hive::RuntimeControlPlane::DispatchRepository.new(database: database, clock: -> { NOW }),
        Hive::ProviderHealth::Repository.new(database: database, clock: -> { NOW })
      )
    ensure
      database&.disconnect
    end
  end

  def race_in_processes(path, policy)
    ready_read, ready_write = IO.pipe
    start_read, start_write = IO.pipe
    result_pipes = 2.times.map { IO.pipe }
    pids = 2.times.map do |index|
      fork do
        ready_read.close
        start_write.close
        result_pipes.each_with_index do |(reader, writer), pipe_index|
          reader.close
          writer.close unless pipe_index == index
        end
        database = Hive::RuntimeControlPlane::Database.new(path: path).open!
        attempts = Hive::Attempts::Repository.new(
          root: File.join(File.dirname(path), "child-#{index}"), database: database
        )
        health = Hive::ProviderHealth::Repository.new(database: database, clock: -> { NOW })
        route_decision = decision(policy, health, "generation-#{index + 1}")
        ready_write.write("r")
        start_read.read(1)
        result = create_routed_attempt(
          attempts, health, policy, route_decision, suffix: index + 1
        )
        Marshal.dump([ :accepted, result.attempt_id ], result_pipes.fetch(index).fetch(1))
      rescue Hive::Attempts::RepositoryError, Hive::ProviderHealth::StaleGeneration => error
        Marshal.dump([ :rejected, error.class.name ], result_pipes.fetch(index).fetch(1))
      ensure
        database&.disconnect
        exit! 0
      end
    end
    ready_write.close
    start_read.close
    result_pipes.each { |_reader, writer| writer.close }
    ready_read.read(2)
    start_write.write("gg")
    start_write.close
    pids.each { |pid| Process.wait(pid) }
    result_pipes.map { |reader, _writer| Marshal.load(reader.read) }
  ensure
    ready_read&.close unless ready_read&.closed?
    ready_write&.close unless ready_write&.closed?
    start_read&.close unless start_read&.closed?
    start_write&.close unless start_write&.closed?
    Array(result_pipes).each do |reader, writer|
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  def create_routed_attempt(attempts, health, policy, route_decision, suffix:)
    attempts.create_launching(
      attempt_id: "attempt-#{suffix}", request_id: "request-#{suffix}",
      predecessor_attempt_id: nil, task_id: "task-#{suffix}", project: "demo",
      task_slug: "task-#{suffix}", intended_stage: "4-execute",
      task_generation: "generation-#{suffix}", ownership_generation: "owner-#{suffix}",
      task_input_epoch: 1, progress_token: "source-#{suffix}", provider: "codex",
      worker_argv: [ "hive", "run", "task-#{suffix}" ],
      claim_capability_digest: CLAIM_DIGEST, starting_revision: "a" * 40,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW,
      limits: { max_global: 10, max_per_project: 10, max_daily: 10 },
      routing_policy: policy, route_decision: route_decision, health_repository: health
    )
  end

  def decision(policy, health, generation)
    evaluations = health.evaluate_routes(
      routes: [ { account_id: "account-a", model_id: "model-a" } ], now: NOW
    )
    Hive::ProviderRouting::Router.new.call(
      request: Hive::ProviderRouting::Request.new(
        policy: policy, task_generation: generation,
        health: { "account-a/model-a" => evaluations.fetch(0) },
        capacity: { "account-a" => { "observed" => 0, "max" => 1 } }
      ),
      decision_id: "decision-#{generation}", decided_at: NOW
    )
  end

  def explicit_policy(max_concurrent:)
    route = Hive::ProviderRouting::Route.new(
      id: "account-a/model-a", account: "account-a", adapter: "codex",
      launch_binding: "binding-a", model: "model-a", effort: "high", order: 0,
      billing_route: "subscription", billing_evidence_source: "agent_profile_contract",
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell], "permissions" => %w[read]
      }
    )
    Hive::ProviderRouting::Policy.explicit(
      stage: "execute", routes: [ route ],
      requirements: Hive::ProviderRouting::Requirements.empty, pin: nil,
      account_policy: {
        "account-a" => {
          "adapter" => "codex", "launch_binding" => "binding-a",
          "models" => [ "model-a" ], "max_concurrent" => max_concurrent,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
  end

  def seed_half_open_circuits(database)
    scopes = [
      Hive::ProviderHealth::Scope.provider_account(account_id: "account-a"),
      Hive::ProviderHealth::Scope.model(account_id: "account-a", model_id: "model-a")
    ]
    database.transaction do |db|
      scopes.each do |scope|
        db[:provider_circuits].insert(
          circuit_id: scope.key, scope_kind: scope.kind,
          provider_account_id: scope.account_id, model: scope.model_id.to_s,
          automatic_state: "open", manual_block: 0, generation: 1, journal_epoch: 0,
          eligible_at: (NOW - 1).iso8601(6),
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json("failure" => "quota"),
          updated_at: NOW.iso8601(6)
        )
      end
    end
  end
end
