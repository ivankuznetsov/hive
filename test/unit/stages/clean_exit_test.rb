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

  def test_scanner_unavailability_leaves_residue_uncommitted
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "lib"))
      path = File.join(worktree, "lib", "example.rb")
      File.write(path, "module Example; end\n")
      head = run!("git", "-C", worktree, "rev-parse", "HEAD")
      unavailable = ->(*) { raise Hive::SecretScanner::Unavailable, "scanner unavailable" }
      with_replaced_singleton_method(Hive::SecretScanner, :staged_findings, unavailable) do
        result = Hive::Stages::CleanExit.run!(
          worktree_path: worktree, stage: "6-review", task: fake_task, cfg: @default_cfg
        )
        assert_equal :git_failed, result[:status]
        assert_includes result[:message], "scanner unavailable"
      end
      assert_equal head, run!("git", "-C", worktree, "rev-parse", "HEAD")
      assert_equal "module Example; end\n", File.read(path)
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

  def test_out_of_scope_secret_shaped_path_is_redacted
    with_tmp_dir do |worktree|
      init_git(worktree)
      secret = "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "#{secret}.txt"), "ordinary content\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :scope_violation, result[:status]
      refute_includes result[:message], secret
      refute_includes result.fetch(:paths).join, secret
    end
  end

  def test_allowed_path_symlink_returns_safety_violation_and_unstages
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      File.symlink("/tmp/operator-secret", File.join(worktree, "wiki", "reference.md"))

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_equal [ "wiki/reference.md" ], result[:paths]
      assert_match(/staged symlinks/, result[:message])
      assert_empty `git -C #{worktree} diff --cached --name-only`
      assert File.symlink?(File.join(worktree, "wiki", "reference.md"))
    end
  end

  def test_pathspec_magic_filename_cannot_hide_staged_symlink
    with_tmp_dir do |worktree|
      init_git(worktree)
      File.symlink("/tmp/operator-secret", File.join(worktree, ":(literal)evil.gemspec"))

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_equal [ ":(literal)evil.gemspec" ], result[:paths]
      assert_match(/staged symlinks/, result[:message])
      assert_empty `git -C #{worktree} diff --cached --name-only`
    end
  end

  def test_allowed_path_secret_content_returns_redacted_safety_violation
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      secret = "AWS_ACCESS_KEY_ID=ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      File.write(File.join(worktree, "wiki", "migration-notes.md"), "#{secret}\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_equal [ "wiki/migration-notes.md" ], result[:paths]
      assert_match(/secret detectors/, result[:message])
      refute_includes result[:message], secret
      assert_empty `git -C #{worktree} diff --cached --name-only`
      assert File.exist?(File.join(worktree, "wiki", "migration-notes.md"))
    end
  end

  def test_unrelated_edit_preserves_committed_secret_fixture
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      path = File.join(worktree, "wiki", "detector-fixture.md")
      File.write(path, "fake detector fixture: ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}\n")
      run!("git", "-C", worktree, "add", "wiki/detector-fixture.md")
      run!("git", "-C", worktree, "commit", "-m", "add detector fixture", "--quiet")
      File.write(path, "ordinary documentation update\n", mode: "a")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :auto_committed, result[:status]
      assert_empty `git -C #{worktree} status --porcelain`
    end
  end

  def test_changed_secret_in_tracked_file_returns_safety_violation
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      path = File.join(worktree, "wiki", "detector-fixture.md")
      File.write(path, "fake detector fixture: ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}\n")
      run!("git", "-C", worktree, "add", "wiki/detector-fixture.md")
      run!("git", "-C", worktree, "commit", "-m", "add detector fixture", "--quiet")
      File.write(path, "replacement: ghp_#{"bC4eF7hI0kL3nO6qR9tU2wX5zA8cD1fG4iJ7"}\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_match(/secret detectors/, result[:message])
      refute_includes result[:message], "ghp_#{"bC4eF7hI0kL3nO6qR9tU2wX5zA8cD1fG4iJ7"}"
    end
  end

  def test_test_password_literal_returns_safety_violation
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "test", "integration"))
      File.write(
        File.join(worktree, "test", "integration", "login_test.rb"),
        "@operator.password = \"password\"\n"
      )

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_match(/generic-password/, result[:message])
      refute_empty `git -C #{worktree} status --porcelain`
    end
  end

  def test_exact_guardrail_waiver_releases_the_same_secret_from_clean_exit
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "test", "integration"))
      content = "@operator.password = \"password\"\n"
      File.write(File.join(worktree, "test", "integration", "login_test.rb"), content)
      hit = Hive::SecretPatterns.scan(content).find do |candidate|
        candidate[:name] == :password_assignment
      end
      cfg = deep_dup_default_cfg
      cfg["review"]["fix"]["guardrail"] = { "waivers" => [
        {
          "pattern" => "secrets_pattern_match.password_assignment",
          "sha256" => hit.fetch(:sha256)
        }
      ] }

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: cfg
      )

      assert_equal :auto_committed, result[:status]
      assert_empty `git -C #{worktree} status --porcelain`
    end
  end

  def test_non_placeholder_password_in_test_tree_returns_safety_violation
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "test", "integration"))
      File.write(
        File.join(worktree, "test", "integration", "login_test.rb"),
        "@operator.password = \"project-secret-42\"\n"
      )

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_match(/secret detectors/, result[:message])
    end
  end

  def test_new_secret_shaped_path_is_rejected_and_redacted
    with_tmp_dir do |worktree|
      init_git(worktree)
      secret = "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      File.write(File.join(worktree, "wiki", "#{secret}.md"), "ordinary content\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_match(/staged path matches secret detectors/, result[:message])
      refute_includes result[:message], secret
      refute_includes result.fetch(:paths).join, secret
    end
  end

  def test_binary_allowed_path_secret_content_returns_redacted_safety_violation
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      secret = "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      File.binwrite(File.join(worktree, "wiki", "migration-key.bin"), "\x00#{secret}\x00".b)

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_equal [ "wiki/migration-key.bin" ], result[:paths]
      assert_match(/secret detectors/, result[:message])
      refute_includes result[:message], secret
      assert_empty `git -C #{worktree} diff --cached --name-only`
    end
  end

  def test_safety_gate_still_applies_when_filename_scope_check_is_disabled
    with_tmp_dir do |worktree|
      init_git(worktree)
      File.symlink("/tmp/operator-secret", File.join(worktree, "unrelated-link"))
      cfg = deep_dup_default_cfg
      cfg["review"]["fix"]["auto_commit"]["scope_check"]["enabled"] = false

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: cfg
      )

      assert_equal :safety_violation, result[:status]
      assert_equal [ "unrelated-link" ], result[:paths]
    end
  end

  def test_safety_gate_rejects_gitlink_index_entries
    object_id = "a" * 40
    capture = lambda do |argv, **_kwargs|
      if argv.include?("ls-files")
        { success: true, stdout: "160000 #{object_id} 0\twiki/plugin\0" }
      else
        { success: true, stdout: "" }
      end
    end

    with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
      result = Hive::Stages::AutoCommit.auto_commit_safety_violations(
        "/worktree", [ "wiki/plugin" ]
      )

      assert_equal 1, result.fetch(:violations).length
      assert_includes result.dig(:violations, 0).reason, "mode 160000"
    end
  end

  def test_safety_gate_rejects_malformed_index_records
    captured_argv = nil
    capture = lambda do |argv, **_kwargs|
      captured_argv = argv
      { success: true, stdout: "100644 not-an-object 0\twiki/bad.md\0" }
    end

    with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
      result = Hive::Stages::AutoCommit.staged_index_entries("/worktree", [ "wiki/bad.md" ])

      refute result.fetch(:success)
      assert_equal "git ls-files --stage returned malformed index data", result.fetch(:message)
    end
    assert_includes captured_argv, "ls-files"
  end

  def test_safety_gate_rejects_malformed_head_tree_records
    captured_argv = nil
    capture = lambda do |argv, **_kwargs|
      captured_argv = argv
      { success: true, stdout: "100644 blob not-an-object\twiki/bad.md\0" }
    end

    with_replaced_singleton_method(Hive::Stages::AutoCommit, :capture_git_with_timeout, capture) do
      result = Hive::Stages::AutoCommit.send(
        :head_blob_object_ids, "/worktree", [ "wiki/bad.md" ]
      )

      refute result.fetch(:success)
      assert_equal "git ls-tree HEAD returned malformed tree data", result.fetch(:message)
    end
    assert_includes captured_argv, "ls-tree"
  end

  def test_large_allowed_path_can_be_scanned_and_committed
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      File.binwrite(
        File.join(worktree, "wiki", "large.bin"),
        "ordinary content\n" * 300_000
      )

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :auto_committed, result.fetch(:status)
      assert_empty `git -C #{worktree} diff --cached --name-only`
      assert File.exist?(File.join(worktree, "wiki", "large.bin"))
    end
  end

  # Regression for the nested-Rails-app (`web/`) scope gap: a fix touching
  # `web/app/**` / `web/test/**` must auto-commit (those mirror the top-level
  # source/test allowlist), while sensitive nested dirs like `web/config/**`
  # stay outside the allowlist and surface as a scope violation.
  def test_web_subdir_source_is_in_scope_but_web_config_is_not
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "web", "app", "controllers"))
      FileUtils.mkdir_p(File.join(worktree, "web", "test", "integration"))
      File.write(File.join(worktree, "web", "app", "controllers", "tasks_controller.rb"), "class TasksController; end\n")
      File.write(File.join(worktree, "web", "test", "integration", "tasks_test.rb"), "# test\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :auto_committed, result[:status],
                   "web/app and web/test source must be in the auto-commit allowlist"
      assert_includes Array(result[:paths]), "web/app/controllers/tasks_controller.rb"
      assert_includes Array(result[:paths]), "web/test/integration/tasks_test.rb"
    end

    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "web", "config"))
      File.write(File.join(worktree, "web", "config", "credentials.yml"), "secret: x\n")

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )

      assert_equal :scope_violation, result[:status],
                   "web/config must stay outside the allowlist like top-level config/"
      assert_includes result[:paths] || [], "web/config/credentials.yml"
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

  def test_failure_marker_redacts_secret_from_failed_git_hook
    with_tmp_dir do |worktree|
      init_git(worktree)
      FileUtils.mkdir_p(File.join(worktree, "lib"))
      File.write(File.join(worktree, "lib", "hook.rb"), "change\n")
      hook = File.join(worktree, ".git", "hooks", "pre-commit")
      File.write(hook, "#!/bin/sh\necho ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"} >&2\nexit 1\n")
      File.chmod(0o755, hook)

      result = Hive::Stages::CleanExit.run!(
        worktree_path: worktree, stage: "6-review",
        task: fake_task, cfg: @default_cfg
      )
      attrs = Hive::Stages::CleanExit.failure_marker_attrs(result)

      assert_equal :git_failed, result.fetch(:status)
      assert_includes result.fetch(:message), "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      refute_includes attrs.fetch(:detail), "ghp_#{"aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"}"
      assert_includes attrs.fetch(:detail), "[REDACTED:github_token]"
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
