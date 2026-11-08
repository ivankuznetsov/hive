require "test_helper"
require "hive/config"
require "hive/plan_review/disposable_worktree"

class PlanReviewDisposableWorktreeTest < Minitest::Test
  include HiveTestHelper

  # The project checkout can sit on an unrelated, stale branch; planning and
  # review must still see origin's default branch, which execution starts from.
  def test_checkout_uses_the_fetched_default_branch_not_the_project_head
    with_tmp_git_repo do |upstream|
      run!("git", "-C", upstream, "branch", "-M", "main")
      with_tmp_dir do |parent|
        project = File.join(parent, "project")
        run!("git", "clone", "-q", upstream, project)
        run!("git", "-C", project, "config", "user.email", "test@example.com")
        run!("git", "-C", project, "config", "user.name", "Test")
        run!("git", "-C", project, "checkout", "-q", "-b", "feature/old")
        File.write(File.join(project, "stale.rb"), "old\n")
        run!("git", "-C", project, "add", "stale.rb")
        run!("git", "-C", project, "commit", "-q", "-m", "stale branch")

        File.write(File.join(upstream, "current.rb"), "current\n")
        run!("git", "-C", upstream, "add", "current.rb")
        run!("git", "-C", upstream, "commit", "-q", "-m", "main moved on")
        upstream_main = run!("git", "-C", upstream, "rev-parse", "HEAD").strip

        with_replaced_singleton_method(Hive::Config, :load, ->(*) { { "default_branch" => "main" } }) do
          Hive::PlanReview::DisposableWorktree.open(project_root: project) do |path|
            assert_equal upstream_main, run!("git", "-C", path, "rev-parse", "HEAD").strip
            assert File.exist?(File.join(path, "current.rb")), "the fetched default branch is inspected"
            refute File.exist?(File.join(path, "stale.rb")), "stale branch content must not be inspected"
          end
        end
      end
    end
  end

  def test_explicit_revision_is_honored
    with_tmp_git_repo do |dir|
      first = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      File.write(File.join(dir, "next.rb"), "next\n")
      run!("git", "-C", dir, "add", "next.rb")
      run!("git", "-C", dir, "commit", "-q", "-m", "next")

      Hive::PlanReview::DisposableWorktree.open(project_root: dir, revision: first) do |path|
        assert_equal first, run!("git", "-C", path, "rev-parse", "HEAD").strip
      end
    end
  end

  def test_unreadable_config_falls_back_to_the_repository_default_branch
    with_tmp_git_repo do |dir|
      run!("git", "-C", dir, "branch", "-M", "main")
      head = run!("git", "-C", dir, "rev-parse", "HEAD").strip
      with_replaced_singleton_method(Hive::Config, :load, ->(*) { raise Hive::ConfigError, "broken" }) do
        base = Hive::PlanReview::DisposableWorktree.execution_base(dir)
        assert_equal head, run!("git", "-C", dir, "rev-parse", base).strip
      end
    end
  end

  def test_unresolvable_execution_base_falls_back_to_head
    require "hive/worktree"
    with_replaced_singleton_method(Hive::Config, :load, ->(*) { { "default_branch" => "main" } }) do
      with_replaced_singleton_method(Hive::Worktree, :new, ->(*) { raise Hive::Error, "no base" }) do
        assert_equal "HEAD", Hive::PlanReview::DisposableWorktree.execution_base("/tmp/project")
      end
    end
  end
end
