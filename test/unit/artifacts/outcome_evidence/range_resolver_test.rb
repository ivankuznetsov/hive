require "test_helper"
require "hive/artifacts/outcome_evidence/range_resolver"
require "hive/draft_pr_receipt"

class OutcomeEvidenceRangeResolverTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Data.define(:folder, :slug, :project_root)

  def test_resolves_the_frozen_clean_range_and_ignores_same_head_execute_base
    with_repository do |task, worktree, base, root|
      changed = File.join(worktree, "lib", "feature.rb")
      FileUtils.mkdir_p(File.dirname(changed))
      File.write(changed, "FEATURE = true\n")
      run!("git", "-C", worktree, "add", "lib/feature.rb")
      run!("git", "-C", worktree, "commit", "-m", "feature", "--quiet")
      head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
      write_pointer(task, worktree, base_oid: base, execute_base_head: head)

      identity = resolver(task, root).resolve

      assert_equal base, identity.fetch("implementation_base")
      assert_equal base, identity.fetch("merge_base")
      assert_equal head, identity.fetch("implementation_head")
      assert_equal [ "lib/feature.rb" ], identity.fetch("changed_paths")
      assert_equal Digest::SHA256.hexdigest("lib/feature.rb"),
                   identity.fetch("changed_paths_digest")
    end
  end

  def test_rejects_dirty_missing_non_ancestor_and_contradictory_controller_state
    with_repository do |task, worktree, base, root|
      commit_path(worktree, "lib/feature.rb", "FEATURE = true\n")
      write_pointer(task, worktree, base_oid: base)
      File.write(File.join(worktree, "dirty.txt"), "dirty\n")
      assert_resolution_error(task, root, /clean/)

      FileUtils.rm_f(File.join(worktree, "dirty.txt"))
      write_pointer(task, worktree)
      assert_resolution_error(task, root, /base/)

      unrelated = run!("git", "-C", task.project_root, "commit-tree", "HEAD^{tree}", "-m", "unrelated").strip
      write_pointer(task, worktree, base_oid: unrelated)
      assert_resolution_error(task, root, /ancestor/)

      write_pointer(task, worktree, base_oid: base, repository: "github.com/acme/widgets")
      Hive::DraftPrReceipt.initialize!(
        task.folder,
        expected: {
          "version" => 1, "phase" => "worktree_created",
          "repository" => "github.com/acme/widgets", "base_branch" => "master",
          "base_oid" => "f" * 40, "task_branch" => task.slug,
          "worktree_path" => worktree
        },
        worktree_root: root
      )
      assert_resolution_error(task, root, /contradicts/)
    end
  end

  def test_rejects_controller_head_drift_symlinks_and_unsafe_paths
    with_repository do |task, worktree, base, root|
      commit_path(worktree, "lib/feature.rb", "FEATURE = true\n")
      head = run!("git", "-C", worktree, "rev-parse", "HEAD").strip
      write_pointer(task, worktree, base_oid: base, repository: "github.com/acme/widgets")
      Hive::DraftPrReceipt.initialize!(
        task.folder,
        expected: {
          "version" => 1, "phase" => "worktree_created",
          "repository" => "github.com/acme/widgets", "base_branch" => "master",
          "base_oid" => base, "task_branch" => task.slug,
          "worktree_path" => worktree
        },
        worktree_root: root
      )
      Hive::DraftPrReceipt.advance!(
        task.folder, from: "worktree_created", to: "agent_validated",
        attributes: { "head_oid" => "e" * 40, "report_sha256" => "d" * 64 },
        worktree_root: root
      )
      assert_resolution_error(task, root, /head/)

      FileUtils.rm_f(File.join(task.folder, Hive::DraftPrReceipt::FILENAME))
      run!("git", "-C", worktree, "reset", "--hard", head, "--quiet")
      File.symlink("feature.rb", File.join(worktree, "lib", "linked.rb"))
      run!("git", "-C", worktree, "add", "lib/linked.rb")
      run!("git", "-C", worktree, "commit", "-m", "symlink", "--quiet")
      assert_resolution_error(task, root, /symlink/)

      %w[../escape /absolute ./dot safe/../escape].each do |path|
        assert_raises(Hive::Artifacts::OutcomeEvidence::ResolutionError) do
          Hive::Artifacts::OutcomeEvidence::RangeResolver.validate_changed_path!(path)
        end
      end
    end
  end

  def test_resolves_rename_to_the_current_path_from_one_raw_diff
    with_repository do |task, worktree, base, root|
      run!("git", "-C", worktree, "mv", "README.md", "GUIDE.md")
      run!("git", "-C", worktree, "commit", "-m", "rename guide", "--quiet")
      write_pointer(task, worktree, base_oid: base)

      identity = resolver(task, root).resolve

      assert_equal [ "GUIDE.md" ], identity.fetch("changed_paths")
    end
  end

  private

  def with_repository
    with_tmp_dir do |sandbox|
      project = File.join(sandbox, "project")
      worktree_root = File.join(sandbox, "worktrees")
      worktree = File.join(worktree_root, "demo-task")
      task_folder = File.join(project, ".hive-state", "stages", "7-artifacts", "demo-task")
      FileUtils.mkdir_p([ project, worktree_root, task_folder ])
      run!("git", "-C", project, "init", "-b", "master", "--quiet")
      run!("git", "-C", project, "config", "user.email", "test@example.com")
      run!("git", "-C", project, "config", "user.name", "Test")
      File.write(File.join(project, "README.md"), "base\n")
      run!("git", "-C", project, "add", "README.md")
      run!("git", "-C", project, "commit", "-m", "base", "--quiet")
      base = run!("git", "-C", project, "rev-parse", "HEAD").strip
      run!("git", "-C", project, "worktree", "add", "-b", "demo-task", worktree, base, "--quiet")
      yield FakeTask.new(folder: task_folder, slug: "demo-task", project_root: project),
            worktree, base, worktree_root
    end
  end

  def resolver(task, root)
    Hive::Artifacts::OutcomeEvidence::RangeResolver.new(
      task: task, project: "demo", worktree_root: root
    )
  end

  def write_pointer(task, worktree, base_oid: nil, execute_base_head: nil, repository: nil)
    data = { "path" => worktree, "branch" => task.slug, "base_branch" => "master" }
    data["base_oid"] = base_oid if base_oid
    data["execute_base_head"] = execute_base_head if execute_base_head
    data["repository"] = repository if repository
    File.write(File.join(task.folder, "worktree.yml"), data.to_yaml)
  end

  def commit_path(worktree, relative, content)
    path = File.join(worktree, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    run!("git", "-C", worktree, "add", relative)
    run!("git", "-C", worktree, "commit", "-m", "change #{relative}", "--quiet")
  end

  def assert_resolution_error(task, root, pattern)
    error = assert_raises(Hive::Artifacts::OutcomeEvidence::ResolutionError) do
      resolver(task, root).resolve
    end
    assert_match pattern, error.message
  end
end
