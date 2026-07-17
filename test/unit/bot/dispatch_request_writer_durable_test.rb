require "test_helper"
require "hive/bot/dispatch_request_writer"

class BotDispatchRequestWriterDurableTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :slug, :project_root, :project_name, :stage_index, :stage_name,
    keyword_init: true
  )

  def test_local_admission_claims_delivery_with_attempt_reference
    with_tmp_dir do |state_home|
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
        reference = Hive::Bot::DispatchRequestWriter.dispatch!(
          project: "demo", slug: "demo-task",
          argv: %w[hive run demo-task], request_id: "request-1",
          state_home: state_home, entrypoint: entrypoint
        )

        assert_equal "attempt-1", reference.attempt_id
        assert_equal :accepted, reference.status
        claim = Dir.glob(File.join(state_home, "dispatch_requests", "*.claim")).first
        metadata = JSON.parse(File.read(claim))
        assert_equal "attempt-1", metadata["attempt_id"]
        assert_equal "generation-1", metadata["task_generation"]
      end
    end
  end

  def test_capacity_deferral_leaves_delivery_pending
    with_tmp_dir do |state_home|
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

        assert reference.queued?
        assert_equal 1, Hive::Daemon::DispatchRequestQueue.pending(state_home: state_home).size
      end
    end
  end
end
