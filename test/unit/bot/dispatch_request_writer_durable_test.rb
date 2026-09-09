require "test_helper"
require "hive/bot/dispatch_request_writer"

class BotDispatchRequestWriterDurableTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :id, :slug, :project_root, :project_name, :stage_index, :stage_name,
    keyword_init: true
  ) do
    def state_file = File.join(project_root, "task.md")
  end

  def test_local_admission_returns_attempt_without_a_second_writer_side_claim
    with_tmp_dir do |state_home|
      repository(state_home)
      task = FakeTask.new(
        slug: "demo-task", project_root: "/tmp/demo", project_name: "demo",
        stage_index: 4, stage_name: "execute"
      )
      attempt = Struct.new(:attempt_id, :task_generation, :state)
                      .new("attempt-1", "generation-1", "launching")
      dispatch_result = Hive::Attempts::DispatchResult.new(
        status: :accepted, attempt: attempt, receipt: nil,
        attach_descriptor: nil, reason: nil
      )
      entrypoint = Object.new
      entrypoint.define_singleton_method(:dispatch) { |**_kwargs| dispatch_result }

      with_replaced_singleton_method(Hive::Bot::DispatchRequestWriter, :resolve_task,
                                     ->(**_kwargs) { task }) do
        reference = nil
        with_replaced_singleton_method(Hive::Attempts::API, :new, -> { entrypoint }) do
          reference = Hive::Bot::DispatchRequestWriter.dispatch!(
            project: "demo", slug: "demo-task",
            argv: %w[hive run demo-task], request_id: "request-1",
            state_home: state_home
          )
        end

        assert_equal "attempt-1", reference.attempt_id
        assert_equal :accepted, reference.status
        request = repository(state_home).pending.fetch(0)
        assert_equal "request-1", request.request_id
        assert_equal "queued", request.state
      end
    end
  end

  def test_capacity_deferral_leaves_delivery_pending
    with_tmp_dir do |state_home|
      repository(state_home)
      task = FakeTask.new(
        slug: "demo-task", project_root: "/tmp/demo", project_name: "demo",
        stage_index: 4, stage_name: "execute"
      )
      entrypoint = Object.new
      entrypoint.define_singleton_method(:dispatch) do |**_kwargs|
        raise Hive::ConcurrentRunError, "capacity"
      end

      with_replaced_singleton_method(Hive::Bot::DispatchRequestWriter, :resolve_task,
                                     ->(**_kwargs) { task }) do
        reference = Hive::Bot::DispatchRequestWriter.dispatch!(
          project: "demo", slug: "demo-task", argv: %w[hive run demo-task],
          request_id: "request-1", state_home: state_home, entrypoint: entrypoint
        )

        assert_equal :queued, reference.status
        assert_equal 1, repository(state_home).pending.size
      end
    end
  end

  def test_initial_no_route_leaves_delivery_pending_without_dereferencing_an_attempt
    with_tmp_dir do |state_home|
      repository(state_home)
      task = FakeTask.new(
        slug: "demo-task", project_root: "/tmp/demo", project_name: "demo",
        stage_index: 4, stage_name: "execute"
      )
      entrypoint = Object.new
      entrypoint.define_singleton_method(:dispatch) do |**_kwargs|
        Hive::Attempts::DispatchResult.new(
          status: :no_route, attempt: nil, receipt: nil,
          attach_descriptor: nil, reason: "no_eligible_provider_route", decision: Object.new
        )
      end

      with_replaced_singleton_method(
        Hive::Bot::DispatchRequestWriter, :resolve_task, ->(**_kwargs) { task }
      ) do
        reference = Hive::Bot::DispatchRequestWriter.dispatch!(
          project: "demo", slug: "demo-task", argv: %w[hive run demo-task],
          request_id: "request-no-route", state_home: state_home, entrypoint: entrypoint
        )

        assert_equal :queued, reference.status
        assert_nil reference.attempt_id
        assert_equal 1, repository(state_home).pending.size
      end
    end
  end

  def test_unexpected_admission_failure_removes_unclaimed_delivery
    with_tmp_dir do |state_home|
      repository(state_home)
      task = FakeTask.new(
        slug: "demo-task", project_root: "/tmp/demo", project_name: "demo",
        stage_index: 4, stage_name: "execute"
      )
      entrypoint = Object.new
      failure = RuntimeError.new("unexpected admission failure")
      entrypoint.define_singleton_method(:dispatch) { |**_kwargs| raise failure }

      with_replaced_singleton_method(Hive::Bot::DispatchRequestWriter, :resolve_task,
                                     ->(**_kwargs) { task }) do
        raised = assert_raises(RuntimeError) do
          Hive::Bot::DispatchRequestWriter.dispatch!(
            project: "demo", slug: "demo-task", argv: %w[hive run demo-task],
            request_id: "request-1", state_home: state_home, entrypoint: entrypoint
          )
        end
        assert_same failure, raised
      end

      assert_empty repository(state_home).pending
    end
  end

  def test_task_resolution_scopes_the_slug_by_project_and_stage_flag
    resolved_task = Object.new
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { resolved_task }
    constructor_calls = []

    with_replaced_singleton_method(
      Hive::TaskResolver,
      :new,
      lambda do |slug, **options|
        constructor_calls << [ slug, options ]
        resolver
      end
    ) do
      result = Hive::Bot::DispatchRequestWriter.resolve_task(
        project: "demo", slug: "demo-task",
        argv: %w[hive run demo-task --from 4-execute]
      )

      assert_same resolved_task, result
    end

    assert_equal [
      [ "demo-task", { project_filter: "demo", stage_filter: "4-execute" } ]
    ], constructor_calls
    assert_nil Hive::Bot::DispatchRequestWriter.stage_filter_for(%w[hive run demo-task])
  end

  def test_write_current_binds_the_delivery_to_the_observed_task_identity
    with_tmp_dir do |state_home|
      repository(state_home)
      task = FakeTask.new(
        id: 42, slug: "demo-task", project_root: "/tmp/demo", project_name: "demo",
        stage_index: 4, stage_name: "execute"
      )

      with_replaced_singleton_method(
        Hive::Bot::DispatchRequestWriter, :resolve_task, ->(**_kwargs) { task }
      ) do
        Hive::Bot::DispatchRequestWriter.write_current!(
          project: "demo", slug: "demo-task", argv: %w[hive run demo-task],
          request_id: "request-current", state_home: state_home
        )
      end

      request = repository(state_home).pending.fetch(0)
      assert_equal 42, request.task_id
      assert_equal "4-execute", request.expected_stage
      assert_match(/\A[0-9a-f]{64}\z/, request.task_generation)
    end
  end

  def test_resolution_race_keeps_a_stage_bound_delivery_without_foreground_admission
    with_tmp_dir do |state_home|
      repository(state_home)
      entrypoint = Object.new
      entrypoint.define_singleton_method(:dispatch) { |**| flunk "unresolved task must stay queued" }

      with_replaced_singleton_method(
        Hive::Bot::DispatchRequestWriter,
        :resolve_task,
        ->(**) { raise Hive::InvalidTaskPath, "task is moving" }
      ) do
        reference = Hive::Bot::DispatchRequestWriter.dispatch!(
          project: "demo", slug: "demo-task",
          argv: %w[hive run demo-task --stage 4-execute],
          request_id: "request-moving", state_home: state_home,
          entrypoint: entrypoint
        )

        assert_equal :queued, reference.status
      end

      request = repository(state_home).pending.fetch(0)
      assert_equal "4-execute", request.expected_stage
      assert_nil request.task_id
      assert_nil request.task_generation
    end
  end

  private

  def repository(state_home)
    database = Hive::RuntimeControlPlane::Database.new(
      path: Hive::Paths.runtime_control_plane_path(state_home)
    ).migrate!
    timestamp = Time.now.utc.iso8601(6)
    database.transaction do |db|
      installation = db[:installations].first.fetch(:installation_id)
      db[:projects].insert_conflict.insert(
        project_id: "project-demo", installation_id: installation,
        registration_id: "demo", name: "demo", observed_path: "/tmp/demo",
        state_root_path: "/tmp/demo/.hive-state", active: 1,
        registered_at: timestamp, last_observed_at: timestamp
      )
    end
    Hive::RuntimeControlPlane::DispatchRepository.new(database: database)
  end
end
