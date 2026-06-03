require "test_helper"
require "open3"
require "hive/babysitter/dry_run_env"

class BabysitterDryRunEnvTest < Minitest::Test
  include HiveTestHelper

  def test_with_env_intercepts_mutating_git_and_gh_calls
    with_tmp_dir do |dir|
      Hive::Babysitter::DryRunEnv.with_env(dir) do
        git_out, git_err, git_status = Open3.capture3("git", "push", "origin", "feature", "--force-with-lease")
        gh_out, gh_err, gh_status = Open3.capture3("gh", "pr", "comment", "42", "--body", "hi")

        assert git_status.success?, git_err
        assert gh_status.success?, gh_err
        assert_equal "", git_out
        assert_equal "", gh_out
      end

      log = File.read(File.join(dir, ".babysitter-dry-run-skipped.log"))
      assert_includes log, "git push origin feature --force-with-lease skipped"
      assert_includes log, "gh pr comment 42 --body hi skipped"
    end
  end

  def test_gh_dry_run_skips_destructive_pr_commands_without_execing_real_gh
    with_tmp_dir do |dir|
      marker = File.join(dir, "real-gh-ran")
      real_gh = File.join(dir, "real-gh")
      File.write(real_gh, <<~SH)
        #!/bin/sh
        echo "$@" >> #{marker}
        exit 9
      SH
      FileUtils.chmod("+x", real_gh)

      old_real_gh = ENV["HIVE_BABYSITTER_REAL_GH"]
      old_log = ENV["HIVE_BABYSITTER_DRY_RUN_LOG"]
      ENV["HIVE_BABYSITTER_REAL_GH"] = real_gh
      ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = File.join(dir, ".babysitter-dry-run-skipped.log")

      begin
        stub = File.expand_path("../../../bin/hive-babysitter-stub-gh", __dir__)
        [
          %w[pr close 42],
          %w[pr merge 42],
          %w[pr ready 42]
        ].each do |argv|
          _out, err, status = Open3.capture3(stub, *argv)
          assert status.success?, err
        end
      ensure
        old_real_gh.nil? ? ENV.delete("HIVE_BABYSITTER_REAL_GH") : ENV["HIVE_BABYSITTER_REAL_GH"] = old_real_gh
        old_log.nil? ? ENV.delete("HIVE_BABYSITTER_DRY_RUN_LOG") : ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = old_log
      end

      refute File.exist?(marker), "destructive dry-run gh pr commands must not reach the real gh binary"
      log = File.read(File.join(dir, ".babysitter-dry-run-skipped.log"))
      assert_includes log, "gh pr close 42 skipped"
      assert_includes log, "gh pr merge 42 skipped"
      assert_includes log, "gh pr ready 42 skipped"
    end
  end
end
