require "test_helper"
require "open3"
require "hive/babysitter/dry_run_env"

# Live-gh regression for the babysitter dry-run wrapper. This deliberately uses
# the operator's stored gh login with token environment variables removed: the
# recording binary in the unit suite cannot prove that the isolated config still
# gives real gh enough host/account context to retrieve a keyring credential.
class LiveGhDryRunAuthSmokeTest < Minitest::Test
  include HiveTestHelper

  TOKEN_ENV = {
    "GH_TOKEN" => nil,
    "GITHUB_TOKEN" => nil,
    "GH_ENTERPRISE_TOKEN" => nil,
    "GITHUB_ENTERPRISE_TOKEN" => nil
  }.freeze

  def setup
    @real_gh = Hive::Babysitter::DryRunEnv.which("gh")
    skip "gh binary not on PATH" unless @real_gh

    _out, _err, status = Open3.capture3(TOKEN_ENV, @real_gh, "auth", "status", "--active")
    skip "real gh has no working stored login" unless status.success?
  end

  def test_dry_run_auth_status_reuses_stored_login_without_exported_token
    with_tmp_dir do |dir|
      with_env(TOKEN_ENV) do
        Hive::Babysitter::DryRunEnv.with_env(dir) do
          _out, _err, status = Open3.capture3("gh", "auth", "status", "--active")

          assert status.success?, "dry-run gh auth status could not use the stored login (exit #{status.exitstatus})"
        end
      end
    end
  end
end
