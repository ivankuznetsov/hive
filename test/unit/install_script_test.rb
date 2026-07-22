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

  def test_installer_temporarily_removes_and_restores_its_managed_hive_wrapper
    script = File.read(INSTALL_SCRIPT)
    removal = script.index('rm -f "$installed_bin"')
    install = script.index('GEM_HOME="$gem_home" gem install')

    refute_nil removal, "a managed wrapper must be removed before RubyGems writes its binstub"
    assert_operator removal, :<, install
    assert_includes script, "hive-managed: install-wrapper/v1"
    assert_includes script, 'mv "$previous_wrapper" "$installed_bin"'
  end


  def test_installer_requires_cosign_for_release_identity_verification
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, 'command -v cosign >/dev/null 2>&1 || die "missing installer prerequisite \'cosign\''
    assert_includes script,
                    '--certificate-identity-regexp "^https://github\\\\.com/${REPO_OWNER}/${REPO_NAME}/' \
                    '\\\\.github/workflows/release\\\\.yml@refs/tags/${VERSION}$"'
    refute_includes script, "install cosign for additional keyless signature verification"
  end
end
