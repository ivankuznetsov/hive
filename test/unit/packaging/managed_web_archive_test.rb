require "test_helper"
require "digest"
require_relative "../../../packaging/managed_web_archive"

class ManagedWebArchiveTest < Minitest::Test
  include HiveTestHelper

  def test_same_commit_produces_byte_identical_web_archive
    with_tmp_dir do |repo|
      run_git(repo, "init", "-b", "main")
      run_git(repo, "config", "user.email", "test@example.com")
      run_git(repo, "config", "user.name", "Hive Test")
      FileUtils.mkdir_p(File.join(repo, "web"))
      File.write(File.join(repo, "web", "Gemfile"), "source \"https://rubygems.org\"\n")
      run_git(repo, "add", "web/Gemfile")
      run_git(repo, "commit", "-m", "fixture")
      sha = run_git(repo, "rev-parse", "HEAD").strip

      first = File.join(repo, "first.tar.gz")
      second = File.join(repo, "second.tar.gz")
      HiveManagedWebArchive.build(
        repo_root: repo, candidate_sha: sha, version: "1.2.3", destination: first
      )
      sleep 1.1
      HiveManagedWebArchive.build(
        repo_root: repo, candidate_sha: sha, version: "1.2.3", destination: second
      )

      assert_equal Digest::SHA256.file(first).hexdigest,
                   Digest::SHA256.file(second).hexdigest
      assert_equal File.binread(first), File.binread(second)
    end
  end

  private

  def run_git(repo, *argv)
    stdout, stderr, status = Open3.capture3("git", *argv, chdir: repo)
    assert status.success?, stderr
    stdout
  end
end
