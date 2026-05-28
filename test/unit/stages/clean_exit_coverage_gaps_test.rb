require_relative "../../test_helper"

require "hive/markers"
require "hive/stages/auto_commit"
require "hive/stages/base"
require "hive/stages/clean_exit"
require "hive/stages/finalize"
require "hive/stages/review"
require "hive/worktree"

# Targeted coverage for branches the existing unit/integration tests
# don't reach. Each test below exists to keep one specific line in the
# 100%-line-coverage gate enforced by HIVE_COVERAGE_MIN_LINE=100.
# Grouped by source file so a future change touching one file doesn't
# require chasing tests across the suite.
class CleanExitCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  # Stand-in for Hive::Task with the minimal surface enforce_clean_exit!
  # and the log-residue helper need.
  Task = Struct.new(:folder, :state_file, :worktree_yml_path, :log_dir, :slug) do
    def respond_to_missing?(_name, _include_private = false); false; end
  end

  def make_task(dir, slug: "cov-260528-aaaa")
    folder = File.join(dir, "stage", slug)
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "task.md")
    File.write(state_file, "<!-- COMPLETE -->\n")
    log_dir = File.join(folder, "logs")
    Task.new(folder, state_file, File.join(folder, "worktree.yml"),
             log_dir, slug)
  end

  # --- base.rb:244 — unexpected CleanExit status falls through to else ---

  def test_enforce_clean_exit_returns_envelope_for_unknown_clean_exit_status
    with_tmp_dir do |dir|
      task = make_task(dir)
      worktree = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(task.worktree_yml_path, "path: #{worktree}\n")

      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, ->(**_kwargs) { { status: :surprise } }) do
        out = Hive::Stages::Base.send(:enforce_clean_exit!, task, {}, "8-finalize")

        assert_equal({ status: :surprise, overwrote_marker: false }, out,
                     "unknown CleanExit status must surface as overwrote_marker:false; line 244")
      end
    end
  end

  # --- base.rb:262-263 — generic StandardError swallowed with warn + nil ---

  def test_enforce_clean_exit_rescues_generic_standard_error
    with_tmp_dir do |dir|
      task = make_task(dir)
      worktree = File.join(dir, "worktree")
      FileUtils.mkdir_p(worktree)
      File.write(task.worktree_yml_path, "path: #{worktree}\n")

      out_capture = nil
      err_capture = nil
      with_replaced_singleton_method(Hive::Stages::CleanExit, :run!, ->(**_kwargs) { raise StandardError, "boom" }) do
        out_capture, err_capture = capture_io do
          assert_nil Hive::Stages::Base.send(:enforce_clean_exit!, task, {}, "8-finalize"),
                     "generic rescue must return nil; line 263"
        end
      end

      _ = out_capture
      assert_match(/ensure_clean_on_exit raised StandardError: boom/, err_capture,
                   "warn message documents the swallow; line 262")
    end
  end

  # --- base.rb:269 — safe_current_marker rescues StandardError ---

  def test_safe_current_marker_rescues_and_returns_nil
    with_replaced_singleton_method(Hive::Markers, :current, ->(_path) { raise "disk gone" }) do
      task = Task.new("/nonexistent", "/nonexistent/task.md", nil, nil, "x")
      assert_nil Hive::Stages::Base.send(:safe_current_marker, task),
                 "marker read failure must not propagate; line 269"
    end
  end

  # --- base.rb:279 — read_worktree_path rescues pointer-read failure ---

  def test_read_worktree_path_rescues_pointer_read_failure
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.worktree_yml_path, "path: /tmp/whatever\n")
      with_replaced_singleton_method(Hive::Worktree, :read_pointer, ->(_folder) { raise "yaml corrupt" }) do
        assert_nil Hive::Stages::Base.send(:read_worktree_path, task),
                   "corrupt worktree.yml must not crash; line 279"
      end
    end
  end

  # --- clean_exit.rb:58 — staged_auto_commit_paths failure path ---

  def test_clean_exit_run_returns_git_failed_when_staged_paths_fails
    fake_add = { success: true, stdout: "", stderr: "", timed_out: false, message: nil }
    fake_reset = { success: true, message: nil, timed_out: false }
    fake_staged = { success: false, message: "git diff --cached failed: lock" }

    capture = ->(argv, **_kw) { argv.include?("add") ? fake_add : fake_reset }

    with_replaced_singleton_method(Hive::Stages::CleanExit, :porcelain_status,
                                   ->(_path) { { status: :ok, porcelain: "M wiki/foo.md\n" } }) do
      with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
        with_replaced_singleton_method(Hive::Stages::AutoCommit, :staged_auto_commit_paths,
                                       ->(_path) { fake_staged }) do
          out = run_clean_exit
          assert_equal :git_failed, out[:status], "staged-paths failure → :git_failed; line 58"
          assert_match(/git diff --cached failed/, out[:message])
        end
      end
    end
  end

  # --- clean_exit.rb:76 — auto_commit_git_commit failure path ---

  def test_clean_exit_run_returns_git_failed_when_git_commit_fails
    fake_add = { success: true, stdout: "", stderr: "", timed_out: false, message: nil }
    fake_reset = { success: true, message: nil, timed_out: false }
    fake_staged = { success: true, paths: [ "wiki/foo.md" ], message: nil }
    fake_commit = { success: false, message: "git commit: signature required" }

    capture = ->(argv, **_kw) { argv.include?("add") ? fake_add : fake_reset }

    with_replaced_singleton_method(Hive::Stages::CleanExit, :porcelain_status,
                                   ->(_path) { { status: :ok, porcelain: "M wiki/foo.md\n" } }) do
      with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
        with_replaced_singleton_method(Hive::Stages::AutoCommit, :staged_auto_commit_paths,
                                       ->(_path) { fake_staged }) do
          with_replaced_singleton_method(Hive::Stages::AutoCommit, :auto_commit_scope_check_enabled?,
                                         ->(_cfg) { false }) do
            with_replaced_singleton_method(Hive::Stages::AutoCommit, :auto_commit_sign_policy_for,
                                           ->(_cfg) { :inherit }) do
              with_replaced_singleton_method(Hive::Stages::AutoCommit, :auto_commit_sign_policy_failure,
                                             ->(_p, _s) { nil }) do
                with_replaced_singleton_method(Hive::Stages::AutoCommit, :auto_commit_git_commit,
                                               ->(_p, _s, _m) { fake_commit }) do
                  out = run_clean_exit
                  assert_equal :git_failed, out[:status], "commit failure → :git_failed; line 76"
                  assert_match(/signature required/, out[:message])
                end
              end
            end
          end
        end
      end
    end
  end

  # --- clean_exit.rb:137, 138 — reset failure during failure_with_unstage ---

  def test_failure_with_unstage_concatenates_reset_failure_message
    reset_fail = { success: false, message: "git reset: index.lock present", timed_out: true }

    with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout,
                                   ->(_argv, **_kw) { reset_fail }) do
      out = Hive::Stages::CleanExit.send(
        :failure_with_unstage, "/x", :scope_violation,
        message: "scope rejected wiki/foo", paths: [ "wiki/foo" ]
      )

      assert_equal :scope_violation, out[:status]
      assert_match(/scope rejected wiki\/foo; git reset: index.lock present/, out[:message],
                   "concatenated message preserves both failures; line 137")
      assert_equal true, out[:timed_out], "timed_out propagates from reset failure; line 138"
    end
  end

  # --- finalize.rb:224 — log writer rescue when File.write raises ---

  def test_finalize_residue_log_writer_rescues_write_failure
    with_tmp_dir do |dir|
      task = make_task(dir)
      result = { head: "abc123", commit_subject: "chore(8-finalize): commit residual worktree changes",
                 paths: [ "wiki/foo.md" ] }

      with_replaced_singleton_method(File, :write, ->(*_args) { raise Errno::EACCES, "Permission denied" }) do
        _, err = capture_io do
          Hive::Stages::Finalize.send(:log_finalize_residue_committed, task, result)
        end

        assert_match(/finalize-residue log write failed.*Errno::EACCES/, err,
                     "log-write failure must warn but not raise; line 224")
      end
    end
  end

  # --- review.rb shims (1557, 1569, 1573, 1674) ---
  # These are module_function shims that delegate to Hive::Stages::AutoCommit.
  # Coverage lands on the line that performs the delegation when called.

  def test_review_shims_delegate_to_auto_commit
    cfg = { "review" => { "fix" => { "auto_commit" => { "scope_check" => { "allowed_paths" => [ "wiki/**" ] } } } } }

    # 1557 — auto_commit_scope_config
    scope_cfg = Hive::Stages::Review.send(:auto_commit_scope_config, cfg)
    refute_nil scope_cfg, "shim must delegate and return the AutoCommit-resolved scope config"

    # 1569 — normalize_staged_path
    assert_equal "wiki/foo.md",
                 Hive::Stages::Review.send(:normalize_staged_path, "wiki/foo.md"),
                 "shim must delegate to AutoCommit.normalize_staged_path"

    # 1573 — staged_path_matches_glob?
    assert Hive::Stages::Review.send(:staged_path_matches_glob?, "wiki/**", "wiki/notes.md"),
           "shim must delegate to AutoCommit.staged_path_matches_glob?"

    # 1674 — auto_commit_signing_error?
    refute Hive::Stages::Review.send(:auto_commit_signing_error?, "unrelated"),
           "shim must delegate to AutoCommit.auto_commit_signing_error?"
    assert Hive::Stages::Review.send(:auto_commit_signing_error?,
                                     "gpg: signing failed: No secret key"),
           "delegation must surface AutoCommit's truthy verdict for signing-error messages"
  end

  private

  def run_clean_exit
    Hive::Stages::CleanExit.run!(
      worktree_path: "/x",
      stage: "8-finalize",
      task: Task.new("/x", "/x/task.md", "/x/wt.yml", "/x/logs", "cov-260528-aaaa"),
      cfg: {},
      reason: :stage_exit
    )
  end
end
