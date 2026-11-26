require "hive/commands/init"
require "hive/task_journal"
require "hive/task"
require "hive/stages/review"
require "hive/review_budget"
require "hive/review_publication_recovery"

module ReviewGrantFixture
  def with_review_grant_task
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root).call }
        config_path = File.join(root, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(config_path))
        cfg["worktree_root"] = File.join(root, "test-worktrees")
        cfg["review"]["ci"]["command"] = nil
        cfg["review"]["reviewers"] = []
        cfg["review"]["browser_test"]["enabled"] = false
        # The fixture models three completed fix passes and a pass-04 final
        # verification, so pin the cap those artifacts were admitted under
        # instead of inheriting the project default.
        cfg["review"]["max_passes"] = 3
        File.write(config_path, cfg.to_yaml)
        slug = "grant-example-261030-abcd"
        folder = File.join(root, ".hive-state", "stages", "6-review", slug)
        FileUtils.mkdir_p(File.join(folder, "reviews"))
        ensure_test_task_identity(folder)
        File.write(File.join(folder, "task.md"), "# Grant recovery\n")
        File.write(File.join(folder, "plan.md"), "# Plan\n<!-- COMPLETE -->\n")
        worktree = File.join(cfg.fetch("worktree_root"), slug)
        run!("git", "-C", root, "worktree", "add", "--quiet", "-b", slug, worktree, "HEAD")
        File.write(File.join(folder, "worktree.yml"), { "path" => worktree, "branch" => slug }.to_yaml)
        task = Hive::Task.new(folder)
        Hive::TaskJournal::Writer.new(task_folder: folder).append(
          event_type: "legacy_baseline", task: { "id" => task.id, "slug" => slug },
          workflow: "coding", stage: "6-review", attempt_id: "legacy", task_generation: 0,
          reason: "pre-feature review baseline", payload: {}
        )
        head = Hive::Stages::Review.git_head(worktree)
        1.upto(3) do |pass|
          suffix = format("%02d", pass)
          File.write(File.join(folder, "reviews", "codex-#{suffix}.md"), "- [x] Earlier finding #{pass}\n")
          File.write(File.join(folder, "reviews", "escalations-#{suffix}.md"), "# Escalations\n")
          File.write(File.join(folder, "reviews", "fix-success-#{suffix}.md"), "<!-- HIVE: head=#{head} kind=fixed -->\n")
        end
        File.write(File.join(folder, "reviews", "codex-04.md"), "- [x] Preserve this exact accepted finding\n")
        File.write(File.join(folder, "reviews", "escalations-04.md"), "# Escalations\n")
        Hive::Markers.set(task.state_file, :review_stale,
          reason: "final_fix_unverified", pass: 4, accepted: 1, escalations: 0)
        yield task, cfg
      end
    end
  end

  # The review grant task above with the PR base recorded in its owned
  # pointer, a one-pass grant (unless `grant: false`), and an `origin` whose
  # `master` moved on after the grant approved `approved`.
  def with_base_merge_grant_task(grant: true, base_branch: "master")
    with_review_grant_task do |task, cfg|
      if base_branch
        pointer = YAML.safe_load(File.read(task.worktree_yml_path))
        File.write(task.worktree_yml_path, pointer.merge("base_branch" => base_branch).to_yaml)
      end
      if grant
        require "hive/daemon/recovery_coordinator"
        token = Hive::ReviewBudget.new(task: task, project: task.project_name).observe.evidence_token
        Hive::Daemon::RecoveryCoordinator.new.grant_review!(task: task, project: task.project_name,
          passes: 1, reason: "Fix the accepted finding and verify it", evidence_token: token)
      end
      Dir.mktmpdir("base-merge-remote") do |remote_root|
        bare = File.join(remote_root, "app.git")
        run!("git", "init", "--bare", "--quiet", bare)
        run!("git", "-C", task.project_root, "remote", "add", "origin", bare)
        approved = Hive::Stages::Review.git_head(task.worktree_path)
        run!("git", "-C", task.worktree_path, "push", "--quiet", "origin", "HEAD:refs/heads/#{task.slug}")
        File.write(File.join(task.project_root, "BASE.md"), "base moved on\n")
        run!("git", "-C", task.project_root, "add", "BASE.md")
        run!("git", "-C", task.project_root, "commit", "--quiet", "-m", "base moved on")
        run!("git", "-C", task.project_root, "push", "--quiet", "origin", "master")
        run!("git", "-C", task.worktree_path, "fetch", "--quiet", "origin")
        yield task, approved, cfg
      end
    end
  end

  # Exactly what reviews/ci-blocked.md tells the operator to run.
  def merge_task_base(task, ref: "origin/master")
    run!("git", "-C", task.worktree_path, "merge", "--no-ff", "--quiet", "-m", "Merge #{ref} into #{task.slug}", ref)
    Hive::Stages::Review.git_head(task.worktree_path)
  end

  # The marker the hosted gate writes for a PR that conflicts with its base.
  def mark_task_base_conflict(task, blocked:, pr_url: "https://github.com/acme/app/pull/42")
    evidence = { "worktree" => task.worktree_path, "branch" => task.slug, "pr_url" => pr_url,
      "publication" => "published", "verification" => "failed", "local_head" => blocked,
      "remote_head" => blocked, "hosted_ci" => "pending", "hosted_ci_head" => blocked }
    Hive::Markers.set(task.state_file, :review_ci_stale, gate: "github", reason: "base_conflict",
      attempts: 0, pass: 1, **Hive::ReviewPublicationRecovery.encode(evidence))
  end
end
