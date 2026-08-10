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

  def test_malformed_remote_is_not_an_identity
    assert_nil Hive::RepositoryIdentity.normalize("https://[broken")
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

  def test_origin_absent_distinguishes_a_repository_without_origin_from_lookup_failure
    with_tmp_git_repo do |repo|
      assert Hive::RepositoryIdentity.origin_absent?(repo)

      system("git", "-C", repo, "remote", "add", "origin", "https://github.com/acme/widgets.git",
             exception: true)
      refute Hive::RepositoryIdentity.origin_absent?(repo)
    end

    with_tmp_dir do |dir|
      refute with_env("PATH" => dir) { Hive::RepositoryIdentity.origin_absent?(dir) }
    end
  end

  def test_current_returns_nil_when_git_cannot_be_spawned
    with_tmp_dir do |dir|
      assert_nil with_env("PATH" => dir) { Hive::RepositoryIdentity.current(dir) }
    end
  end

  def test_current_bounds_a_hung_git_lookup
    with_tmp_dir do |dir|
      fake_bin = File.join(dir, "bin")
      FileUtils.mkdir_p(fake_bin)
      git = File.join(fake_bin, "git")
      File.write(git, "#!/bin/sh\nsleep 60\n")
      File.chmod(0o755, git)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      identity = with_env("PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}") do
        Hive::RepositoryIdentity.current(dir, timeout_sec: 0.05)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_nil identity
      assert_operator elapsed, :<, 1.0
    end
  end

  def test_current_kills_a_git_lookup_that_ignores_term
    with_tmp_dir do |dir|
      fake_bin = File.join(dir, "bin")
      FileUtils.mkdir_p(fake_bin)
      git = File.join(fake_bin, "git")
      File.write(git, "#!/bin/sh\ntrap '' TERM\nsleep 60\n")
      File.chmod(0o755, git)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      identity = with_env("PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}") do
        Hive::RepositoryIdentity.current(dir, timeout_sec: 0.05)
      end

      assert_nil identity
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
    end
  end

  def test_process_cleanup_tolerates_already_reaped_or_missing_processes
    assert_nil Hive::RepositoryIdentity.send(:signal_process_group, "TERM", 99_999_999)
    assert_nil Hive::RepositoryIdentity.send(:terminate_process_group, 99_999_999)

    broken_io = Object.new
    broken_io.define_singleton_method(:closed?) { false }
    broken_io.define_singleton_method(:close) { raise IOError, "already closed" }
    assert_nil Hive::RepositoryIdentity.send(:close_io, broken_io)
  end

  def test_local_identity_preserves_expanded_path_when_realpath_is_missing
    with_tmp_dir do |dir|
      missing = File.join(dir, "missing.git")

      assert_equal "local:#{missing}", Hive::RepositoryIdentity.normalize(missing)
    end
  end
end
