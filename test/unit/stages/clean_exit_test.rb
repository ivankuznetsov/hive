require "test_helper"
require "hive/stages/clean_exit"
require "hive/config"
require "hive/task"

# Unit tests for the `Hive::Stages::CleanExit.run!` invariant. Every
# residue-handling branch runs in a real tmpdir with a real git repo so
# scope-check + sign-policy behaviour matches production exactly — no
# stubs, no mocks of the AutoCommit primitives.
class HiveStagesCleanExitTest < Minitest::Test
  include HiveTestHelper

  def setup
    @default_cfg = Hive::Config::DEFAULTS
  end

  def fake_task(slug = "demo-260528-aaaa")
    Object.new.tap do |task|
      task.define_singleton_method(:slug) { slug }
      task.define_singleton_method(:folder) { "/tmp/#{slug}-folder" }
      task.define_singleton_method(:state_file) { "/tmp/#{slug}.md" }
    end
  end

  def init_git(worktree_path)
    run!("git", "-C", worktree_path, "init", "-b", "main", "--quiet")
    run!("git", "-C", worktree_path, "config", "user.email", "t@example.com")
    run!("git", "-C", worktree_path, "config", "user.name", "T")
    run!("git", "-C", worktree_path, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree_path, "seed.txt"), "seed\n")
    run!("git", "-C", worktree_path, "add", ".")
    run!("git", "-C", worktree_path, "commit", "-m", "seed", "--quiet")
  end

  def test_clean_worktree_returns_clean
    with_tmp_dir do |worktree|
      init_git(worktree)

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :clean, result[:status]
    end
  end

  # Regression: babysitter dry-run runs leave a skip log + overlay-bin shims at
  # the worktree root. With those paths gitignored (see the repo `.gitignore`),
  # CleanExit's `git status --porcelain` reports nothing and the stage exits
  # clean — instead of `git add -A` staging them and the scope check failing
  # with :error reason=ensure_clean_on_exit_failed. The ignore patterns are
  # replicated here because the tmp repo has no inherited root `.gitignore`;
  # `dry_run_env_test.rb` separately asserts the real repo carries them.
  def test_gitignored_dry_run_residue_exits_clean
    with_tmp_dir do |worktree|
      init_git(worktree)
      File.write(File.join(worktree, ".gitignore"), <<~IGNORE)
        .babysitter-dry-run-skipped.log
        .babysitter-dry-run-plan.md
        .hive-babysitter-dry-run-bin/
      IGNORE
      run!("git", "-C", worktree, "add", ".gitignore")
      run!("git", "-C", worktree, "commit", "-m", "ignore dry-run artifacts", "--quiet")

      File.write(File.join(worktree, ".babysitter-dry-run-skipped.log"),
                 "git push origin HEAD:feature skipped\n")
      FileUtils.mkdir_p(File.join(worktree, ".hive-babysitter-dry-run-bin"))
      File.write(File.join(worktree, ".hive-babysitter-dry-run-bin", "git"),
                 "#!/usr/bin/env ruby\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :clean, result[:status],
                   "gitignored dry-run artifacts must not be flagged as out-of-scope residue"
    end
  end

  def test_residue_in_scope_is_auto_committed_with_canonical_message
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "lib"))
      File.write(File.join(worktree, "lib", "foo.rb"), "module Foo; end\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "8-finalize",
        task: fake_task, cfg: @default_cfg, reason: :finalize_entry_backstop
      )

      assert_equal :auto_committed, result[:status]
      assert_equal "chore(8-finalize): commit residual worktree changes",
                   result[:commit_subject]
      assert_kind_of String, result[:head]
      refute result[:head].empty?, "auto-committed HEAD must be reported"
      assert_includes Array(result[:paths]), "lib/foo.rb"

      # Subject + trailers byte-shape on HEAD.
      subject = `git -C #{worktree} log -1 --pretty=%s`.strip
      body = `git -C #{worktree} log -1 --pretty=%B`
      assert_equal "chore(8-finalize): commit residual worktree changes", subject
      assert_match(/Hive-Task-Slug: demo-260528-aaaa/, body)
      assert_match(/Hive-Stage: 8-finalize/, body)
      assert_match(/Hive-Auto-Commit: residue/, body)
      assert_match(/Hive-Auto-Commit-Reason: finalize_entry_backstop/, body)

      # And the worktree is now clean.
      porcelain = `git -C #{worktree} status --porcelain`
      assert porcelain.empty?, "auto-commit must clear the worktree"
    end
  end

  def test_residue_out_of_scope_returns_scope_violation_and_unstages
    with_tmp_dir do |worktree|
      init_git(worktree)
      # `unrelated/path.txt` matches no allowed_paths in the default
      # scope-check config; the violation must unstage and return the
      # offending paths to the caller.
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "4-execute",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :scope_violation, result[:status]
      assert_includes result[:paths] || [], "unrelated/path.txt"
      assert_match(/scope check failed/, result[:message])

      # Index must NOT carry the staged path after the violation.
      staged = `git -C #{worktree} diff --cached --name-only`.strip
      assert_empty staged, "scope_violation must unstage the offending paths"
      # And the worktree still has the residue file (we don't discard).
      assert File.exist?(File.join(worktree, "unrelated", "path.txt")),
             "scope_violation must not delete agent edits"
    end
  end

  def test_pre_fix_dirty_worktree_residue_bypasses_scope_check
    with_tmp_dir do |worktree|
      init_git(worktree)
      File.write(File.join(worktree, "operator-note.txt"), "manual residue\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg, reason: :pre_fix_dirty_worktree
      )

      assert_equal :auto_committed, result[:status]
      assert_includes Array(result[:paths]), "operator-note.txt"
      assert_empty `git -C #{worktree} status --porcelain`
      body = `git -C #{worktree} log -1 --pretty=%B`
      assert_includes body, "Hive-Auto-Commit-Reason: pre_fix_dirty_worktree"
    end
  end

  def test_residue_with_sign_policy_fail_under_gpgsign_returns_git_failed
    with_tmp_dir do |worktree|
      init_git(worktree)
      # Force commit.gpgsign=true so the `fail` sign policy denies.
      run!("git", "-C", worktree, "config", "commit.gpgsign", "true")
      File.write(File.join(worktree, "README.md"), "updated\n")

      cfg = deep_dup_default_cfg
      cfg["review"]["fix"]["auto_commit"]["sign_policy"] = "fail"

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: cfg
      )

      assert_equal :git_failed, result[:status]
      assert_match(/signing policy failed/, result[:message])
      # No commit landed.
      log = `git -C #{worktree} log --oneline -2`.lines
      assert_equal 1, log.size,
                   "sign-policy refusal must NOT produce a residue commit"
    end
  end

  def test_residue_with_disabled_scope_check_still_auto_commits
    with_tmp_dir do |worktree|
      init_git(worktree)
      File.write(File.join(worktree, "unrelated.txt"), "x\n")

      cfg = deep_dup_default_cfg
      cfg["review"]["fix"]["auto_commit"]["scope_check"]["enabled"] = false

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: cfg
      )

      assert_equal :auto_committed, result[:status]
      assert_includes Array(result[:paths]), "unrelated.txt"
    end
  end

  # A hung pre-commit hook or frozen git op used to pin the runner
  # indefinitely because `Open3.capture3` had no upper bound. The
  # bounded `capture_git_with_timeout` wrapper translates a
  # `Timeout::Error` into a `:git_failed` envelope with
  # `timed_out: true` and the canonical "timed out after 300s" message,
  # so callers (CleanExit, the with_stage_events hook) can mark the
  # task `:error reason=ensure_clean_on_exit_failed` instead of
  # blocking forever.
  def test_porcelain_status_timeout_surfaces_git_failed
    with_tmp_dir do |worktree|
      init_git(worktree)

      result = with_open3_capture3_stub(
        ->(argv) { argv.include?("status") }
      ) do
        Hive::Stages::CleanExit.run!(
          worktree_path: worktree, stage: "6-review",
          task: fake_task, cfg: @default_cfg
        )
      end

      assert_equal :git_failed, result[:status],
                   "a timed-out git status must surface as :git_failed"
      assert_match(/timed out after 300s/, result[:message])
    end
  end

  def test_git_add_timeout_surfaces_git_failed_with_unstage
    with_tmp_dir do |worktree|
      init_git(worktree)
      File.write(File.join(worktree, "lib.rb"), "x\n")

      result = with_open3_capture3_stub(
        ->(argv) { argv.include?("add") && argv.include?("-A") }
      ) do
        Hive::Stages::CleanExit.run!(
          worktree_path: worktree, stage: "6-review",
          task: fake_task, cfg: @default_cfg
        )
      end

      assert_equal :git_failed, result[:status]
      assert_match(/git add -A timed out/, result[:message])
    end
  end

  def test_commit_message_template_shape_is_byte_stable
    msg = Hive::Stages::CleanExit.commit_message(
      task: fake_task("slugged-260528-aaaa"),
      stage: "8-finalize",
      reason: :stage_exit
    )

    expected = <<~MSG.chomp
      chore(8-finalize): commit residual worktree changes

      Hive-Task-Slug: slugged-260528-aaaa
      Hive-Stage: 8-finalize
      Hive-Auto-Commit: residue
      Hive-Auto-Commit-Reason: stage_exit
    MSG
    assert_equal expected, msg
  end

  private

  def deep_dup_default_cfg
    require "yaml"
    YAML.unsafe_load(YAML.dump(Hive::Config::DEFAULTS))
  end

  # Replace `Open3.capture3` with a stub that raises `Timeout::Error`
  # whenever `predicate.call(argv)` returns truthy; otherwise delegates
  # to the real implementation. Restores the original method on exit
  # even when the block raises.
  def with_open3_capture3_stub(predicate)
    original = Open3.method(:capture3)
    Open3.singleton_class.send(:define_method, :capture3) do |*argv, **kwargs|
      raise Timeout::Error if predicate.call(argv)

      original.call(*argv, **kwargs)
    end
    yield
  ensure
    Open3.singleton_class.send(:define_method, :capture3) do |*argv, **kwargs|
      original.call(*argv, **kwargs)
    end
  end
end
