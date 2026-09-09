require "test_helper"
require "hive/task"
require "hive/stages/review"

class HiveStagesReviewPreFixCleanExitTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:folder, :slug, :state_file, keyword_init: true)

  def fake_task
    folder = Dir.mktmpdir("hive-review-task")
    FakeTask.new(
      folder: folder,
      slug: "demo-260530-aaaa",
      state_file: File.join(folder, "task.md")
    )
  end

  def teardown
    FileUtils.rm_rf(@task.folder) if @task
  end

  def test_prepare_worktree_for_fix_returns_clean_when_cleanup_reports_clean
    @task = fake_task
    status_calls = 0

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, lambda { |_path|
      status_calls += 1
      :dirty
    }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, ->(**_kwargs) { { status: :clean } }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal :clean, result
      end
    end

    assert_equal 1, status_calls
  end

  def test_prepare_worktree_for_fix_preserves_cleanup_git_failure
    @task = fake_task

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { :dirty }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, lambda { |**_kwargs|
        { status: :git_failed, message: "git status exploded" }
      }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal({ status: :git_failed, message: "git status exploded" }, result)
      end
    end
  end

  def test_prepare_worktree_for_fix_surfaces_safety_failure_detail
    @task = fake_task
    cleanup = {
      status: :safety_violation,
      message: "auto-commit safety check failed: wiki/link: staged symlinks are not eligible"
    }

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { :dirty }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, ->(**_kwargs) { cleanup }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal cleanup, result
        assert_includes result.fetch(:message), "staged symlinks"
      end
    end
  end

  def test_prepare_worktree_for_fix_maps_cleanup_config_error_to_typed_git_failure
    @task = fake_task

    with_replaced_singleton_method(Hive::Stages::Review, :worktree_status, ->(_path) { :dirty }) do
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, lambda { |**_kwargs|
        raise Hive::ConfigError, "bad sign_policy"
      }) do
        result = Hive::Stages::Review.send(:prepare_worktree_for_fix, @task, {}, "/worktree")

        assert_equal(
          { status: :git_failed, message: "invalid auto-commit config: bad sign_policy" },
          result
        )
      end
    end
  end

  def test_mark_pre_fix_clean_exit_failure_writes_canonical_lossless_recovery_marker
    @task = fake_task
    paths = [ "test/visual/home,desktop.png" ] +
            24.times.map { |index| "test/visual/task-#{index}.png" }
    cleanup = {
      status: :safety_violation,
      message: "oversized visual baselines",
      paths: paths
    }

    Hive::Stages::Review.send(:mark_pre_fix_clean_exit_failure, @task, cleanup, 2)

    marker = Hive::Markers.current(File.join(@task.folder, "task.md"))
    assert_equal :error, marker.name
    assert_equal "ensure_clean_on_exit_failed", marker.attrs.fetch("reason")
    assert_equal "review_pre_fix", marker.attrs.fetch("origin")
    assert_equal "safety_violation", marker.attrs.fetch("failure_kind")
    assert_equal "fix", marker.attrs.fetch("phase")
    assert_equal "2", marker.attrs.fetch("pass")
    assert_equal paths.sort,
                 JSON.parse(Base64.strict_decode64(marker.attrs.fetch("residue_paths_b64")))
    assert_operator marker.attrs.fetch("residue_paths").length, :<=, 200
    refute_includes marker.attrs.fetch("residue_paths"), "task-9.png"
  end

  def test_large_pre_fix_residue_keeps_marker_readable_and_paths_in_bounded_sidecar
    @task = fake_task
    paths = 12_000.times.map do |index|
      "test/visual/#{format('%05d', index)}-#{'baseline-' * 8}.png"
    end
    cleanup = {
      status: :safety_violation,
      message: "oversized visual baselines",
      paths: paths
    }

    Hive::Stages::Review.send(:mark_pre_fix_clean_exit_failure, @task, cleanup, 3)

    marker = Hive::Markers.current(File.join(@task.folder, "task.md"))
    assert_equal :error, marker.name
    assert_equal Hive::Stages::CleanExit::RESIDUE_PATHS_FILE,
                 marker.attrs.fetch("residue_paths_file")
    assert_equal paths.length.to_s, marker.attrs.fetch("residue_paths_count")
    refute marker.attrs.key?("residue_paths_b64")
    assert_operator marker.raw.bytesize, :<, Hive::Markers::MAX_MARKER_SCAN_BYTES

    stored = JSON.parse(
      File.read(File.join(@task.folder, Hive::Stages::CleanExit::RESIDUE_PATHS_FILE))
    )
    assert_equal paths, stored
  end

  def test_large_baseline_with_a_secret_becomes_recoverable_without_staging_source_residue
    @task = fake_task
    worktree = Dir.mktmpdir("hive-review-worktree")
    run!("git", "-C", worktree, "init", "-b", "main", "--quiet")
    run!("git", "-C", worktree, "config", "user.email", "t@example.com")
    run!("git", "-C", worktree, "config", "user.name", "T")
    run!("git", "-C", worktree, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree, "README.md"), "seed\n")
    run!("git", "-C", worktree, "add", ".")
    run!("git", "-C", worktree, "commit", "-m", "seed", "--quiet")
    FileUtils.mkdir_p(File.join(worktree, "test", "visual"))
    FileUtils.mkdir_p(File.join(worktree, "lib"))
    File.binwrite(
      File.join(worktree, "test", "visual", "task.png"),
      "ordinary content\n" * 300_000 + "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
    )
    File.write(File.join(worktree, "lib", "repair.rb"), "meaningful change\n")

    result = Hive::Stages::Review.send(
      :prepare_worktree_for_fix, @task, Hive::Config::DEFAULTS, worktree
    )
    Hive::Stages::Review.send(:mark_pre_fix_clean_exit_failure, @task, result, 1)

    assert_equal :safety_violation, result.fetch(:status)
    assert_equal [ "test/visual/task.png" ], result.fetch(:paths)
    assert_empty `git -C #{worktree} diff --cached --name-only`
    assert_equal [ "lib/repair.rb", "test/visual/task.png" ],
                 `git -C #{worktree} status --porcelain -uall`.lines.map { |line| line[3..].strip }.sort
    marker = Hive::Markers.current(@task.state_file)
    assert_equal :error, marker.name
    assert_equal "ensure_clean_on_exit_failed", marker.attrs.fetch("reason")
    assert_equal "review_pre_fix", marker.attrs.fetch("origin")
    assert_equal "safety_violation", marker.attrs.fetch("failure_kind")
  ensure
    FileUtils.rm_rf(worktree) if worktree
  end

  def test_review_run_stops_before_fix_agent_on_recoverable_pre_fix_residue
    root = Dir.mktmpdir("hive-review-project")
    slug = "review-residue-260824-abcd"
    folder = File.join(root, ".hive-state", "stages", "6-review", slug)
    worktree = File.join(root, "worktree")
    FileUtils.mkdir_p(File.join(folder, "reviews"))
    FileUtils.mkdir_p(worktree)
    run!("git", "-C", worktree, "init", "-b", "main", "--quiet")
    run!("git", "-C", worktree, "config", "user.email", "t@example.com")
    run!("git", "-C", worktree, "config", "user.name", "T")
    run!("git", "-C", worktree, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree, "README.md"), "seed\n")
    run!("git", "-C", worktree, "add", ".")
    run!("git", "-C", worktree, "commit", "-m", "seed", "--quiet")
    FileUtils.mkdir_p(File.join(worktree, "test", "visual"))
    File.binwrite(
      File.join(worktree, "test", "visual", "task.png"),
      "ordinary content\n" * 300_000 + "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
    )
    task = Hive::Task.new(folder)
    File.write(task.state_file, "---\nslug: #{slug}\n---\n")
    File.write(task.worktree_yml_path, { "path" => worktree, "branch" => slug }.to_yaml)
    File.write(File.join(folder, "reviews", "stub-reviewer-01.md"), "## High\n- [x] apply a fix\n")
    Hive::Markers.set(task.state_file, :review_waiting, pass: 1, escalations: 1)

    with_replaced_singleton_method(Hive::Stages::Review, :canonical_worktree_root, ->(_task, _cfg) { root }) do
      owned_pointer = ->(_folder, **_kwargs) { { "path" => worktree, "branch" => slug } }
      with_replaced_singleton_method(Hive::Worktree, :read_owned_pointer, owned_pointer) do
        with_replaced_singleton_method(Hive::Stages::Review, :reviewer_compare_ref, ->(_cfg, _ops) { "main" }) do
          result = Hive::Stages::Review.run!(task, { "review" => {} })

          assert_equal :review_error, result.fetch(:status)
          assert_equal "ensure_clean_on_exit_failed_pass_01", result.fetch(:commit)
        end
      end
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :error, marker.name
    assert_equal "ensure_clean_on_exit_failed", marker.attrs.fetch("reason")
    assert_equal "review_pre_fix", marker.attrs.fetch("origin")
    assert_equal "safety_violation", marker.attrs.fetch("failure_kind")
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_emit_pre_fix_clean_exit_event_is_best_effort
    @task = fake_task

    with_replaced_singleton_method(Hive::Events, :emit, ->(**_kwargs) { raise IOError, "blocked" }) do
      result = Hive::Stages::Review.send(
        :emit_pre_fix_clean_exit_event,
        @task,
        { head: "abc123", paths: [ "wiki/page.md" ] }
      )

      assert_nil result
    end
  end
end
