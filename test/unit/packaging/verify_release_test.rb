require "test_helper"

class PackagingVerifyReleaseTest < Minitest::Test
  SCRIPT = File.expand_path("../../../packaging/verify-release.sh", __dir__).freeze

  def test_service_manager_is_stubbed_before_any_installed_hive_command_runs
    body = File.read(SCRIPT)
    path_export = body.index('export PATH="$SERVICE_MANAGER_BIN:$XDG_BIN_HOME:$PATH"')
    installer_call = body.index('timeout 300 bash "$INSTALL_SH"')

    assert_includes body, 'SERVICE_MANAGER_BIN="$PREFIX/service-manager-bin"'
    assert_includes body, '"$SERVICE_MANAGER_BIN/systemctl"'
    assert_includes body, '"$SERVICE_MANAGER_BIN/launchctl"'
    assert_includes body, 'command -v "$SERVICE_MANAGER_COMMAND"'
    assert_includes body, '"$SERVICE_MANAGER_BIN/$SERVICE_MANAGER_COMMAND"'
    refute_nil path_export
    refute_nil installer_call
    assert_operator path_export, :<, installer_call,
                    "the fake service manager must be on PATH before install.sh can run Hive"
  end
end
