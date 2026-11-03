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

  def test_idempotent_replay_returns_before_candidate_validation
    with_initialized_project do |project_root|
      first = build_capture(project_root).call
      validations = 0
      replay = build_capture(
        project_root,
        candidate_validator: lambda do |_folder|
          validations += 1
          raise "candidate validation must not run for an exact replay"
        end
      ).call

      assert first.created
      refute replay.created
      assert_equal first.folder, replay.folder
      assert_equal 0, validations
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

  def test_task_creation_requires_a_current_registered_project_identity
    capture = Hive::TaskCapture.allocate
    capture.instance_variable_set(:@project, nil)
    capture.instance_variable_set(:@project_root, "/tmp/unregistered-project")

    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [] }) do
      assert_raises(Hive::ConfigError) { capture.send(:project_identity!) }
    end
  end

  def test_feature_enabled_capture_pins_automatic_version_one_and_replay_retains_it
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      first = build_capture(root, cfg: cfg).call
      plan = Hive::TaskCapabilities::Store.new(first.folder).current
      assert_equal 1, plan.version
      assert plan.to_h.fetch("inputs").values.all? { |value| value == "automatic" }
      assert_equal "coding", Hive::TaskMeta.read(first.folder).fetch(:workflow)
      assert_nil Hive::Task.new(first.folder).managed_runtime_context("stages.plan")
      before = Dir.glob(File.join(first.folder, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h { |path| [ path, File.binread(path) ] }
      replay = build_capture(root, cfg: {}).call
      refute replay.created
      assert_equal plan.digest, Hive::TaskCapabilities::Store.new(replay.folder).current.digest
      assert_equal before, before.keys.to_h { |path| [ path, File.binread(path) ] }
      project_cfg = Hive::Config.load(root).merge("default_workflow" => "content")
      with_replaced_singleton_method(Hive::Config, :load, ->(_root) { project_cfg }) do
        assert_equal :coding, Hive::Task.new(first.folder).workflow.id
      end
    end
  end

  def test_disabled_and_noncoding_capture_remain_legacy
    with_initialized_project do |root|
      first = build_capture(root).call
      assert_nil Hive::TaskCapabilities::Store.new(first.folder).current
      refute Hive::TaskMeta.read(first.folder).key?(:task_capabilities)
      refute File.exist?(File.join(first.folder, "execution-plan-current.json"))
      options = capture_options(root)
      options[:workflow_info] = options.fetch(:workflow_info).merge(
        descriptor: Hive::Workflows::Registry.fetch(:content), managed_cfg: { "task_capabilities" => { "enabled" => true } }
      )
      options[:slug] = "content-capability-task"
      options[:idempotency_key] = "other-task"
      result = Hive::TaskCapture.new(**options).call
      assert_nil Hive::TaskCapabilities::Store.new(result.folder).current
      refute Hive::TaskMeta.read(result.folder).key?(:task_capabilities)
    end
  end

  def test_feature_enabled_capture_commit_failure_removes_all_substrate
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      capture = build_capture(root, cfg: cfg)
      with_replaced_singleton_method(capture.instance_variable_get(:@git_ops), :hive_commit, ->(**_args) { raise "commit failure" }) do
        assert_raises(RuntimeError) { capture.call }
      end
      refute File.exist?(File.join(root, ".hive-state/stages/1-inbox/patrol-fix-task"))
    end
  end

  def test_initial_pointer_publication_failure_rolls_back_the_entire_capture
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      original = Hive::AtomicFile.method(:write)
      with_replaced_singleton_method(Hive::AtomicFile, :write, lambda { |path, *args, **kwargs|
        raise "pointer publication failed" if File.basename(path) == "execution-plan-current.json"
        original.call(path, *args, **kwargs)
      }) do
        assert_raises(RuntimeError) { build_capture(root, cfg: cfg).call }
      end
      refute File.exist?(File.join(root, ".hive-state/stages/1-inbox/patrol-fix-task"))
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
                    candidate_validator: nil, candidate_writer: nil, cfg: {})
    descriptor = Hive::Workflows::Registry.default
    Hive::TaskCapture.new(
      project_root: project_root,
      hive_state: File.join(project_root, ".hive-state"),
      workflow_info: {
        descriptor: descriptor,
        pin: false,
        managed: nil,
        managed_cfg: cfg,
        authored_digest: nil
      },
      slug: slug,
      state_bytes: "---\nslug: #{slug}\n---\n\n# #{slug}\n\n<!-- WAITING -->\n",
      idempotency_key: "patrol-fix:capture:one",
      input_fingerprint: fingerprint,
      candidate_validator: candidate_validator,
      candidate_writer: candidate_writer
    )
  end
end

class TaskCaptureTest
  def test_concurrent_first_captures_persist_exactly_one_project_adoption_notice
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      children = %w[first-task second-task].map do |slug|
        fork do
          options = capture_options(root)
          options[:slug] = slug
          options[:idempotency_key] = slug
          options[:workflow_info] = options.fetch(:workflow_info).merge(managed_cfg: cfg)
          Hive::TaskCapture.new(**options).call
          exit! 0
        rescue StandardError => error
          warn error.full_message
          exit! 1
        end
      end
      children.each do |pid|
        Process.wait(pid)
        assert $?.success?
      end
      path = File.join(root, ".hive-state/task-capabilities-adoption.json")
      notice = JSON.parse(File.read(path))
      assert_includes %w[first-task second-task], notice.dig("task", "slug")
      history = Hive::GitOps.new(root).run_git!("-C", File.join(root, ".hive-state"), "log", "--format=%H", "--", "task-capabilities-adoption.json").lines
      assert_equal 1, history.length
      assert_equal 2, Dir.glob(File.join(root, ".hive-state/stages/1-inbox/*/execution-plan-current.json")).length
    end
  end

  def test_adoption_notice_rolls_back_on_commit_failure_and_can_be_emitted_later
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      capture = build_capture(root, cfg: cfg)
      ops = capture.instance_variable_get(:@git_ops)
      with_replaced_singleton_method(ops, :hive_commit, ->(**) { raise Hive::GitError, "commit failed" }) do
        assert_raises(Hive::GitError) { capture.call }
      end
      notice = File.join(root, ".hive-state/task-capabilities-adoption.json")
      refute File.exist?(notice)
      assert build_capture(root, cfg: cfg).call.created
      assert File.file?(notice)
    end
  end
end

class TaskCaptureTest
  def test_pointer_failure_cleans_registration_so_same_slug_retry_with_next_id_succeeds
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      original = Hive::AtomicFile.method(:write)
      with_replaced_singleton_method(Hive::AtomicFile, :write, lambda { |path, *args, **kwargs|
        raise "pointer failed" if File.basename(path) == "execution-plan-current.json"
        original.call(path, *args, **kwargs)
      }) do
        assert_raises(RuntimeError) { build_capture(root, cfg: cfg).call }
      end
      result = build_capture(root, cfg: cfg).call
      assert result.created
      assert Hive::TaskCapabilities::Store.new(result.folder).current
    end
  end

  def test_rollback_refusal_preserves_referenced_task_and_notice_for_repair
    with_initialized_project do |root|
      cfg = { "task_capabilities" => { "enabled" => true } }
      capture = build_capture(root, cfg: cfg)
      folder = File.join(root, ".hive-state/stages/1-inbox/patrol-fix-task")
      database = Hive::Lock.task_lease_repository.database
      with_replaced_singleton_method(capture.instance_variable_get(:@git_ops), :hive_commit, lambda { |**|
        id = Hive::TaskMeta.read(folder).fetch(:id).to_s
        database.transaction do |db|
          db[:payload_references].insert(payload_id: "capture-reference", task_id: id, kind: "capture", relative_path: "state.json", state: "open", created_at: Time.now.utc.iso8601)
        end
        raise Hive::GitError, "commit failed"
      }) do
        assert_raises(Hive::RuntimeControlPlane::IdentityError) { capture.call }
      end
      assert File.directory?(folder)
      assert Hive::TaskCapabilities::Store.new(folder).current
      assert File.file?(File.join(root, ".hive-state/task-capabilities-adoption.json"))
    end
  end
end
