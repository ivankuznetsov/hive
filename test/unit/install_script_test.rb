require "test_helper"
require "base64"
require "digest"
require "open3"

class InstallScriptTest < Minitest::Test
  INSTALL_SCRIPT = File.expand_path("../../install.sh", __dir__)
  INSTALL_DOC = File.expand_path("../../install.md", __dir__)
  OLD_WRAPPER = <<~SH.freeze
    #!/bin/sh
    # hive-managed: install-wrapper/v1
    printf 'old wrapper\n'
  SH
  OLD_HV = "#!/bin/sh\nprintf 'old hv\\n'\n".freeze
  OLD_SHIM = "#!/bin/sh\nprintf 'old shim\\n'\n".freeze
  QMD_TARBALL = "fixture qmd tarball\n".freeze
  QMD_TARBALL_INTEGRITY = "sha512-#{Base64.strict_encode64(Digest::SHA512.digest(QMD_TARBALL))}".freeze

  def test_hv_wrapper_delegates_to_hive_wrapper_instead_of_rubygems_shim
    wrapper = File.read(INSTALL_SCRIPT).match(
      %r{cat > "\$staged_hv" <<WRAPPER\n(?<body>.*?)\nWRAPPER}m
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
    assert_includes script, "launcher_rollback_armed=1"
    assert_includes script,
                    'restore_launcher_path "$installed_bin" "$launcher_wrapper_had_original" "$launcher_wrapper_backup"'
    assert_operator script.rindex("launcher_rollback_armed=0"), :>, script.index('bash -n "$installed_bin"')
  end

  def test_gem_install_failure_restores_previous_launcher_state
    assert_launcher_rollback("gem_failure", "gem install failed")
  end

  def test_gem_install_without_hive_binstub_restores_previous_launcher_state
    assert_launcher_rollback("missing_bin", "no executable")
  end

  def test_shim_staging_failure_restores_previous_launcher_state
    assert_launcher_rollback("shim_move", "restored the previous wrapper and shim state")
  end

  def test_wrapper_write_failure_restores_previous_launcher_state
    assert_launcher_rollback("wrapper_write", "restored the previous wrapper and shim state")
  end

  def test_wrapper_chmod_failure_restores_previous_launcher_state
    assert_launcher_rollback("chmod", "restored the previous wrapper and shim state")
  end

  def test_successful_launcher_transaction_activates_the_verified_set
    Dir.mktmpdir("hive-installer-success") do |dir|
      paths = create_previous_launcher_state(dir)

      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      assert_includes File.binread(paths.fetch(:wrapper)), "hive-managed: install-wrapper/v1"
      assert_equal "#!/bin/sh\nexit 0\n", File.binread(paths.fetch(:shim))
      assert File.executable?(paths.fetch(:wrapper))
      assert File.executable?(paths.fetch(:hv))
      assert File.executable?(paths.fetch(:shim))
      assert_empty Dir.glob(File.join(File.dirname(paths.fetch(:wrapper)), ".*wrapper.*"))
      assert_empty Dir.glob(File.join(File.dirname(paths.fetch(:shim)), ".hive-shim.*"))
    end
  end

  def test_installer_preserves_an_unowned_user_hive_launcher_and_uses_hv_fallback
    Dir.mktmpdir("hive-installer-unowned-launcher") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      launcher = File.join(bin, "hive")
      unowned = "#!/bin/sh\nprintf 'operator hive\\n'\n"
      write_file_with_mode(launcher, unowned, 0o755)

      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      assert_equal unowned, File.binread(launcher)
      assert_equal 0o755, File.stat(launcher).mode & 0o777
      assert File.symlink?(File.join(bin, "hv"))
      assert_includes err, "leaving it unchanged"
    end
  end

  def test_installer_preserves_unowned_hive_and_hv_launchers
    Dir.mktmpdir("hive-installer-two-unowned-launchers") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      sentinels = %w[hive hv].to_h do |name|
        path = File.join(bin, name)
        content = "#!/bin/sh\nprintf 'operator #{name}\\n'\n"
        write_file_with_mode(path, content, 0o755)
        [ path, content ]
      end

      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      sentinels.each { |path, content| assert_equal content, File.binread(path) }
      assert_includes err, "Hive launchers remain available under"
    end
  end

  def test_reinstall_does_not_replace_an_existing_managed_user_link
    Dir.mktmpdir("hive-installer-managed-link") do |dir|
      _out, err, status = run_installer(dir, "none")
      assert status.success?, err
      link = File.join(dir, "bin", "hive")
      before = File.lstat(link)

      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      assert_equal before.ino, File.lstat(link).ino
      assert File.symlink?(link)
    end
  end

  def test_link_publication_race_preserves_replacement_and_uses_hv
    Dir.mktmpdir("hive-installer-link-race") do |dir|
      _out, err, status = run_installer(dir, "link_race")
      hive = File.join(dir, "bin", "hive")
      hv = File.join(dir, "bin", "hv")

      assert status.success?, err
      refute File.symlink?(hive)
      assert_equal "operator race\n", File.binread(hive)
      assert File.symlink?(hv)
    end
  end

  def test_installer_requires_cosign_for_release_identity_verification
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, 'command -v cosign >/dev/null 2>&1 || die "missing installer prerequisite \'cosign\''
    assert_includes script,
                    '--certificate-identity-regexp "^https://github\\\\.com/${REPO_OWNER}/${REPO_NAME}/' \
                    '\\\\.github/workflows/release\\\\.yml@refs/tags/${version}$"'
    refute_includes script, "install cosign for additional keyless signature verification"
  end

  def test_latest_release_resolution_binds_cosign_to_the_resolved_tag
    Dir.mktmpdir("hive-installer-latest-identity") do |dir|
      cosign_args = File.join(dir, "cosign-args")

      _out, err, status = run_installer(
        dir, "none", hive_version: nil, cosign_args: cosign_args
      )

      assert status.success?, err
      assert_includes File.binread(cosign_args),
                      "@refs/tags/v0.0.0$"
    end
  end

  def test_installer_normalizes_relative_prefix_before_writing_sidecars
    Dir.mktmpdir("hive-installer-relative-prefix") do |dir|
      _out, err, status = run_installer(
        dir, "none", hive_prefix: "relative-prefix", chdir: dir
      )

      assert status.success?, err
      expected = File.join(dir, "relative-prefix")
      assert_equal "#{expected}\n",
                   File.binread(File.join(expected, "hive", "install-prefix"))
      assert_equal "#{expected}\n",
                   File.binread(File.join(dir, "home", ".local", "share", "hive", "install-prefix"))
    end
  end

  def test_installer_expands_home_prefix_before_writing_sidecars
    Dir.mktmpdir("hive-installer-home-prefix") do |dir|
      _out, err, status = run_installer(
        dir, "none", hive_prefix: "~/custom-prefix", chdir: dir
      )

      assert status.success?, err
      expected = File.join(dir, "home", "custom-prefix")
      assert_equal "#{expected}\n",
                   File.binread(File.join(expected, "hive", "install-prefix"))
      assert_equal "#{expected}\n",
                   File.binread(File.join(dir, "home", ".local", "share", "hive", "install-prefix"))
    end
  end

  def test_qmd_install_uses_exact_package_and_integrity_pin
    Dir.mktmpdir("hive-installer-qmd-pin") do |dir|
      npm_args = File.join(dir, "npm-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true, npm_args: npm_args
      )

      assert status.success?, err
      calls = File.readlines(npm_args, chomp: true)
      assert_includes File.read(INSTALL_SCRIPT), 'DEFAULT_QMD_NPM_PACKAGE="@tobilu/qmd@2.5.3"'
      assert calls.any? { |line| line.start_with?("pack @tobilu/qmd@2.5.3 ") }, calls.inspect
      assert calls.any? { |line| line.include?("install --global") && line.end_with?(".tgz") },
             calls.inspect
      refute calls.any? { |line| line.start_with?("install ") && line.include?("@tobilu/qmd@") }, calls.inspect
      assert_empty Dir.glob(File.join(dir, "prefix", "hive", ".qmd-{stage,backup}.*"))
    end
  end

  def test_documented_qmd_repair_fails_closed_before_installing_mismatched_bytes
    block = File.read(INSTALL_DOC).match(
      %r{## Install / Repair QMD.*?```bash\n(?<body>.*?)\n```}m
    )
    refute_nil block

    Dir.mktmpdir("hive-installer-qmd-doc") do |dir|
      fake_bin = create_installer_fakes(dir)
      npm_args = File.join(dir, "npm-args")
      env = {
        "PATH" => "#{fake_bin}:/usr/bin:/bin",
        "HOME" => File.join(dir, "home"),
        "XDG_DATA_HOME" => File.join(dir, "data"),
        "XDG_BIN_HOME" => File.join(dir, "bin"),
        "HIVE_INSTALL_TEST_NPM_ARGS" => npm_args
      }

      _out, _err, status = Open3.capture3(env, "/bin/bash", "-c", block[:body])

      refute status.success?
      calls = File.readlines(npm_args, chomp: true)
      assert calls.any? { |line| line.start_with?("pack @tobilu/qmd@2.5.3 ") }
      refute calls.any? { |line| line.start_with?("install ") }
      refute_path_exists File.join(dir, "bin", "qmd")
    end
  end

  def test_qmd_install_rejects_non_exact_or_foreign_package_specs_before_npm
    Dir.mktmpdir("hive-installer-qmd-package") do |dir|
      npm_args = File.join(dir, "npm-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "https://example.invalid/qmd.tgz", npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "invalid HIVE_QMD_NPM_PACKAGE"
      refute_path_exists npm_args
    end
  end

  def test_disabled_qmd_ignores_an_unused_package_override
    Dir.mktmpdir("hive-installer-qmd-disabled") do |dir|
      _out, err, status = run_installer(
        dir, "none", qmd_package: "https://example.invalid/qmd.tgz"
      )

      assert status.success?, err
    end
  end

  def test_qmd_rebuild_failure_is_visible_and_skips_publication
    Dir.mktmpdir("hive-installer-qmd-rebuild") do |dir|
      _out, err, status = run_installer(
        dir, "none", install_qmd: true, qmd_rebuild_failure: true
      )

      assert status.success?, err
      assert_includes err, "qmd native rebuild failed"
      refute_path_exists File.join(dir, "bin", "qmd")
    end
  end

  def test_failed_qmd_upgrade_preserves_previous_tree_and_managed_link
    Dir.mktmpdir("hive-installer-qmd-upgrade") do |dir|
      qmd_home = File.join(dir, "prefix", "hive", "qmd")
      qmd_bin = File.join(qmd_home, "bin", "qmd")
      qmd_link = File.join(dir, "bin", "qmd")
      FileUtils.mkdir_p(File.dirname(qmd_bin))
      FileUtils.mkdir_p(File.dirname(qmd_link))
      write_executable(qmd_bin, "#!/bin/sh\nprintf 'old qmd\\n'\n")
      File.symlink(qmd_bin, qmd_link)

      _out, err, status = run_installer(
        dir, "none", install_qmd: true, qmd_rebuild_failure: true
      )

      assert status.success?, err
      assert_includes err, "qmd native rebuild"
      assert_equal "#!/bin/sh\nprintf 'old qmd\\n'\n", File.binread(qmd_bin)
      assert_equal qmd_bin, File.realpath(qmd_link)
      assert_empty Dir.glob(File.join(File.dirname(qmd_home), ".qmd-stage.*"))
    end
  end

  def test_qmd_integrity_mismatch_is_visible_and_skips_install
    Dir.mktmpdir("hive-installer-qmd-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true, npm_args: npm_args,
        qmd_integrity: "sha512-wrong"
      )

      assert status.success?, err
      assert_includes err, "qmd package integrity mismatch"
      refute File.readlines(npm_args, chomp: true).any? { |line| line.start_with?("install ") }
      refute_path_exists File.join(dir, "bin", "qmd")
    end
  end

  def test_qmd_download_failure_is_visible_and_skips_publication
    assert_optional_qmd_failure(
      qmd_pack_failure: true,
      expected_warning: "qmd package download failed"
    )
  end

  def test_qmd_install_failure_is_visible_and_skips_publication
    assert_optional_qmd_failure(
      qmd_install_failure: true,
      expected_warning: "qmd install failed"
    )
  end

  def test_qmd_missing_executable_is_visible_and_skips_publication
    assert_optional_qmd_failure(
      qmd_missing_bin: true,
      expected_warning: "no executable was found in staging"
    )
  end

  def test_qmd_startup_failure_is_visible_and_skips_publication
    assert_optional_qmd_failure(
      qmd_version_failure: true,
      expected_warning: "qmd startup check failed"
    )
  end

  def test_qmd_download_timeout_is_visible_and_skips_publication
    assert_optional_qmd_failure(
      qmd_hang: "pack", qmd_timeout_seconds: 1,
      expected_warning: "qmd package download timed out after 1s"
    )
  end

  def test_custom_qmd_version_requires_integrity
    Dir.mktmpdir("hive-installer-qmd-custom-no-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "@tobilu/qmd@2.5.2", qmd_integrity: nil,
        npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "HIVE_QMD_NPM_INTEGRITY is required"
      refute_path_exists npm_args
    end
  end

  def test_custom_qmd_version_rejects_malformed_integrity
    Dir.mktmpdir("hive-installer-qmd-custom-bad-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "@tobilu/qmd@2.5.2", qmd_integrity: "sha256-nope",
        npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "invalid HIVE_QMD_NPM_INTEGRITY"
      refute_path_exists npm_args
    end
  end

  def test_custom_qmd_version_accepts_matching_tarball_integrity
    Dir.mktmpdir("hive-installer-qmd-custom-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "@tobilu/qmd@2.5.2", qmd_integrity: QMD_TARBALL_INTEGRITY,
        npm_args: npm_args
      )

      assert status.success?, err
      assert File.readlines(npm_args, chomp: true).any? { |line| line.start_with?("pack @tobilu/qmd@2.5.2 ") }
      assert File.symlink?(File.join(dir, "bin", "qmd"))
    end
  end

  def test_qmd_native_health_probe_loads_better_sqlite3_before_publication
    Dir.mktmpdir("hive-installer-qmd-native") do |dir|
      node_args = File.join(dir, "node-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_native_failure: true, node_args: node_args
      )

      assert status.success?, err
      assert_includes err, "qmd native SQLite health check failed"
      assert_includes File.binread(node_args), "better-sqlite3"
      refute_path_exists File.join(dir, "bin", "qmd")
    end
  end

  def test_qmd_managed_link_refresh_does_not_depend_on_readlink_dash_f
    Dir.mktmpdir("hive-installer-qmd-readlink") do |dir|
      qmd_bin = File.join(dir, "prefix", "hive", "qmd", "bin", "qmd")
      qmd_link = File.join(dir, "bin", "qmd")
      FileUtils.mkdir_p(File.dirname(qmd_bin))
      FileUtils.mkdir_p(File.dirname(qmd_link))
      File.symlink(qmd_bin, qmd_link)

      _out, err, status = run_installer(
        dir, "none", install_qmd: true, readlink_f_failure: true
      )

      assert status.success?, err
      refute_includes err, "existing qmd"
      assert_equal qmd_bin, File.realpath(qmd_link)
    end
  end

  def test_qmd_install_preserves_an_unowned_user_launcher
    Dir.mktmpdir("hive-installer-unowned-qmd") do |dir|
      qmd_link = File.join(dir, "bin", "qmd")
      FileUtils.mkdir_p(File.dirname(qmd_link))
      unowned = "#!/bin/sh\nprintf 'operator qmd\\n'\n"
      write_executable(qmd_link, unowned)

      _out, err, status = run_installer(dir, "none", install_qmd: true)

      assert status.success?, err
      assert_equal unowned, File.binread(qmd_link)
      refute File.symlink?(qmd_link)
      assert_includes err, "existing qmd"
    end
  end

  private

  def assert_optional_qmd_failure(expected_warning:, **options)
    Dir.mktmpdir("hive-installer-qmd-optional-failure") do |dir|
      _out, err, status = run_installer(dir, "none", install_qmd: true, **options)

      assert status.success?, err
      assert_includes err, expected_warning
      refute_path_exists File.join(dir, "bin", "qmd")
      assert_empty Dir.glob(File.join(dir, "prefix", "hive", ".qmd-stage.*"))
    end
  end

  def assert_launcher_rollback(failure, expected_error)
    Dir.mktmpdir("hive-installer-rollback") do |dir|
      paths = create_previous_launcher_state(dir)
      _out, err, status = run_installer(dir, failure)

      refute status.success?, "#{failure} unexpectedly succeeded"
      assert_includes err, expected_error
      assert_equal OLD_WRAPPER, File.binread(paths.fetch(:wrapper))
      assert_equal OLD_HV, File.binread(paths.fetch(:hv))
      assert_equal OLD_SHIM, File.binread(paths.fetch(:shim))
      assert_equal 0o751, File.stat(paths.fetch(:wrapper)).mode & 0o777
      assert_equal 0o701, File.stat(paths.fetch(:hv)).mode & 0o777
      assert_equal 0o711, File.stat(paths.fetch(:shim)).mode & 0o777
      assert_empty Dir.glob(File.join(File.dirname(paths.fetch(:wrapper)), ".*wrapper.*"))
      assert_empty Dir.glob(File.join(File.dirname(paths.fetch(:shim)), ".hive-shim.*"))
    end
  end

  def run_installer(dir, failure, hive_version: "v0.0.0", cosign_args: nil,
                    hive_prefix: nil, chdir: nil, install_qmd: false,
                    qmd_package: nil, qmd_rebuild_failure: false,
                    qmd_native_failure: false, npm_args: nil, node_args: nil,
                    readlink_f_failure: false, qmd_integrity: :fixture,
                    qmd_pack_failure: false, qmd_install_failure: false,
                    qmd_missing_bin: false, qmd_version_failure: false,
                    qmd_hang: nil, qmd_timeout_seconds: nil)
    fake_bin = create_installer_fakes(dir)
    env = {
      "PATH" => "#{fake_bin}:/usr/bin:/bin",
      "HOME" => File.join(dir, "home"),
      "HIVE_PREFIX" => hive_prefix || File.join(dir, "prefix"),
      "XDG_BIN_HOME" => File.join(dir, "bin"),
      "HIVE_VERSION" => hive_version,
      "HIVE_INSTALL_QMD" => install_qmd ? "1" : "0",
      "HIVE_QMD_NPM_PACKAGE" => qmd_package,
      "HIVE_QMD_NPM_INTEGRITY" => qmd_integrity == :fixture ?
        (install_qmd ? QMD_TARBALL_INTEGRITY : nil) : qmd_integrity,
      "HIVE_QMD_TIMEOUT_SECONDS" => qmd_timeout_seconds&.to_s,
      "HIVE_INSTALL_TEST_FAILURE" => failure,
      "HIVE_INSTALL_TEST_COSIGN_ARGS" => cosign_args,
      "HIVE_INSTALL_TEST_QMD_REBUILD_FAILURE" => qmd_rebuild_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_NATIVE_FAILURE" => qmd_native_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_NPM_ARGS" => npm_args,
      "HIVE_INSTALL_TEST_NODE_ARGS" => node_args,
      "HIVE_INSTALL_TEST_READLINK_F_FAILURE" => readlink_f_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_PACK_FAILURE" => qmd_pack_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_INSTALL_FAILURE" => qmd_install_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_MISSING_BIN" => qmd_missing_bin ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_VERSION_FAILURE" => qmd_version_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_HANG" => qmd_hang
    }.compact
    Open3.capture3(
      env,
      "/bin/bash", INSTALL_SCRIPT,
      **({ chdir: chdir }.compact)
    )
  end

  def create_previous_launcher_state(dir)
    gem_home = File.join(dir, "prefix", "hive", "gems")
    wrapper = File.join(gem_home, "bin", "hive")
    hv = File.join(gem_home, "bin", "hv")
    shim = File.join(gem_home, "shims", "hive")
    [ wrapper, hv, shim ].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
    write_file_with_mode(wrapper, OLD_WRAPPER, 0o751)
    write_file_with_mode(hv, OLD_HV, 0o701)
    write_file_with_mode(shim, OLD_SHIM, 0o711)
    { wrapper: wrapper, hv: hv, shim: shim }
  end

  def create_installer_fakes(dir)
    fake_bin = File.join(dir, "fake-bin")
    FileUtils.mkdir_p(fake_bin)
    write_executable(File.join(fake_bin, "curl"), <<~'SH')
      #!/bin/bash
      if [[ "$*" == *'/releases/latest'* ]]; then
        printf '{"tag_name":"v0.0.0"}\n200'
        exit 0
      fi
      out=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-o" ]]; then
          shift
          out="$1"
        fi
        shift
      done
      case "$(basename "$out")" in
        hive-cli-*.gem) printf 'fixture gem\n' > "$out" ;;
        SHA256SUMS)
          gem_path="$(dirname "$out")/hive-cli-0.0.0.gem"
          digest="$(/usr/bin/sha256sum "$gem_path" | /usr/bin/awk '{print $1}')"
          printf '%s  hive-cli-0.0.0.gem\n' "$digest" > "$out"
          ;;
        *) printf 'fixture\n' > "$out" ;;
      esac
      printf '200'
    SH
    write_executable(File.join(fake_bin, "cosign"), <<~'SH')
      #!/bin/sh
      if [ -n "${HIVE_INSTALL_TEST_COSIGN_ARGS:-}" ]; then
        printf '%s\n' "$@" > "$HIVE_INSTALL_TEST_COSIGN_ARGS"
      fi
      exit 0
    SH
    write_executable(File.join(fake_bin, "ruby"), <<~RUBY)
      #!#{RbConfig.ruby}
      exec(#{RbConfig.ruby.dump}, *ARGV)
    RUBY
    write_executable(File.join(fake_bin, "gem"), <<~'SH')
      #!/bin/bash
      [[ "$HIVE_INSTALL_TEST_FAILURE" == "gem_failure" ]] && exit 42
      bindir=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--bindir" ]]; then
          shift
          bindir="$1"
        fi
        shift
      done
      [[ "$HIVE_INSTALL_TEST_FAILURE" == "missing_bin" ]] && exit 0
      /usr/bin/mkdir -p "$bindir"
      printf '#!/bin/sh\nexit 0\n' > "$bindir/hive"
      /usr/bin/chmod 755 "$bindir/hive"
    SH
    write_executable(File.join(fake_bin, "mv"), <<~'SH')
      #!/bin/bash
      source_path="${@: -2:1}"
      destination_path="${@: -1}"
      if [[ "$HIVE_INSTALL_TEST_FAILURE" == "shim_move" &&
            "$source_path" == */bin/hive && "$destination_path" == */shims/.hive-shim.* ]]; then
        exit 73
      fi
      exec /usr/bin/mv "$@"
    SH
    write_executable(File.join(fake_bin, "cat"), <<~'SH')
      #!/bin/sh
      if [ "$HIVE_INSTALL_TEST_FAILURE" = "wrapper_write" ] && [ "$#" -eq 0 ]; then
        exit 74
      fi
      exec /usr/bin/cat "$@"
    SH
    write_executable(File.join(fake_bin, "chmod"), <<~'SH')
      #!/bin/bash
      if [[ "$HIVE_INSTALL_TEST_FAILURE" == "chmod" && "$*" == *'.hive-wrapper.'* ]]; then
        exit 75
      fi
      exec /usr/bin/chmod "$@"
    SH
    write_executable(File.join(fake_bin, "ln"), <<~'SH')
      #!/bin/bash
      destination="${@: -1}"
      if [[ "$HIVE_INSTALL_TEST_FAILURE" == "link_race" &&
            "$destination" == */bin/hive ]]; then
        printf 'operator race\n' > "$destination"
        /usr/bin/chmod 755 "$destination"
        exit 76
      fi
      exec /usr/bin/ln "$@"
    SH
    write_executable(File.join(fake_bin, "npm"), <<~'SH')
      #!/bin/bash
      if [[ -n "${HIVE_INSTALL_TEST_NPM_ARGS:-}" ]]; then
        printf '%s\n' "$*" >> "$HIVE_INSTALL_TEST_NPM_ARGS"
      fi
      case "${1:-}" in
        pack)
          [[ "${HIVE_INSTALL_TEST_QMD_HANG:-}" == "pack" ]] && /usr/bin/sleep 5
          [[ "${HIVE_INSTALL_TEST_QMD_PACK_FAILURE:-}" == "1" ]] && exit 41
          destination=""
          while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--pack-destination" ]]; then
              shift
              destination="$1"
            fi
            shift
          done
          filename="tobilu-qmd-fixture.tgz"
          printf 'fixture qmd tarball\n' > "$destination/$filename"
          printf '[{"filename":"%s"}]\n' "$filename"
          ;;
        install)
          [[ "${HIVE_INSTALL_TEST_QMD_HANG:-}" == "install" ]] && /usr/bin/sleep 5
          [[ "${HIVE_INSTALL_TEST_QMD_INSTALL_FAILURE:-}" == "1" ]] && exit 42
          prefix=""
          while [[ $# -gt 0 ]]; do
            if [[ "$1" == "--prefix" ]]; then
              shift
              prefix="$1"
            fi
            shift
          done
          mkdir -p "$prefix/lib/node_modules/@tobilu/qmd/node_modules/better-sqlite3"
          printf '{"name":"@tobilu/qmd"}\n' > "$prefix/lib/node_modules/@tobilu/qmd/package.json"
          [[ "${HIVE_INSTALL_TEST_QMD_MISSING_BIN:-}" == "1" ]] && exit 0
          mkdir -p "$prefix/bin"
          cat > "$prefix/bin/qmd" <<'QMD'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  [ "${HIVE_INSTALL_TEST_QMD_VERSION_FAILURE:-}" = "1" ] && exit 44
  printf 'qmd 2.5.3\n'
fi
QMD
          chmod 755 "$prefix/bin/qmd"
          ;;
        rebuild)
          [[ "${HIVE_INSTALL_TEST_QMD_REBUILD_FAILURE:-}" == "1" ]] && exit 42
          exit 0
          ;;
      esac
    SH
    write_executable(File.join(fake_bin, "node"), <<~'SH')
      #!/bin/bash
      if [[ -n "${HIVE_INSTALL_TEST_NODE_ARGS:-}" ]]; then
        printf '%s\n' "$*" > "$HIVE_INSTALL_TEST_NODE_ARGS"
      fi
      [[ "${HIVE_INSTALL_TEST_QMD_NATIVE_FAILURE:-}" == "1" ]] && exit 43
      exit 0
    SH
    write_executable(File.join(fake_bin, "readlink"), <<~'SH')
      #!/bin/bash
      if [[ "${HIVE_INSTALL_TEST_READLINK_F_FAILURE:-}" == "1" && "${1:-}" == "-f" ]]; then
        exit 1
      fi
      exec /usr/bin/readlink "$@"
    SH
    fake_bin
  end

  def write_executable(path, body)
    write_file_with_mode(path, body, 0o755)
  end

  def write_file_with_mode(path, body, mode)
    File.binwrite(path, body)
    FileUtils.chmod(mode, path)
  end
end
