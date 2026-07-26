require "test_helper"
require "hive/artifacts/capture_policy"

class ArtifactsCapturePolicyTest < Minitest::Test
  FakeTask = Data.define(:folder, :slug, :project_root, :state_file, :worktree_path)

  def with_task
    Dir.mktmpdir("capture-policy") do |root|
      task_dir = File.join(root, ".hive-state", "stages", "7-artifacts", "demo-task")
      worktree = File.join(root, "worktree")
      FileUtils.mkdir_p([ task_dir, worktree ])
      state_file = File.join(task_dir, "artifact.md")
      File.write(state_file, "")
      yield FakeTask.new(
        folder: task_dir, slug: "demo-task", project_root: root,
        state_file: state_file, worktree_path: worktree
      )
    end
  end

  def test_visual_paths_are_required_and_receipt_is_generation_bound
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo",
        changed_paths: [ "web/app/views/tasks/show.html.erb" ],
        task_generation: "generation-1",
        base_sha: "a" * 40, head_sha: "b" * 40
      )

      receipt = policy.ensure!

      assert_equal "required", receipt.fetch("result")
      assert_equal "generation-1", receipt.fetch("task_generation")
      assert_equal "b" * 40, receipt.fetch("implementation_head")
      assert File.file?(File.join(task.folder, "capture-requirement.json"))
    end
  end

  def test_nonvisual_change_is_not_applicable_but_explicit_visual_request_promotes
    with_task do |task|
      plain = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "lib/hive/config.rb" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40,
        requested_outcome: "Refactor configuration"
      ).build
      explicit = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "lib/hive/config.rb" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40,
        requested_outcome: "Include a browser screenshot"
      ).build

      assert_equal "not_applicable", plain.fetch("result")
      assert_equal "required", explicit.fetch("result")
    end
  end

  def test_unverifiable_changed_paths_fail_closed_as_required
    with_task do |task|
      receipt = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [],
        task_generation: "g", base_sha: nil, head_sha: nil,
        requested_outcome: "Refactor configuration",
        evidence_complete: false
      ).build

      assert_equal "required", receipt.fetch("result")
      assert_match(/could not prove/, receipt.fetch("rationale"))
    end
  end

  def test_required_capture_cannot_be_demoted_without_confirmed_operator
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      policy.ensure!

      assert_raises(Hive::Artifacts::CapturePolicy::AuthorizationError) do
        policy.demote!(actor: "agent", rationale: "tool missing", confirmed: false)
      end
      receipt = policy.demote!(actor: "operator:local", rationale: "verified no visual delta", confirmed: true)
      assert_equal "not_applicable", receipt.fetch("result")
      assert_equal "confirmed_demotion", receipt.dig("override", "kind")
    end
  end

  def test_required_capture_verifies_schema_files_hashes_cleanup_and_accessibility
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      policy.ensure!
      media = File.join(task.folder, "media")
      FileUtils.mkdir_p(media)
      video = File.join(media, "demo.webm")
      File.binwrite(video, "playable-video")
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: File.join(task.folder, "runtime"),
        environment: {}, lifecycle_token: "token-123"
      )
      manifest = runtime.capture_manifest(
        task: task.slug, source_sha: "b" * 40,
        lock_digests: { "root" => "c" * 64, "web" => "d" * 64 },
        cache_key: "e" * 64,
        command: [ "hive", "web", "capture" ],
        fixture_ids: [ "synthetic-demo" ],
        media_paths: [ video ],
        status: "captured",
        cleanup: {
          "processes" => "clean", "port" => "released", "runtime" => "cleaned"
        },
        accessibility_assertions: [ "page heading is visible" ]
      )
      runtime.publish_manifest!(task_folder: task.folder, manifest: manifest)

      assert policy.capture_satisfied?

      File.binwrite(video, "tampered")
      refute policy.capture_satisfied?,
             "artifact bytes and SHA must still match at stage completion"
    end
  end
end
