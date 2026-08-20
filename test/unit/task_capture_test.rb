require "test_helper"
require "hive/commands/init"
require "hive/task_capture"
require "hive/task_meta"
require "hive/workflows"

class TaskCaptureTest < Minitest::Test
  include HiveTestHelper

  def test_exact_replay_finds_the_same_task_after_a_stage_move
    with_initialized_project do |project_root|
      capture = build_capture(project_root)

      first = capture.call
      moved = File.join(project_root, ".hive-state", "stages", "2-brainstorm", "patrol-fix-task")
      FileUtils.mkdir_p(File.dirname(moved))
      File.rename(first.folder, moved)
      replay = build_capture(project_root).call

      assert_equal true, first.created
      assert_equal false, replay.created
      assert_equal moved, replay.folder
      assert_equal "patrol-fix:capture:one", Hive::TaskMeta.read(moved).fetch(:idempotency_key)
    end
  end

  def test_conflicting_reuse_fails_closed_without_a_second_task
    with_initialized_project do |project_root|
      build_capture(project_root).call

      error = assert_raises(Hive::TaskCapture::IdempotencyConflict) do
        build_capture(project_root, fingerprint: "b" * 64, slug: "must-not-exist").call
      end

      assert_includes error.message, "different input or workflow"
      refute Dir.exist?(
        File.join(project_root, ".hive-state", "stages", "1-inbox", "must-not-exist")
      )
    end
  end

  def test_controller_candidate_writer_adds_typed_artifact_only_during_creation
    with_initialized_project do |project_root|
      writes = 0
      writer = lambda do |folder|
        writes += 1
        File.write(File.join(folder, "controller-relation.json"), "{}")
      end
      first = build_capture(project_root, candidate_writer: writer).call
      replay = build_capture(project_root, candidate_writer: writer).call

      assert first.created
      refute replay.created
      assert_equal 1, writes
      assert_equal "{}", File.read(File.join(first.folder, "controller-relation.json"))
    end
  end

  private

  def with_initialized_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io do
          Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call
        end
        yield project_root
      end
    end
  end

  def build_capture(project_root, fingerprint: "a" * 64, slug: "patrol-fix-task",
                    candidate_writer: nil)
    descriptor = Hive::Workflows::Registry.default
    Hive::TaskCapture.new(
      project_root: project_root,
      hive_state: File.join(project_root, ".hive-state"),
      workflow_info: {
        descriptor: descriptor,
        pin: false,
        managed: nil,
        managed_cfg: {},
        authored_digest: nil
      },
      slug: slug,
      state_bytes: "---\nslug: #{slug}\n---\n\n# #{slug}\n\n<!-- WAITING -->\n",
      idempotency_key: "patrol-fix:capture:one",
      input_fingerprint: fingerprint,
      candidate_writer: candidate_writer
    )
  end
end
