require "test_helper"
require "json"
require "hive/commands/worktree"

class HiveCommandsWorktreeTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(
    :slug, :stage_index, :stage_name, :folder, :state_file, :project_root, :project_name,
    keyword_init: true
  )

  def setup
    @root = Dir.mktmpdir("hive-worktree-command")
    @worktree = File.join(@root, "worktree")
    FileUtils.mkdir_p(@worktree)
    run!("git", "-C", @worktree, "init", "-b", "main", "--quiet")
    run!("git", "-C", @worktree, "config", "user.email", "t@example.com")
    run!("git", "-C", @worktree, "config", "user.name", "T")
    run!("git", "-C", @worktree, "config", "commit.gpgsign", "false")
    File.write(File.join(@worktree, "seed.txt"), "seed\n")
    run!("git", "-C", @worktree, "add", ".")
    run!("git", "-C", @worktree, "commit", "-m", "seed", "--quiet")

    folder = File.join(@root, ".hive-state", "stages", "6-review", "demo-260813-abcd")
    FileUtils.mkdir_p(folder)
    @task = FakeTask.new(
      slug: "demo-260813-abcd", stage_index: 6, stage_name: "review",
      folder: folder, state_file: File.join(folder, "task.md"),
      project_root: @root, project_name: "demo"
    )
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed", residue_paths: "wiki/residue.md"
    )
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_status_emits_exact_machine_readable_residue
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    payload = run_command("status")

    assert_equal "hive-worktree", payload.fetch("schema")
    assert_equal "status", payload.fetch("action")
    assert_equal [ "wiki/residue.md" ], payload.fetch("residue_paths")
    assert_equal 1, payload.fetch("untracked_count")
    assert_equal "hive status --json", payload.dig("next_action", "command")
  end

  def test_status_renders_human_readable_recovery_details
    out, = capture_io do
      with_resolved_task do
        Hive::Commands::Worktree.new(
          "status", @task.slug,
          pointer_resolver: ->(_task, _cfg) { @worktree }
        ).call
      end
    end

    assert_includes out, "demo-260813-abcd: status"
    assert_includes out, "worktree: #{@worktree}"
    assert_includes out, "branch: main"
    assert_match(/head: [0-9a-f]+/, out)
    assert_includes out, "residue: (clean)"
    assert_includes out, "next: hive status --json"
  end

  def test_status_resolves_the_strict_owned_pointer_by_default
    canonical_input = nil
    pointer_args = nil
    worktree = @worktree
    canonical_root = "/canonical/worktrees"

    with_replaced_singleton_method(Hive::Worktree, :canonical_root, lambda { |path|
      canonical_input = path
      canonical_root
    }) do
      with_replaced_singleton_method(Hive::Worktree, :read_owned_pointer, lambda { |folder, **kwargs|
        pointer_args = [ folder, kwargs ]
        { "path" => worktree }
      }) do
        out, = capture_io do
          with_resolved_task do
            Hive::Commands::Worktree.new("status", @task.slug, json: true).call
          end
        end

        assert_equal @worktree, JSON.parse(out).fetch("worktree_path")
      end
    end

    assert_equal @task.project_root, canonical_input
    assert_equal(
      [
        @task.folder,
        {
          project_root: @task.project_root, slug: @task.slug,
          expected_root: canonical_root
        }
      ],
      pointer_args
    )
  end

  def test_error_envelope_kinds_preserve_resolution_and_lock_failures
    errors = {
      Hive::AmbiguousSlug.new("ambiguous", slug: @task.slug, candidates: []) => "ambiguous_slug",
      Hive::InvalidTaskPath.new("invalid") => "invalid_task_path",
      Hive::ConcurrentRunError.new("locked") => "task_locked",
      StandardError.new("unexpected") => "error"
    }

    errors.each do |error, expected|
      assert_equal expected, command("status").envelope_error_kind(error), error.class.name
    end
  end

  def test_commit_residue_uses_clean_exit_guards_and_keeps_marker_for_coordinator
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    payload = run_command("commit-residue")

    assert_equal "commit-residue", payload.fetch("action")
    assert_equal [ "wiki/residue.md" ], payload.fetch("committed_paths")
    assert payload.fetch("clean")
    assert_equal "ensure_clean_on_exit_failed",
                 Hive::Markers.current(@task.state_file).attrs.fetch("reason")
    assert_equal "chore(6-review): commit residual worktree changes",
                 `git -C #{@worktree} log -1 --pretty=%s`.strip
  end

  def test_commit_residue_accepts_error_dirty_worktree_from_execute
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "dirty_worktree", marker_id: "execute-dirty-1", attempt_id: "attempt-1"
    )
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    payload = run_command("commit-residue")

    assert_equal "commit-residue", payload.fetch("action")
    assert_equal [ "wiki/residue.md" ], payload.fetch("committed_paths")
    assert payload.fetch("clean")
    marker = Hive::Markers.current(@task.state_file)
    assert_equal :error, marker.name
    assert_equal "dirty_worktree", marker.attrs.fetch("reason")
    assert_equal "execute-dirty-1", marker.attrs.fetch("marker_id")
  end

  def test_commit_residue_rejects_secret_content_without_committing_or_leaking_it
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    secret = "AKIAABCDEFGHIJKLMNOP"
    File.write(File.join(@worktree, "wiki", "residue.md"), "#{secret}\n")

    out, error = run_command_error("commit-residue")
    payload = JSON.parse(out)

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", payload.fetch("error_kind")
    refute_includes payload.fetch("message"), secret
    assert_equal "seed", `git -C #{@worktree} log -1 --pretty=%s`.strip
    assert File.exist?(File.join(@worktree, "wiki", "residue.md"))
  end

  def test_existing_secret_shaped_filename_is_redacted_from_status_and_commit_output
    secret = "AKIAABCDEFGHIJKLMNOP"
    path = "wiki/#{secret}.md"
    FileUtils.mkdir_p(File.dirname(File.join(@worktree, path)))
    File.write(File.join(@worktree, path), "baseline\n")
    run!("git", "-C", @worktree, "add", "--", path)
    run!("git", "-C", @worktree, "commit", "-m", "add legacy fixture", "--quiet")
    File.write(File.join(@worktree, path), "changed\n")

    status_payload = run_command("status")
    status_json = JSON.generate(status_payload)
    refute_includes status_json, secret
    assert_equal [ "wiki/[REDACTED:aws_access_key].md" ], status_payload.fetch("residue_paths")
    assert_equal "wiki/[REDACTED:aws_access_key].md",
                 status_payload.fetch("porcelain").fetch(0).fetch("path")

    commit_payload = run_command("commit-residue")
    commit_json = JSON.generate(commit_payload)
    refute_includes commit_json, secret
    assert_equal [ "wiki/[REDACTED:aws_access_key].md" ], commit_payload.fetch("committed_paths")
  end

  def test_discard_residue_removes_only_marker_recorded_paths
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    FileUtils.mkdir_p(File.join(@worktree, "lib"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "discard\n")
    File.write(File.join(@worktree, "lib", "keep.rb"), "keep\n")

    payload = run_command("discard-residue")

    assert_equal [ "wiki/residue.md" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "wiki", "residue.md"))
    assert File.exist?(File.join(@worktree, "lib", "keep.rb"))
    assert_equal [ "lib/keep.rb" ], payload.fetch("residue_paths")
  end

  def test_discard_residue_treats_pathspec_magic_as_a_literal_filename
    File.write(File.join(@worktree, "*"), "discard\n")
    File.write(File.join(@worktree, "operator-note"), "keep\n")
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed", residue_paths: "*"
    )

    payload = run_command("discard-residue")

    assert_equal [ "*" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "*"))
    assert File.exist?(File.join(@worktree, "operator-note"))
  end

  def test_discard_residue_preserves_comma_in_explicit_path
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "a,b.md"), "discard\n")

    payload = run_command("discard-residue", paths: [ "wiki/a,b.md" ])

    assert_equal [ "wiki/a,b.md" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "wiki", "a,b.md"))
  end

  def test_discard_residue_decodes_lossless_marker_paths
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "a,b.md"), "discard\n")
    encoded = Base64.strict_encode64(JSON.generate([ "wiki/a,b.md" ]))
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed", residue_paths: "wiki/a,b.md",
      residue_paths_b64: encoded
    )

    payload = run_command("discard-residue")

    assert_equal [ "wiki/a,b.md" ], payload.fetch("discarded_paths")
    refute File.exist?(File.join(@worktree, "wiki", "a,b.md"))
  end

  def test_discard_residue_restores_a_tracked_path_from_head
    File.write(File.join(@worktree, "seed.txt"), "changed\n")

    payload = run_command("discard-residue", paths: [ "seed.txt" ])

    assert_equal [ "seed.txt" ], payload.fetch("discarded_paths")
    assert_equal "seed\n", File.read(File.join(@worktree, "seed.txt"))
    assert payload.fetch("clean")
  end

  def test_discard_residue_rejects_paths_that_are_not_currently_dirty
    out, error = run_command_error("discard-residue", paths: [ "not-dirty.txt" ])

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
    assert_match(/not currently reported as residue/, error.message)
  end

  def test_discard_residue_rejects_non_normalized_paths
    out, error = run_command_error("discard-residue", paths: [ "../outside" ])

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
    assert_match(/normalized repository-relative paths/, error.message)
  end

  def test_discard_residue_rejects_invalid_encoded_marker_paths
    Hive::Markers.set(
      @task.state_file, :error,
      reason: "ensure_clean_on_exit_failed",
      residue_paths_b64: "not-base64"
    )

    out, error = run_command_error("discard-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_match(/invalid encoded paths/, error.message)
  end

  def test_mutation_requires_durable_residue_marker
    Hive::Markers.set(@task.state_file, :review_complete)
    FileUtils.mkdir_p(File.join(@worktree, "wiki"))
    File.write(File.join(@worktree, "wiki", "residue.md"), "residue\n")

    out, error = run_command_error("commit-residue")

    assert_instance_of Hive::WorktreeError, error
    assert_equal "worktree_error", JSON.parse(out).fetch("error_kind")
    assert_equal "seed", `git -C #{@worktree} log -1 --pretty=%s`.strip
  end

  def test_repair_requires_an_explicit_strategy
    out, error = run_command_error("repair")

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
  end

  def test_argument_validation_rejects_cross_action_options
    cases = [
      [ "future", {}, /unknown worktree subcommand/ ],
      [ "status", { paths: [ "wiki/a.md" ] }, /status does not accept/ ],
      [ "commit-residue", { strategy: "commit" }, /strategy applies only/ ],
      [ "commit-residue", { paths: [ "wiki/a.md" ] }, /paths applies only/ ],
      [ "discard-residue", { message: "commit this" }, /message applies only/ ]
    ]

    cases.each do |subcommand, options, expected_message|
      out, error = run_command_error(subcommand, **options)

      assert_instance_of Hive::UsageError, error
      assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
      assert_match expected_message, error.message
    end
  end

  def test_commit_message_rejects_control_characters
    out, error = run_command_error("commit-residue", message: "fix residue\rfor me")

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
  end

  def test_status_rejects_malformed_porcelain_records
    captured_argv = nil
    capture = lambda do |argv, **_kwargs|
      captured_argv = argv
      { success: true, stdout: "M malformed\0" }
    end

    with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
      error = assert_raises(Hive::WorktreeError) do
        command("status").send(:worktree_status, @worktree)
      end

      assert_match(/malformed porcelain data/, error.message)
    end
    assert_includes captured_argv, "status"
  end

  private

  def command(subcommand, **options)
    Hive::Commands::Worktree.new(
      subcommand,
      @task.slug,
      json: true,
      pointer_resolver: ->(_task, _cfg) { @worktree },
      **options
    )
  end

  def run_command(subcommand, **options)
    out, = capture_io do
      with_resolved_task { command(subcommand, **options).call }
    end
    JSON.parse(out)
  end

  def run_command_error(subcommand, **options)
    error = nil
    out, = capture_io do
      with_resolved_task do
        error = assert_raises(Hive::Error) { command(subcommand, **options).call }
      end
    end
    [ out, error ]
  end

  def with_resolved_task
    original_resolve = Hive::TaskResolver.instance_method(:resolve)
    original_load = Hive::Config.method(:load)
    task = @task
    Hive::TaskResolver.define_method(:resolve) { task }
    Hive::Config.define_singleton_method(:load) { |_root| Hive::Config::DEFAULTS }
    yield
  ensure
    Hive::TaskResolver.define_method(:resolve, original_resolve)
    Hive::Config.define_singleton_method(:load, original_load)
  end
end
