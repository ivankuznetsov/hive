require "hive/commands/init"
require "hive/task_journal"
require "hive/task"
require "hive/stages/review"

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
end
