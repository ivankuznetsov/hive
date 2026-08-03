require "test_helper"
require "hive/artifacts/capture_policy"

class ArtifactsCapturePolicyTest < Minitest::Test
  include HiveTestHelper

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

  def test_generated_markers_do_not_create_an_explicit_visual_request
    with_task do |task|
      File.write(File.join(task.folder, "idea.md"), "Refactor configuration\n")
      File.write(
        File.join(task.folder, "task.md"),
        "<!-- REVIEW_COMPLETE pass=1 browser=skipped -->\n"
      )

      requested = Hive::Artifacts::CapturePolicy.send(:requested_outcome, task)
      receipt = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "lib/hive/config.rb" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40,
        requested_outcome: requested
      ).build

      refute_match(/browser/, requested)
      assert_equal "not_applicable", receipt.fetch("result")
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

  def test_retained_v1_capture_manifest_remains_satisfactory_after_v2_migration
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      policy.ensure!
      media = File.join(task.folder, "media")
      FileUtils.mkdir_p(media)
      image = File.join(media, "legacy.png")
      File.binwrite(image, "legacy-png")
      manifest = {
        "schema" => "hive-artifact-capture",
        "schema_version" => 1,
        "status" => "captured",
        "task" => task.slug,
        "source_sha" => "b" * 40,
        "lock_digests" => { "root" => "c" * 64, "web" => "d" * 64 },
        "cache_key" => "e" * 64,
        "command" => [ "hive", "web", "capture" ],
        "environment_keys" => Hive::Web::CaptureRuntime::DISCLOSED_ENV_KEYS.sort,
        "fixture_ids" => [ "legacy-fixture" ],
        "started_at" => "2026-07-26T03:00:00Z",
        "finished_at" => "2026-07-26T03:01:00Z",
        "viewport" => { "width" => 1280, "height" => 800 },
        "accessibility_assertions" => [ "heading visible" ],
        "artifacts" => [
          {
            "file" => File.basename(image),
            "bytes" => File.size(image),
            "sha256" => Digest::SHA256.file(image).hexdigest
          }
        ],
        "cleanup" => {
          "port" => "released", "processes" => "clean", "runtime" => "cleaned"
        },
        "diagnostic" => nil
      }
      File.write(File.join(media, "capture-manifest.json"), JSON.generate(manifest))

      assert policy.capture_satisfied?
    end
  end

  def test_capture_manifest_consumer_ceiling_accepts_just_below_and_rejects_just_above
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      policy.ensure!
      media = File.join(task.folder, "media")
      FileUtils.mkdir_p(media)
      image = File.join(media, "provider.png")
      File.binwrite(image, "png")
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: File.join(task.folder, "runtime"),
        environment: {}, lifecycle_token: "token-123"
      )
      manifest = runtime.capture_manifest(
        task: task.slug,
        source_sha: "b" * 40,
        recorder: {
          "kind" => "project_provider", "name" => "fixture",
          "command" => [ "bin/provider" ]
        },
        environment_keys: [ "PATH" ],
        evidence: { "type" => "project_provider", "details" => {} },
        media_paths: [ image ],
        status: "captured",
        cleanup: {
          "port" => "released", "processes" => "clean", "runtime" => "cleaned"
        }
      )
      path = File.join(media, "capture-manifest.json")
      encoded = JSON.generate(manifest)
      limit = Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES

      File.binwrite(path, encoded + (" " * (limit - 1 - encoded.bytesize)))
      assert_equal limit - 1, File.size(path)
      assert policy.capture_satisfied?

      File.binwrite(path, encoded + (" " * (limit + 1 - encoded.bytesize)))
      assert_equal limit + 1, File.size(path)
      refute policy.capture_satisfied?
    end
  end

  def test_non_object_capture_manifests_fail_closed
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      policy.ensure!
      media = File.join(task.folder, "media")
      FileUtils.mkdir_p(media)
      path = File.join(media, "capture-manifest.json")
      invalid_manifests = {
        "array" => [],
        "null" => nil,
        "scalar recorder" => {
          "schema" => "hive-artifact-capture",
          "schema_version" => 2,
          "recorder" => "not-an-object"
        }
      }

      invalid_manifests.each do |shape, manifest|
        File.binwrite(path, JSON.generate(manifest))
        refute policy.capture_satisfied?, "#{shape} manifest must fail closed"
      end
    end
  end

  def test_for_task_collects_committed_staged_unstaged_and_untracked_paths
    with_task do |task|
      base = "a" * 40
      head = "b" * 40
      git_calls = []
      git = lambda do |_worktree, *args|
        git_calls << args
        case args
        when [ "rev-parse", "HEAD" ] then "#{head}\n"
        when [ "diff", "--name-only", "--no-ext-diff", "#{base}..HEAD", "--" ]
          "web/app/views/tasks/show.html.erb\n"
        when [ "diff", "--name-only", "--no-ext-diff", "--cached", "--" ]
          "web/app/javascript/controllers/poll_controller.js\n"
        when [ "diff", "--name-only", "--no-ext-diff", "--" ]
          "web/app/views/tasks/show.html.erb\n"
        when [ "ls-files", "--others", "--exclude-standard" ]
          "public/demo.png\n"
        else
          raise "unexpected git call: #{args.inspect}"
        end
      end
      pointer = ->(_task) { { "path" => task.worktree_path, "execute_base_head" => base } }
      generation = Data.define(:task_generation).new(task_generation: "generation-1")

      policy = with_replaced_singleton_method(
        Hive::Artifacts::CapturePolicy, :owned_pointer, pointer
      ) do
        with_replaced_singleton_method(Hive::Artifacts::CapturePolicy, :git, git) do
          with_replaced_singleton_method(
            Hive::Attempts::Generation, :resolve, ->(**) { generation }
          ) do
            Hive::Artifacts::CapturePolicy.for_task(task, project: "demo")
          end
        end
      end
      receipt = policy.build

      assert_equal "required", receipt.fetch("result")
      assert_equal base, receipt.fetch("implementation_base")
      assert_equal head, receipt.fetch("implementation_head")
      assert_equal(
        [
          "public/demo.png",
          "web/app/javascript/controllers/poll_controller.js",
          "web/app/views/tasks/show.html.erb"
        ],
        receipt.fetch("changed_paths")
      )
      assert_equal 5, git_calls.length
    end
  end

  def test_for_task_fails_closed_when_owned_pointer_cannot_be_proven
    with_task do |task|
      generation = Data.define(:task_generation).new(task_generation: "generation-2")
      policy = with_replaced_singleton_method(
        Hive::Artifacts::CapturePolicy,
        :owned_pointer,
        ->(_task) { raise Hive::WorktreeError, "pointer invalid" }
      ) do
        with_replaced_singleton_method(
          Hive::Attempts::Generation, :resolve, ->(**) { generation }
        ) do
          Hive::Artifacts::CapturePolicy.for_task(task, project: "demo")
        end
      end

      receipt = policy.build
      assert_equal "required", receipt.fetch("result")
      assert_nil receipt.fetch("implementation_base")
      assert_nil receipt.fetch("implementation_head")
      assert_match(/could not prove/, receipt.fetch("rationale"))
    end
  end

  def test_for_task_without_a_pointer_records_complete_nonvisual_evidence
    with_task do |task|
      generation = Data.define(:task_generation).new(task_generation: "generation-3")
      policy = with_replaced_singleton_method(
        Hive::Artifacts::CapturePolicy, :owned_pointer, ->(_task) { nil }
      ) do
        with_replaced_singleton_method(
          Hive::Attempts::Generation, :resolve, ->(**) { generation }
        ) do
          Hive::Artifacts::CapturePolicy.for_task(task, project: "demo")
        end
      end

      receipt = policy.build
      assert_equal "not_applicable", receipt.fetch("result")
      assert_equal [], receipt.fetch("changed_paths")
    end
  end

  def test_owned_pointer_delegates_the_canonical_task_identity
    with_task do |task|
      calls = []
      replacement = lambda do |folder, **identity|
        calls << [ folder, identity ]
        { "path" => task.worktree_path }
      end

      pointer = with_replaced_singleton_method(
        Hive::Worktree, :read_owned_pointer, replacement
      ) do
        Hive::Artifacts::CapturePolicy.send(:owned_pointer, task)
      end

      assert_equal task.worktree_path, pointer.fetch("path")
      assert_equal task.folder, calls.first.first
      assert_equal task.slug, calls.first.last.fetch(:slug)
      assert_equal task.project_root, calls.first.last.fetch(:project_root)
    end
  end

  def test_git_helper_returns_stdout_on_success
    output = Hive::Artifacts::CapturePolicy.send(
      :git, File.expand_path("../../..", __dir__),
      "rev-parse", "--is-inside-work-tree"
    )

    assert_equal "true", output.strip
  end

  def test_git_failure_is_classified_as_a_hive_error
    status = Struct.new(:success?).new(false)
    capture3 = ->(*) { [ "", "not a repository", status ] }

    error = with_replaced_singleton_method(Open3, :capture3, capture3) do
      assert_raises(Hive::Error) do
        Hive::Artifacts::CapturePolicy.send(:git, "/missing", "rev-parse", "HEAD")
      end
    end

    assert_match(/not a repository/, error.message)
  end

  def test_promote_records_operator_rationale_and_is_idempotent
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "lib/hive/config.rb" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40,
        clock: -> { Time.utc(2026, 7, 26, 3) }
      )

      promoted = policy.promote!(actor: "operator:local", rationale: "Needs a visual walkthrough")
      repeated = policy.promote!(actor: "operator:other", rationale: "ignored")

      assert_equal "required", promoted.fetch("result")
      assert_equal "promotion", promoted.dig("override", "kind")
      assert_equal "operator:local", promoted.dig("override", "actor")
      assert_equal promoted, repeated
    end
  end

  def test_demotion_rejects_a_stale_generation_receipt
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "current", base_sha: "a" * 40, head_sha: "b" * 40
      )
      stale = policy.build.merge("task_generation" => "stale")
      policy.define_singleton_method(:ensure!) { stale }

      error = assert_raises(Hive::Artifacts::CapturePolicy::AuthorizationError) do
        policy.demote!(
          actor: "operator:local", rationale: "Confirmed nonvisual", confirmed: true
        )
      end

      assert_match(/changed generation/, error.message)
    end
  end

  def test_invalid_capture_times_and_missing_media_fail_validation
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      receipt = policy.ensure!
      media = File.join(task.folder, "media")
      FileUtils.mkdir_p(media)
      image = File.join(media, "demo.png")
      File.binwrite(image, "png")
      runtime = Hive::Web::CaptureRuntime.new(
        source_root: "/source", runtime_root: File.join(task.folder, "runtime"),
        environment: {}, lifecycle_token: "token-123"
      )
      manifest = runtime.capture_manifest(
        task: task.slug, source_sha: receipt.fetch("implementation_head"),
        lock_digests: { "root" => "c" * 64, "web" => "d" * 64 },
        cache_key: "e" * 64, command: [ "hive", "web", "capture" ],
        fixture_ids: [ "synthetic-demo" ], media_paths: [ image ],
        status: "captured",
        cleanup: {
          "processes" => "clean", "port" => "released", "runtime" => "cleaned"
        },
        accessibility_assertions: [ "heading visible" ]
      )
      manifest["started_at"] = "not-a-time"
      runtime.publish_manifest!(task_folder: task.folder, manifest: manifest)
      refute policy.capture_satisfied?
      refute policy.send(
        :valid_capture_times?,
        { "started_at" => "not-a-time", "finished_at" => "also-invalid" }
      )

      manifest["started_at"] = "2026-07-26T03:00:00Z"
      manifest["finished_at"] = "2026-07-26T03:01:00Z"
      FileUtils.rm_f(image)
      runtime.publish_manifest!(task_folder: task.folder, manifest: manifest)
      refute policy.capture_satisfied?
    end
  end

  def test_corrupt_requirement_and_capture_manifest_are_reclassified_safely
    with_task do |task|
      policy = Hive::Artifacts::CapturePolicy.new(
        task: task, project: "demo", changed_paths: [ "web/app.css" ],
        task_generation: "g", base_sha: "a" * 40, head_sha: "b" * 40
      )
      File.write(policy.path, "{")

      receipt = policy.ensure!
      assert_equal "required", receipt.fetch("result")

      media = File.join(task.folder, "media")
      FileUtils.mkdir_p(media)
      File.write(File.join(media, "capture-manifest.json"), "{")
      refute policy.capture_satisfied?
    end
  end

  def test_requested_outcome_ignores_a_file_that_becomes_unreadable
    with_task do |task|
      idea = File.join(task.folder, "idea.md")
      File.write(idea, "browser screenshot")
      original_read = File.method(:read)
      replacement = lambda do |path, *args|
        raise Errno::EACCES, path if path == idea

        original_read.call(path, *args)
      end

      requested = with_replaced_singleton_method(File, :read, replacement) do
        Hive::Artifacts::CapturePolicy.send(:requested_outcome, task)
      end

      assert_equal "", requested
    end
  end
end
