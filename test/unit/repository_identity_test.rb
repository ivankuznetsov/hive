require "test_helper"
require "hive/repository_identity"

class RepositoryIdentityTest < Minitest::Test
  include HiveTestHelper

  def test_normalizes_common_remote_transports_to_one_identity
    expected = "github.com/acme/widgets"

    assert_equal expected, Hive::RepositoryIdentity.normalize("git@github.com:acme/widgets.git")
    assert_equal expected, Hive::RepositoryIdentity.normalize("ssh://git@github.com/acme/widgets.git")
    assert_equal expected, Hive::RepositoryIdentity.normalize("https://github.com/acme/widgets/")
  end

  def test_keeps_host_and_path_significant
    refute_equal Hive::RepositoryIdentity.normalize("https://github.com/acme/widgets.git"),
                 Hive::RepositoryIdentity.normalize("https://gitlab.com/acme/widgets.git")
    refute_equal Hive::RepositoryIdentity.normalize("https://github.com/acme/widgets.git"),
                 Hive::RepositoryIdentity.normalize("https://github.com/acme/other.git")
  end

  def test_normalizes_local_and_file_remotes_without_network_access
    with_tmp_dir do |dir|
      repo = File.join(dir, "repo")
      remote = File.join(dir, "remote.git")
      FileUtils.mkdir_p([ repo, remote ])

      expected = "local:#{File.realpath(remote)}"
      assert_equal expected, Hive::RepositoryIdentity.normalize("../remote.git", base_path: repo)
      assert_equal expected, Hive::RepositoryIdentity.normalize("file://#{remote}", base_path: repo)
    end
  end

  def test_current_returns_nil_without_origin
    with_tmp_git_repo do |repo|
      assert_nil Hive::RepositoryIdentity.current(repo)
    end
  end
end
