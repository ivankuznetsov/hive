require "test_helper"
require "hive/attempts/lost_outcome"
require "hive/attempts/repository"
require "hive/provider_routing"
require "hive/runtime_control_plane/dispatch_repository"

class RuntimeControlPlaneAdmissionTransitionTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 29, 12)
  CLAIM_DIGEST = Hive::Attempts::Capability.digest("c" * 64)

  def test_concurrent_lost_healers_admit_at_most_one_independent_replacement
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, _dispatch, _health|
      source = attempts.create_launching(
        attempt_id: "lost-source", request_id: "source-request",
        task_id: "task-1", project: "demo", task_slug: "task-1",
        intended_stage: "4-execute", task_generation: "generation-1",
        ownership_generation: "owner-1", task_input_epoch: 1,
        progress_token: "source-1", provider: "codex",
        worker_argv: %w[hive run task-1], claim_capability_digest: CLAIM_DIGEST,
        starting_revision: "a" * 40, retry_charge: 0,
        inherited_outputs: [], launch_timeout_sec: 30, now: NOW
      )
      lost = attempts.mark_lost(source, reason: "owner_gone", now: NOW + 1)
      recovery = Hive::Attempts::LostOutcomeTransition.new(store: attempts)
      request_id = recovery.recovery_request_id(lost)
      path = attempts.database.path
      payload_root = attempts.root
      attempts.database.disconnect

      results = race_lost_healers(
        path: path, payload_root: payload_root, source_attempt_id: lost.attempt_id
      )

      attempts.database.open!
      assert_equal 1, results.count { |status, _| status == :accepted }, results.inspect
      assert_equal 1, results.count { |status, _| status == :rejected }, results.inspect
      rows = attempts.database.read do |db|
        {
          source: db[:attempts].where(attempt_id: lost.attempt_id).first,
          replacements: db[:attempts].exclude(attempt_id: lost.attempt_id).all,
          recovery_requests: db[:dispatch_requests].where(request_id: request_id).all
        }
      end
      assert_equal "complete", rows.fetch(:source).fetch(:lost_recovery_phase)
      assert_equal request_id, rows.fetch(:source).fetch(:lost_recovery_request_id)
      assert_equal 1, rows.fetch(:replacements).size
      assert_equal request_id, rows.fetch(:replacements).first.fetch(:request_id)
      assert_equal 1, rows.fetch(:recovery_requests).size
      assert_equal "admitted", rows.fetch(:recovery_requests).first.fetch(:state)
      payload = Hive::RuntimeControlPlane::Codec.load_json(
        rows.fetch(:recovery_requests).first.fetch(:payload_json)
      )
      assert_equal "dispatched", payload.dig("recovery", "phase")
      replacement = attempts.fetch(rows.fetch(:replacements).first.fetch(:attempt_id))
      refute_includes replacement.to_h, "predecessor_attempt_id"
    end
  end

  def test_racing_admissions_atomically_claim_one_provider_capacity_slot
    with_control_plane(task_ids: %w[task-1 task-2]) do |attempts, dispatch, health|
      policy = explicit_policy(max_concurrent: 1)
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
      refute_includes winner["routing"], "probe_bindings"

      rows = attempts.database.read do |db|
        {
          requests: db[:dispatch_requests].order(:request_id).select_map([ :request_id, :state ]),
          attempts: db[:attempts].select_map(:attempt_id)
        }
      end
      assert_equal 1, rows.fetch(:requests).count { |_id, state| state == "admitted" }
      assert_equal 1, rows.fetch(:requests).count { |_id, state| state == "queued" }
      assert_includes rows.fetch(:requests), [ winner["request_id"], "admitted" ]
      assert_equal [ winner.attempt_id ], rows.fetch(:attempts)
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

  def test_recovery_admission_requires_the_requests_current_generation
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, dispatch, _health|
      dispatch.write_request!(
        project: "demo", slug: "task-1", argv: %w[hive run task-1],
        request_id: "request-1", task_id: "task-1",
        task_generation: "generation-current", expected_stage: "4-execute",
        recovery: {
          "variant" => "marker", "phase" => "cleared",
          "expected_marker_attrs" => { "task_generation" => "generation-failed" }
        },
        now: NOW
      )

      assert_raises(Hive::Attempts::RepositoryError) do
        attempts.create_launching(
          attempt_id: "attempt-1", request_id: "request-1",
          task_id: "task-1", project: "demo", task_slug: "task-1",
          intended_stage: "4-execute", task_generation: "generation-failed",
          ownership_generation: "generation-failed", task_input_epoch: 1,
          progress_token: "source-1", provider: "codex",
          worker_argv: %w[hive run task-1], claim_capability_digest: CLAIM_DIGEST,
          starting_revision: "a" * 40, retry_charge: 1,
          inherited_outputs: [], launch_timeout_sec: 30, now: NOW
        )
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
        task_id: nil, project: "demo",
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

  def test_task_source_observation_rejects_each_identity_and_generation_mismatch
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, _dispatch, _health|
      state_root = attempts.database.read { |db| db[:projects].first.fetch(:state_root_path) }
      generation_class = Struct.new(
        :task_id, :project, :task_slug, :progress_token, :task_input_epoch
      )
      task_class = Struct.new(:folder, :workflow)

      invalid_path = task_class.new(File.join(state_root, "other", "task-1"), nil)
      valid_generation = generation_class.new("task-1", "demo", "task-1", "source", 1)
      assert_raises(Hive::Attempts::StaleTaskSource) do
        attempts.observe_task_source(task: invalid_path, generation: valid_generation, observed_at: NOW)
      end

      unknown_root = File.join(File.dirname(state_root), "unknown", ".hive-state")
      unregistered = task_class.new(File.join(unknown_root, "stages", "4-execute", "task-1"), nil)
      assert_raises(Hive::Attempts::StaleTaskSource) do
        attempts.observe_task_source(task: unregistered, generation: valid_generation, observed_at: NOW)
      end

      folder = File.join(state_root, "stages", "4-execute", "task-1")
      task = task_class.new(folder, nil)
      alias_generation = generation_class.new("other-id", "demo", "task-1", "source", 1)
      assert_raises(Hive::Attempts::StaleTaskSource) do
        attempts.observe_task_source(task: task, generation: alias_generation, observed_at: NOW)
      end

      wrong_workflow = task_class.new(folder, "review")
      assert_raises(Hive::Attempts::StaleTaskSource) do
        attempts.observe_task_source(task: wrong_workflow, generation: valid_generation, observed_at: NOW)
      end

      invalid_generation = generation_class.new("task-1", "demo", "task-1", "source", "bad")
      assert_raises(Hive::Attempts::StaleTaskSource) do
        attempts.observe_task_source(task: task, generation: invalid_generation, observed_at: NOW)
      end
      attempts.database.transaction do |db|
        assert_raises(Hive::Attempts::StaleTaskSource) do
          attempts.admission_validate_subject_in(
            db, task_id: "task-1", source_fingerprint: "source-1", generation: "bad"
          )
        end
      end
    end

    with_control_plane(task_ids: [ "task-1" ]) do |attempts, _dispatch, _health|
      state_root = attempts.database.read { |db| db[:projects].first.fetch(:state_root_path) }
      folder = File.join(state_root, "stages", "4-execute", "task-1")
      task = Struct.new(:folder, :workflow).new(folder, nil)
      generation = Struct.new(
        :task_id, :project, :task_slug, :progress_token, :task_input_epoch
      ).new("task-1", "demo", "task-1", "source", 1)
      attempts.database.define_singleton_method(:transaction) do |**|
        raise Hive::RuntimeControlPlane::IntegrityError.new("boom", code: :database_corrupt)
      end

      error = assert_raises(Hive::Attempts::RepositoryError) do
        attempts.observe_task_source(task: task, generation: generation, observed_at: NOW)
      end
      assert_match(/could not be observed/, error.message)
    end
  end

  def test_admission_rejects_unregistered_module_invalid_record_and_invalid_limits
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, _dispatch, _health|
      base = {
        attempt_id: "module-attempt", request_id: "module-request",
        task_id: nil, project: "demo",
        task_slug: "module-demo-task-event-1", intended_stage: "module-hook",
        task_generation: "module-generation", ownership_generation: "module-owner",
        task_input_epoch: 1, progress_token: "event-1", provider: "module",
        worker_argv: %w[hive __module-hook demo task],
        claim_capability_digest: CLAIM_DIGEST, starting_revision: nil,
        retry_charge: 0, inherited_outputs: [],
        subject: {
          "kind" => "module_hook", "project_id" => "missing", "module" => "demo",
          "hook" => "task", "event_id" => "event-1", "occurrence_id" => "event-1",
          "event_name" => "task.completed", "module_generation" => "a" * 40,
          "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
        },
        launch_timeout_sec: 30, now: NOW
      }
      assert_raises(Hive::Attempts::RepositoryError) { attempts.create_launching(**base) }
      assert_raises(Hive::Attempts::RepositoryError) do
        attempts.create_launching(**base.merge(attempt_id: ""))
      end

      assert_raises(Hive::Attempts::RepositoryError) do
        attempts.create_launching(
          attempt_id: "attempt-1", request_id: "request-1",
          task_id: "task-1", project: "demo",
          task_slug: "task-1", intended_stage: "4-execute",
          task_generation: "generation-1", ownership_generation: "owner-1",
          task_input_epoch: 1, progress_token: "source-1", provider: "codex",
          worker_argv: %w[hive run task-1], claim_capability_digest: CLAIM_DIGEST,
          starting_revision: nil, retry_charge: 0, inherited_outputs: [],
          limits: { max_global: "bad" }, launch_timeout_sec: 30, now: NOW
        )
      end
    end
  end

  def test_admission_rejects_changed_dispatch_source_binding
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, dispatch, health|
      policy = explicit_policy(max_concurrent: 1)
      route_decision = decision(policy, health, "generation-1")
      dispatch.write_request!(
        project: "demo", slug: "task-1", argv: %w[hive run task-1],
        request_id: "request-1", task_id: "task-1",
        task_generation: "generation-1", expected_stage: "4-execute", now: NOW
      )
      attempts.database.transaction do |db|
        row = db[:dispatch_requests].where(request_id: "request-1").first
        payload = Hive::RuntimeControlPlane::Codec.load_json(row.fetch(:payload_json))
        payload["task_id"] = "different-task"
        db[:dispatch_requests].where(request_id: "request-1")
          .update(payload_json: Hive::RuntimeControlPlane::Codec.dump_json(payload))
      end

      assert_raises(Hive::Attempts::RepositoryError) do
        create_routed_attempt(attempts, health, policy, route_decision, suffix: 1)
      end
      assert_equal "queued", dispatch.fetch("request-1").state
    end
  end

  def test_admission_requires_a_provider_capacity_observation
    with_control_plane(task_ids: [ "task-1" ]) do |attempts, dispatch, health|
      policy = explicit_policy(max_concurrent: 1)
      ordinary = decision(policy, health, "generation-1")
      candidate = Hive::ProviderRouting::Candidate.new(
        route: ordinary.route, exclusions: [], max_concurrency: nil
      )
      incomplete = Hive::ProviderRouting::Decision.selected(
        request: ordinary.request, route: ordinary.route, considered: ordinary.considered,
        candidates: [ candidate ], decided_at: NOW
      )
      dispatch.write_request!(
        project: "demo", slug: "task-1", argv: %w[hive run task-1],
        request_id: "request-1", task_id: "task-1",
        task_generation: "generation-1", expected_stage: "4-execute", now: NOW
      )

      error = assert_raises(Hive::Attempts::RepositoryError) do
        create_routed_attempt(attempts, health, policy, incomplete, suffix: 1)
      end
      assert_match(/provider capacity observation is unavailable/, error.message)
      assert_equal 0, attempts.database.read { |db| db[:attempts].count }
    end
  end

  private

  def race_lost_healers(path:, payload_root:, source_attempt_id:)
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
        repository = Hive::Attempts::Repository.new(root: payload_root, database: database)
        source = repository.fetch(source_attempt_id)
        recovery = Hive::Attempts::LostOutcomeTransition.new(store: repository)
        ready_write.write("r")
        start_read.read(1)
        recovery.ensure_for(source, now: NOW + 2)
        ready = recovery.update(
          source, phase: "ready", cleanup: "absent",
          request_id: recovery.recovery_request_id(source), now: NOW + 2
        )
        replacement = repository.create_launching(
          attempt_id: "replacement-#{index + 1}", request_id: ready.fetch("request_id"),
          recovery_source_attempt_id: source.attempt_id,
          task_id: source["task_id"], project: source["project"],
          task_slug: source["task_slug"], intended_stage: source["intended_stage"],
          task_generation: source.task_generation,
          ownership_generation: "replacement-owner-#{index + 1}",
          task_input_epoch: source.task_input_epoch, progress_token: source["progress_token"],
          provider: source["provider"], routing: source["routing"],
          worker_argv: source["worker_argv"], claim_capability_digest: CLAIM_DIGEST,
          starting_revision: source["starting_revision"], retry_charge: 1,
          inherited_outputs: source["current_outputs"], launch_timeout_sec: 30,
          now: NOW + 3
        )
        Marshal.dump([ :accepted, replacement.attempt_id ], result_pipes.fetch(index).fetch(1))
      rescue Hive::Attempts::RepositoryError, Hive::RuntimeControlPlane::Error => error
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
        nil
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
        route_decision = decision(policy, nil, "generation-#{index + 1}")
        ready_write.write("r")
        start_read.read(1)
        result = create_routed_attempt(
          attempts, nil, policy, route_decision, suffix: index + 1
        )
        Marshal.dump([ :accepted, result.attempt_id ], result_pipes.fetch(index).fetch(1))
      rescue StandardError => error
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

  def create_routed_attempt(attempts, _health, _policy, route_decision, suffix:)
    attempts.create_launching(
      attempt_id: "attempt-#{suffix}", request_id: "request-#{suffix}",
      task_id: "task-#{suffix}", project: "demo",
      task_slug: "task-#{suffix}", intended_stage: "4-execute",
      task_generation: "generation-#{suffix}", ownership_generation: "owner-#{suffix}",
      task_input_epoch: 1, progress_token: "source-#{suffix}", provider: "codex",
      worker_argv: [ "hive", "run", "task-#{suffix}" ],
      claim_capability_digest: CLAIM_DIGEST, starting_revision: "a" * 40,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW,
      limits: { max_global: 10, max_per_project: 10, max_daily: 10 },
      route_decision: route_decision
    )
  end

  def decision(policy, _health, generation)
    Hive::ProviderRouting::Router.new.call(
      request: Hive::ProviderRouting::Request.new(
        policy: policy, task_generation: generation,
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
end
