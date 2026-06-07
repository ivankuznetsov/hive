require "test_helper"

class InstallScriptTest < Minitest::Test
  INSTALL_SCRIPT = File.expand_path("../../install.sh", __dir__)

  def test_hv_wrapper_delegates_to_hive_wrapper_instead_of_rubygems_shim
    wrapper = File.read(INSTALL_SCRIPT).match(
      %r{cat > "\$\{gem_home\}/bin/hv" <<WRAPPER\n(?<body>.*?)\nWRAPPER}m
    )

    refute_nil wrapper, "install.sh should generate a bash wrapper for hv"
    assert_includes wrapper[:body], 'exec "${gem_home}/bin/hive" "\$@"'
    refute_includes wrapper[:body], 'exec "${gem_home}/shims/hv" "\$@"'
  end

  def test_installer_does_not_expect_a_gem_installed_hv_binstub
    script = File.read(INSTALL_SCRIPT)

    refute_includes script, 'mv "${gem_home}/bin/hv" "${gem_home}/shims/hv"'
  end
end
