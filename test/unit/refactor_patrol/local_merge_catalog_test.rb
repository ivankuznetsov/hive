require "test_helper"
require "hive/refactor_patrol/local_merge_catalog"

class HiveRefactorPatrolLocalMergeCatalogTest < Minitest::Test
  include HiveTestHelper

  def test_discovers_squash_and_merge_subjects_oldest_first_with_first_parent_boundaries
    with_history_repo do |repo, baseline|
      File.write(File.join(repo, "lib", "one.rb"), "one\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "Add one (#101)", "--quiet")
      first = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      File.write(File.join(repo, "lib", "two.rb"), "two\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "Merge pull request #102 from example/two", "--quiet")
      second = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      result = Hive::RefactorPatrol::LocalMergeCatalog.new(repo).discover(checkpoint_sha: baseline, head_sha: second)

      assert_equal [ 101, 102 ], result.merges.map { |item| item.fetch("pr_number") }
      assert_equal [ baseline, first ], result.merges.map { |item| item.fetch("base_sha") }
      assert_equal [ first, second ], result.merges.map { |item| item.fetch("merge_sha") }
      assert_equal [ [ "lib/one.rb" ], [ "lib/two.rb" ] ], result.merges.map { |item| item.fetch("changed_paths") }
      assert_empty result.diagnostics
    end
  end

  def test_unattributed_commits_are_diagnostic_and_renames_deletes_keep_both_boundaries
    with_history_repo do |repo, baseline|
      File.write(File.join(repo, "lib", "old.rb"), "old\n")
      File.write(File.join(repo, "lib", "delete.rb"), "delete\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "direct change", "--quiet")

      run!("git", "-C", repo, "mv", "lib/old.rb", "lib/new.rb")
      FileUtils.rm_f(File.join(repo, "lib", "delete.rb"))
      run!("git", "-C", repo, "add", "-A")
      run!("git", "-C", repo, "commit", "-m", "Move files (#103)", "--quiet")
      head = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      result = Hive::RefactorPatrol::LocalMergeCatalog.new(repo).discover(checkpoint_sha: baseline, head_sha: head)

      assert_equal [ 103 ], result.merges.map { |item| item.fetch("pr_number") }
      assert_equal [ "lib/delete.rb", "lib/new.rb", "lib/old.rb" ], result.merges.first.fetch("changed_paths").sort
      assert_equal "unattributed_first_parent_commit", result.diagnostics.first.fetch("reason")
    end
  end

  def test_rewritten_checkpoint_fails_closed
    with_history_repo do |repo, _baseline|
      error = assert_raises(Hive::RefactorPatrol::LocalMergeCatalog::CatalogError) do
        Hive::RefactorPatrol::LocalMergeCatalog.new(repo).discover(checkpoint_sha: "0" * 40, head_sha: "HEAD")
      end
      assert_equal "checkpoint_unreachable", error.reason
    end
  end

  def test_unreachable_history_missing_parent_and_git_failures_are_typed
    fake = Object.new
    fake.define_singleton_method(:rev_parse) { |ref| ref }
    fake.define_singleton_method(:ancestor?) { |_checkpoint, _head| false }
    error = assert_raises(Hive::RefactorPatrol::LocalMergeCatalog::CatalogError) do
      Hive::RefactorPatrol::LocalMergeCatalog.new("/tmp", git: fake).discover(
        checkpoint_sha: "base", head_sha: "head"
      )
    end
    assert_equal "checkpoint_unreachable", error.reason

    fake.define_singleton_method(:ancestor?) { |_checkpoint, _head| true }
    fake.define_singleton_method(:first_parent_commits) do |_checkpoint, _head|
      [ { "sha" => "root", "subject" => "Root change (#9)", "parents" => [] } ]
    end
    result = Hive::RefactorPatrol::LocalMergeCatalog.new("/tmp", git: fake).discover(
      checkpoint_sha: "base", head_sha: "head"
    )
    assert_empty result.merges
    assert_equal "merge_without_first_parent", result.diagnostics.first.fetch("reason")

    fake.define_singleton_method(:rev_parse) { |_ref| raise Hive::GitError, "unreadable" }
    error = assert_raises(Hive::RefactorPatrol::LocalMergeCatalog::CatalogError) do
      Hive::RefactorPatrol::LocalMergeCatalog.new("/tmp", git: fake).discover(
        checkpoint_sha: "base", head_sha: "head"
      )
    end
    assert_equal "checkpoint_unreachable", error.reason
  end

  private

  def with_history_repo
    with_tmp_git_repo do |repo|
      FileUtils.mkdir_p(File.join(repo, "lib"))
      baseline = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      yield repo, baseline
    end
  end
end
