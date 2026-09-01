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

  def test_input_identity_and_attachment_validation_fail_closed
    with_tmp_dir do |dir|
      base = capture_options(dir)
      [
        [ { slug: "../unsafe" }, Hive::TaskCapture::SlugCollisionError ],
        [ { idempotency_key: "" }, Hive::TaskCapture::IdempotencyConflict ],
        [ { input_fingerprint: "BAD" }, Hive::TaskCapture::IdempotencyConflict ]
      ].each do |overrides, error_class|
        capture = Hive::TaskCapture.new(**base.merge(overrides))
        assert_raises(error_class) { capture.send(:validate_inputs!) }
      end

      attachment = Hive::TaskCapture::Attachment.new(
        snapshot_path: "/tmp/source", destination: "../bad", name: "../bad", sha256: "a" * 64
      )
      capture = Hive::TaskCapture.new(**base.merge(attachments: [ attachment ]))
      assert_raises(Hive::TaskCapture::InvalidAttachmentError) do
        capture.send(:validate_inputs!)
      end

      empty_workflow = Struct.new(:id, :stages).new(:empty, [])
      capture = Hive::TaskCapture.new(
        **base.merge(workflow_info: base.fetch(:workflow_info).merge(descriptor: empty_workflow))
      )
      assert_raises(Hive::ConfigError) { capture.send(:validate_inputs!) }
    end
  end

  def test_initial_marker_is_written_during_capture
    with_initialized_project do |project_root|
      options = capture_options(project_root).merge(
        hive_state: File.join(project_root, ".hive-state"),
        initial_marker: { name: :waiting, attrs: { reason: "imported" } }
      )

      result = Hive::TaskCapture.new(**options).call

      state_file = Hive::Workflows::Registry.default.stages.first.state_file
      marker = Hive::Markers.current(File.join(result.folder, state_file))
      assert_equal :waiting, marker.name
      assert_equal "imported", marker.attrs.fetch("reason")
      bounded = Hive::TaskProjection::Reader.new(
        task_folder: result.folder
      ).read_routine(marker: marker)
      assert bounded.current?
      assert_equal "current", bounded.state
      refute File.exist?(File.join(result.folder, "task-journal.jsonl"))
    end
  end

  def test_managed_selection_drift_is_rejected
    with_tmp_dir do |dir|
      managed = {
        "source_commit" => "a" * 40,
        "manifest_digest" => "b" * 64,
        "configuration_digest" => "c" * 64
      }
      options = capture_options(dir)
      capture = Hive::TaskCapture.new(
        **options.merge(
          workflow_info: options.fetch(:workflow_info).merge(managed: managed)
        )
      )

      assert_raises(Hive::ConcurrentRunError) do
        capture.send(:validate_stable_selection!, managed.merge("source_commit" => "d" * 40))
      end
    end
  end

  private

  def capture_options(project_root)
    {
      project_root: project_root,
      hive_state: File.join(project_root, ".hive-state"),
      workflow_info: {
        descriptor: Hive::Workflows::Registry.default,
        pin: false, managed: nil, managed_cfg: {}, authored_digest: nil
      },
      slug: "patrol-fix-task",
      state_bytes: "# Task\n",
      idempotency_key: "patrol-fix:capture:one",
      input_fingerprint: "a" * 64
    }
  end

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
