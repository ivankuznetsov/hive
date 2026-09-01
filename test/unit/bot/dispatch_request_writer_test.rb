require "test_helper"
require "tmpdir"
require "hive/bot/dispatch_request_writer"

class HiveBotDispatchRequestWriterTest < Minitest::Test
  include HiveTestHelper

  W = Hive::Bot::DispatchRequestWriter

  def test_generate_request_id_is_pure
    with_replaced_singleton_method(W, :repository_for, ->(*) { flunk "must not open database" }) do
      assert_match(/\A[0-9a-f]{16}\z/, W.generate_request_id)
    end
  end

  def test_write_never_disconnects_the_process_shared_repository
    shared, database = fake_repository
    with_replaced_singleton_method(W, :repository_for, ->(*) { shared }) do
      assert_equal "request-1", W.write!(
        project: "hive", slug: "task-1", argv: %w[hive run task-1]
      )
    end
    assert_equal 0, database.disconnects

    injected, database = fake_repository
    assert_equal "request-1", W.write!(
      project: "hive", slug: "task-1", argv: %w[hive run task-1],
      repository: injected
    )
    assert_equal 0, database.disconnects
  end

  def test_write_emits_schema_versioned_json_with_required_fields
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      request_id = W.write!(
        project: "hive",
        slug: "explore-the-simplest-way-to-260528-2503",
        argv: [ "hive", "run", "explore-the-simplest-way-to-260528-2503", "--json" ],
        chat_id: 123_456_789,
        update_id: 926_850_952,
        trigger: "answer_complete",
        state_home: dir,
        now: Time.utc(2026, 5, 28, 18, 11, 44)
      )

      assert_kind_of String, request_id
      refute_empty request_id

      request = repository(dir).pending.fetch(0)
      assert_equal Hive::RuntimeControlPlane::DispatchRepository::SCHEMA_VERSION,
                   request.schema_version
      assert_equal request_id, request.request_id
      assert_equal Time.utc(2026, 5, 28, 18, 11, 44), request.created_at
      assert_equal "hive", request.project
      assert_equal "explore-the-simplest-way-to-260528-2503", request.slug
      assert_equal [ "hive", "run", "explore-the-simplest-way-to-260528-2503", "--json" ],
                   request.argv
      assert_equal "bot", request.requestor
      assert_equal 123_456_789, request.chat_id
      assert_equal 926_850_952, request.update_id
      assert_equal "answer_complete", request.trigger
      assert_nil request.task_generation
      assert_nil request.predecessor_attempt_id
      assert_equal [], request.inherited_outputs
    end
  end

  def test_write_accepts_generation_intent_for_durable_delivery
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      W.write!(project: "hive", slug: "task-260528-aaaa",
               argv: [ "hive", "run", "task-260528-aaaa" ],
               task_generation: "generation-one", predecessor_attempt_id: "attempt-zero",
               inherited_outputs: [ { "path" => "outputs/old", "size" => 1, "sha256" => "0" * 64 } ],
               state_home: dir)
      request = repository(dir).pending.first

      assert_equal "generation-one", request.task_generation
      assert_equal "attempt-zero", request.predecessor_attempt_id
      assert_equal 1, request.inherited_outputs.size
    end
  end

  def test_non_run_stage_action_resolves_workflow_target
    task = Struct.new(:stage_index, :stage_name).new(2, "brainstorm")
    assert_equal "3-plan", W.intended_stage_for([ "hive", "plan", "task" ], task)
  end

  def test_plan_review_runner_stays_bound_to_the_current_plan_stage
    task = Struct.new(:stage_index, :stage_name).new(3, "plan")

    assert_equal "3-plan", W.intended_stage_for(
      [ "hive", "plan-review-run", "task" ], task
    )
  end

  def test_write_uses_chronologically_sortable_filename
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      W.write!(project: "p", slug: "first", argv: [ "hive", "run", "first" ],
               state_home: dir, now: Time.utc(2026, 5, 28, 18, 0, 0))
      W.write!(project: "p", slug: "second", argv: [ "hive", "run", "second" ],
               state_home: dir, now: Time.utc(2026, 5, 28, 18, 1, 0))

      first, second = repository(dir).pending.map(&:slug)
      assert_equal "first", first
      assert_equal "second", second
    end
  end

  def test_write_rejects_non_allowlisted_argv
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      good_slug = "task-260528-aaaa"
      assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: good_slug, argv: [ "hive", "doctor" ], state_home: dir)
      end
      assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: good_slug, argv: [ "echo", "rm", "-rf" ], state_home: dir)
      end
      assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: good_slug, argv: "hive run #{good_slug}", state_home: dir)
      end
      assert_empty repository(dir).pending
    end
  end

  # AC-04 from PR #241 ce-code-review: empty project or slug must
  # raise loudly at the producer boundary, not silently make the
  # daemon reject + reply "Couldn't queue".
  def test_write_rejects_empty_project_or_slug
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      good_argv = [ "hive", "run", "task-260528-aaaa" ]

      empty_project = assert_raises(ArgumentError) do
        W.write!(project: "", slug: "task-260528-aaaa", argv: good_argv, state_home: dir)
      end
      assert_match(/project is invalid/, empty_project.message)

      empty_slug = assert_raises(ArgumentError) do
        W.write!(project: "hive", slug: "", argv: good_argv, state_home: dir)
      end
      assert_match(/slug is invalid/, empty_slug.message)

      assert_empty repository(dir).pending
    end
  end

  def test_write_produces_a_parseable_request_via_pending
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      W.write!(project: "hive", slug: "s1",
               argv: [ "hive", "markers", "clear", "s1", "--name", "ERROR", "--project", "hive", "--json" ],
               trigger: "autofix",
               state_home: dir,
               now: Time.utc(2026, 5, 28, 18, 0, 0))

      pending = repository(dir).pending
      assert_equal 1, pending.size
      req = pending.first
      assert_equal "hive", req.project
      assert_equal "s1", req.slug
      assert_equal "bot", req.requestor
      assert_equal "autofix", req.trigger
      assert_equal "markers", req.argv[1]
    end
  end

  def test_sequence_helpers_delegate_to_queue
    Dir.mktmpdir("hive-writer") do |dir|
      migrate!(dir)
      W.write!(
        project: "hive", slug: "task-260528-aaaa",
        argv: [ "hive", "run", "task-260528-aaaa" ],
        request_id: "seq-writer-1", state_home: dir
      )
      assert W.write_sequence!(
        request_id: "seq-writer-1",
        remaining_argvs: [ [ "hive", "review", "task-260528-aaaa", "--json" ] ],
        state_home: dir
      )

      assert W.discard_sequence!(request_id: "seq-writer-1", state_home: dir)
      refute W.discard_sequence!(request_id: "seq-writer-1", state_home: dir)
    end
  end

  def test_recover_normalizes_surface_rows_and_delegates_to_the_shared_coordinator
    captured = nil
    coordinator = Object.new
    coordinator.define_singleton_method(:request) do |**kwargs|
      captured = kwargs
      :receipt
    end
    observed_at = Time.utc(2026, 7, 25, 9, 0, 0)
    row = {
      "slug" => "recover-task",
      "folder" => "/tmp/recover-task",
      "state_file" => "/tmp/recover-task/task.md",
      "stage" => "4-execute",
      "workflow" => "coding",
      "marker" => "error",
      "attrs" => { "reason" => "timeout", "marker_id" => "marker-1" },
      "mtime" => observed_at.iso8601(6),
      "attempt_id" => "attempt-old",
      "task_generation" => "generation-old"
    }

    result = W.recover!(
      row: row, project: "demo", requestor: "web",
      request_id: "recover-request", observation_token: "token",
      now: observed_at + 3600, coordinator: coordinator
    )

    assert_equal :receipt, result
    assert_equal "web", captured.fetch(:requestor)
    assert_equal "recover-request", captured.fetch(:request_id)
    assert_equal "token", captured.fetch(:observation_token)
    observation = captured.fetch(:row)
    assert_equal "demo", observation.project
    assert_equal "recover-task", observation.slug
    assert_equal "error", observation.marker
    assert_equal({ "reason" => "timeout", "marker_id" => "marker-1" },
                 observation.marker_attrs)
    assert_equal observed_at, observation.state_file_mtime
  end

  def test_recover_derives_observation_token_for_every_surface
    captured = nil
    token_observation = nil
    coordinator = Object.new
    coordinator.define_singleton_method(:observation_token_for) do |observation|
      token_observation = observation
      "derived-token"
    end
    coordinator.define_singleton_method(:request) do |**kwargs|
      captured = kwargs
      :receipt
    end

    assert_equal :receipt, W.recover!(
      row: {
        "slug" => "recover-task",
        "folder" => "/tmp/recover-task",
        "state_file" => "/tmp/recover-task/task.md",
        "stage" => "4-execute",
        "workflow" => "coding",
        "marker" => "error",
        "attrs" => { "reason" => "timeout", "marker_id" => "marker-1" },
        "mtime" => Time.utc(2026, 7, 25, 9).iso8601(6)
      },
      project: "demo",
      coordinator: coordinator
    )
    assert_equal "recover-task", token_observation.slug
    assert_equal "derived-token", captured.fetch(:observation_token)
  end

  private

  def fake_repository
    database = Struct.new(:disconnects) do
      def disconnect = self.disconnects += 1
    end.new(0)
    repository = Object.new
    repository.define_singleton_method(:database) { database }
    repository.define_singleton_method(:generate_request_id) { "request-1" }
    repository.define_singleton_method(:write_request!) { |**| "request-1" }
    [ repository, database ]
  end

  def repository(state_home)
    Hive::RuntimeControlPlane::DispatchRepository.open_default(state_home: state_home)
  end

  def migrate!(state_home)
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(state_home)
    ).migrate!
    timestamp = Time.now.utc.iso8601(6)
    database.transaction do |db|
      installation = db[:installations].first.fetch(:installation_id)
      %w[hive p].each do |project|
        db[:projects].insert_conflict.insert(
          project_id: "project-#{project}", installation_id: installation,
          registration_id: project, name: project, observed_path: "/tmp/#{project}",
          state_root_path: "/tmp/#{project}/.hive-state", active: 1,
          registered_at: timestamp, last_observed_at: timestamp
        )
      end
    end
  end
end
