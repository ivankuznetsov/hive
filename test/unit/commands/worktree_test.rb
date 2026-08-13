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

  def test_commit_message_rejects_control_characters
    out, error = run_command_error("commit-residue", message: "fix residue\rfor me")

    assert_instance_of Hive::UsageError, error
    assert_equal "invalid_arguments", JSON.parse(out).fetch("error_kind")
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
