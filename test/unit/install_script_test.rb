require "test_helper"
require "base64"
require "digest"
require "json"
require "open3"

class InstallScriptTest < Minitest::Test
  INSTALL_SCRIPT = File.expand_path("../../install.sh", __dir__)
  INSTALL_DOC = File.expand_path("../../install.md", __dir__)
  QMD_LOCK_ROOT = File.expand_path("../../lib/hive/assets/qmd", __dir__)
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
      assert_includes File.binread(paths.fetch(:shim)), 'printf \'%s\\n\' "$*"'
      assert File.executable?(paths.fetch(:wrapper))
      assert File.executable?(paths.fetch(:hv))
      assert File.executable?(paths.fetch(:shim))
      assert_empty Dir.glob(File.join(File.dirname(paths.fetch(:wrapper)), ".*wrapper.*"))
      assert_empty Dir.glob(File.join(File.dirname(paths.fetch(:shim)), ".hive-shim.*"))
    end
  end

  def test_installer_migrates_all_projects_before_daemon_setup
    Dir.mktmpdir("hive-installer-migration") do |dir|
      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      calls = File.readlines(File.join(dir, "hive-args"), chomp: true)
      assert_equal "migrate --all", calls.fetch(0)
      assert_equal "daemon install --json", calls.fetch(1)
    end
  end

  def test_installer_fails_closed_when_automatic_project_migration_fails
    Dir.mktmpdir("hive-installer-migration-failure") do |dir|
      _out, err, status = run_installer(dir, "migration")

      refute status.success?
      assert_includes err, "automatic project migration failed"
      assert_includes err, "hive migrate --all"
      calls = File.readlines(File.join(dir, "hive-args"), chomp: true)
      assert_equal [ "migrate --all" ], calls
    end
  end

  def test_installer_skips_fleet_migration_when_installing_a_release_that_predates_it
    Dir.mktmpdir("hive-installer-legacy-migration") do |dir|
      out, err, status = run_installer(dir, "legacy_migration")

      assert status.success?, err
      assert_includes out, "predates fleet migration"
      calls = File.readlines(File.join(dir, "hive-args"), chomp: true)
      assert_equal [ "daemon install --json" ], calls
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

  def test_fresh_install_creates_the_hv_collision_fallback_link
    Dir.mktmpdir("hive-installer-fresh-hv") do |dir|
      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      hv = File.join(dir, "bin", "hv")
      assert_path_exists hv
      assert File.symlink?(hv)
      assert_equal File.realpath(File.join(dir, "prefix", "hive", "gems", "bin", "hv")),
                   File.realpath(hv)
    end
  end

  def test_fresh_install_preserves_an_unowned_hv_when_hive_link_publishes
    Dir.mktmpdir("hive-installer-unowned-hv") do |dir|
      bin = File.join(dir, "bin")
      fake_bin = File.join(dir, "fake-bin")
      FileUtils.mkdir_p(bin)
      FileUtils.mkdir_p(fake_bin)
      unowned = "#!/bin/sh\nprintf 'operator hv\\n'\n"
      write_file_with_mode(File.join(bin, "hv"), unowned, 0o755)
      File.symlink(File.join(dir, "prefix", "hive", "gems", "bin", "hive"),
                   File.join(fake_bin, "hive"))

      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      assert_equal unowned, File.binread(File.join(bin, "hv"))
      assert_includes err, "existing hv"
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

  def test_reinstall_recreates_a_removed_hv_collision_fallback_link
    Dir.mktmpdir("hive-installer-reinstall-hv") do |dir|
      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      hv = File.join(dir, "bin", "hv")
      gem_hive = File.join(dir, "prefix", "hive", "gems", "bin", "hive")
      assert File.symlink?(hv)
      FileUtils.rm(hv)

      # Resolve `hive` on PATH to the managed launcher so the reinstall takes
      # the unconflicted branch instead of the collision-fallback branch.
      File.symlink(gem_hive, File.join(dir, "fake-bin", "hive"))

      _out, err, status = run_installer(dir, "none")

      assert status.success?, err
      refute_includes err, "existing hive"
      assert File.symlink?(hv),
             "an unconflicted reinstall must recreate a missing managed hv link"
      assert_equal File.realpath(gem_hive.gsub("/gems/bin/hive", "/gems/bin/hv")),
                   File.realpath(hv)
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
      assert calls.any? { |line| line.start_with?("ci --prefix ") && line.include?("--ignore-scripts") }, calls.inspect
      refute calls.any? { |line| line.start_with?("install ") && line.include?("@tobilu/qmd@") }, calls.inspect
      refute calls.any? { |line| line.start_with?("rebuild ") }, calls.inspect
      assert File.exist?(File.join(dir, "prefix", "hive", "qmd", "lib", "package-lock.json"))
      assert_empty Dir.glob(File.join(dir, "prefix", "hive", ".qmd-{stage,backup}.*"))
    end
  end

  def test_documented_qmd_repair_uses_channel_updater_not_direct_npm_install
    block = File.read(INSTALL_DOC).match(
      %r{## Install / Repair QMD.*?```bash\n(?<body>.*?)\n```}m
    )
    refute_nil block

    assert_includes block[:body], "hive update"
    refute_includes block[:body], "npm install"
  end

  def test_qmd_install_rejects_non_exact_or_foreign_package_specs_before_npm
    Dir.mktmpdir("hive-installer-qmd-package") do |dir|
      npm_args = File.join(dir, "npm-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "https://example.invalid/qmd.tgz", npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "unsupported HIVE_QMD_NPM_PACKAGE"
      refute_path_exists npm_args
    end
  end

  def test_qmd_dependency_lock_pins_registry_versions_and_integrities
    lock = JSON.parse(File.read(File.join(QMD_LOCK_ROOT, "package-lock.json")))
    packages = lock.fetch("packages")
    qmd = packages.fetch("node_modules/@tobilu/qmd")

    assert_equal "2.5.3", qmd.fetch("version")
    assert_equal "file:qmd.tgz", qmd.fetch("resolved")
    assert_equal "sha512-wUKc4pSPDbgs7mV7JYE8/Qj1pNXXatJFV8byTT/T3yLaoAXheFtWu0BgSWwoWGhRkMmxl5Qyitt66NHgbMyeBA==",
                 qmd.fetch("integrity")
    registry_packages = packages.filter_map do |path, metadata|
      next if path.empty? || metadata["link"] || metadata["resolved"].to_s.start_with?("file:")
      next unless metadata["resolved"].to_s.start_with?("https://registry.npmjs.org/")

      metadata
    end
    refute_empty registry_packages
    assert registry_packages.all? { |metadata| metadata.fetch("version").match?(/\A\d+\.\d+\.\d+/) }
    assert registry_packages.all? { |metadata| metadata.fetch("integrity").start_with?("sha512-") }
    assert_equal "11.5.0", lock.fetch("packages").fetch("").fetch("dependencies").fetch("node-gyp")
    assert_equal "11.5.0", packages.fetch("node_modules/node-gyp").fetch("version")
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
      assert_equal File.realpath(qmd_bin), File.realpath(qmd_link)
      assert_empty Dir.glob(File.join(File.dirname(qmd_home), ".qmd-stage.*"))
    end
  end

  def test_qmd_integrity_mismatch_is_visible_and_skips_install
    Dir.mktmpdir("hive-installer-qmd-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true, npm_args: npm_args,
        qmd_pack_tampered: true
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

  def test_qmd_startup_timeout_is_visible_and_skips_publication
    assert_optional_qmd_failure(
      qmd_hang: "version", qmd_timeout_seconds: 1,
      expected_warning: "qmd startup check timed out after 1s"
    )
  end

  def test_custom_qmd_version_is_rejected_without_using_npm
    Dir.mktmpdir("hive-installer-qmd-custom-no-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "@tobilu/qmd@2.5.2", qmd_integrity: nil,
        npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "release dependency lock requires @tobilu/qmd@2.5.3"
      refute_path_exists npm_args
    end
  end

  def test_default_qmd_version_rejects_non_release_integrity
    Dir.mktmpdir("hive-installer-qmd-custom-bad-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_integrity: "sha256-nope",
        npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "unsupported HIVE_QMD_NPM_INTEGRITY"
      refute_path_exists npm_args
    end
  end

  def test_default_qmd_version_rejects_well_formed_non_release_integrity
    Dir.mktmpdir("hive-installer-qmd-unlocked-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      alternate = "sha512-#{Base64.strict_encode64(Digest::SHA512.digest("not the release tarball"))}"

      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_integrity: alternate, npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "release dependency lock requires the published @tobilu/qmd@2.5.3 integrity"
      refute_path_exists npm_args
    end
  end

  def test_qmd_native_build_uses_locked_node_gyp_local_headers_and_offline_mode
    Dir.mktmpdir("hive-installer-qmd-locked-native-build") do |dir|
      npm_args = File.join(dir, "npm-args")
      node_args = File.join(dir, "node-args")

      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        npm_args: npm_args, node_args: node_args
      )

      assert status.success?, err
      calls = File.readlines(node_args, chomp: true)
      build = calls.find { |line| line.include?("node_modules/node-gyp/bin/node-gyp.js") }
      refute_nil build, calls.inspect
      assert_includes build, "--directory="
      assert_includes build, "--nodedir="
      refute File.readlines(npm_args, chomp: true).any? { |line| line.start_with?("rebuild ") }
    end
  end

  def test_custom_qmd_version_with_matching_tarball_integrity_is_still_rejected
    Dir.mktmpdir("hive-installer-qmd-custom-integrity") do |dir|
      npm_args = File.join(dir, "npm-args")
      _out, err, status = run_installer(
        dir, "none", install_qmd: true,
        qmd_package: "@tobilu/qmd@2.5.2", qmd_integrity: QMD_TARBALL_INTEGRITY,
        npm_args: npm_args
      )

      refute status.success?
      assert_includes err, "release dependency lock requires @tobilu/qmd@2.5.3"
      refute_path_exists npm_args
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
      assert_equal File.realpath(qmd_bin), File.realpath(qmd_link)
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
                    qmd_pack_tampered: false,
                    qmd_missing_bin: false, qmd_version_failure: false,
                    qmd_hang: nil, qmd_timeout_seconds: nil)
    fake_bin = create_installer_fakes(dir)
    install_script = INSTALL_SCRIPT
    if install_qmd
      install_script = File.join(dir, "install.sh")
      script = File.binread(INSTALL_SCRIPT).sub(
        /DEFAULT_QMD_NPM_INTEGRITY="sha512-[A-Za-z0-9+\/=]+"/,
        "DEFAULT_QMD_NPM_INTEGRITY=\"#{QMD_TARBALL_INTEGRITY}\""
      )
      File.binwrite(install_script, script)
    end
    node_header_root = File.join(dir, "node-prefix")
    FileUtils.mkdir_p(File.join(node_header_root, "include", "node"))
    File.binwrite(File.join(node_header_root, "include", "node", "node.h"), "/* fixture */\n")
    env = {
      "PATH" => "#{fake_bin}:/usr/bin:/bin",
      "HOME" => File.join(dir, "home"),
      "HIVE_PREFIX" => hive_prefix || File.join(dir, "prefix"),
      "XDG_BIN_HOME" => File.join(dir, "bin"),
      "HIVE_VERSION" => hive_version,
      "HIVE_INSTALL_QMD" => install_qmd ? "1" : "0",
      "HIVE_QMD_NPM_PACKAGE" => qmd_package,
      "HIVE_QMD_NPM_INTEGRITY" => qmd_integrity.is_a?(String) ? qmd_integrity : nil,
      "HIVE_QMD_TIMEOUT_SECONDS" => qmd_timeout_seconds&.to_s,
      "HIVE_INSTALL_TEST_FAILURE" => failure,
      "HIVE_INSTALL_TEST_COSIGN_ARGS" => cosign_args,
      "HIVE_INSTALL_TEST_QMD_REBUILD_FAILURE" => qmd_rebuild_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_NATIVE_FAILURE" => qmd_native_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_NPM_ARGS" => npm_args,
      "HIVE_INSTALL_TEST_NODE_ARGS" => node_args,
      "HIVE_INSTALL_TEST_NODE_HEADER_ROOT" => node_header_root,
      "HIVE_INSTALL_TEST_READLINK_F_FAILURE" => readlink_f_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_PACK_FAILURE" => qmd_pack_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_PACK_TAMPERED" => qmd_pack_tampered ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_INSTALL_FAILURE" => qmd_install_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_MISSING_BIN" => qmd_missing_bin ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_VERSION_FAILURE" => qmd_version_failure ? "1" : nil,
      "HIVE_INSTALL_TEST_QMD_HANG" => qmd_hang,
      "HIVE_INSTALL_TEST_QMD_ASSET_ROOT" => QMD_LOCK_ROOT,
      "HIVE_INSTALL_TEST_HIVE_ARGS" => File.join(dir, "hive-args")
    }.compact
    Open3.capture3(
      env,
      "/bin/bash", install_script,
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
      install_dir=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--bindir" ]]; then
          shift
          bindir="$1"
        elif [[ "$1" == "--install-dir" ]]; then
          shift
          install_dir="$1"
        fi
        shift
      done
      [[ "$HIVE_INSTALL_TEST_FAILURE" == "missing_bin" ]] && exit 0
      /usr/bin/mkdir -p "$bindir"
      cat > "$bindir/hive" <<'HIVE'
      #!/bin/sh
      if [ "$1" = "help" ] && [ "$2" = "migrate" ]; then
        if [ "$HIVE_INSTALL_TEST_FAILURE" = "legacy_migration" ]; then
          printf 'Usage: hive migrate [PROJECT_PATH]\n'
        else
          printf 'Options:\n  --all  migrate every registered project\n'
        fi
        exit 0
      fi
      printf '%s\n' "$*" >> "$HIVE_INSTALL_TEST_HIVE_ARGS"
      if [ "$1" = "migrate" ] && [ "$HIVE_INSTALL_TEST_FAILURE" = "migration" ]; then
        exit 79
      fi
      if [ "$1" = "daemon" ]; then
        printf '{"outcome":"unchanged"}\n'
      fi
      exit 0
      HIVE
      /usr/bin/chmod 755 "$bindir/hive"
      asset_dir="$install_dir/gems/hive-cli-0.0.0/lib/hive/assets/qmd"
      /usr/bin/mkdir -p "$asset_dir" "$install_dir/specifications"
      /usr/bin/cp "$HIVE_INSTALL_TEST_QMD_ASSET_ROOT/package.json" "$asset_dir/package.json"
      /usr/bin/cp "$HIVE_INSTALL_TEST_QMD_ASSET_ROOT/package-lock.json" "$asset_dir/package-lock.json"
      cat > "$install_dir/specifications/hive-cli-0.0.0.gemspec" <<'GEMSPEC'
      Gem::Specification.new do |spec|
        spec.name = "hive-cli"
        spec.version = "0.0.0"
        spec.summary = "installer fixture"
        spec.authors = ["Hive"]
        spec.files = []
      end
      GEMSPEC
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
      #!/bin/sh
      if [ -n "${HIVE_INSTALL_TEST_NPM_ARGS:-}" ]; then
        printf '%s\n' "$*" >> "$HIVE_INSTALL_TEST_NPM_ARGS"
      fi
      case "${1:-}" in
        pack)
          [ "${HIVE_INSTALL_TEST_QMD_HANG:-}" = "pack" ] && /usr/bin/sleep 5
          [ "${HIVE_INSTALL_TEST_QMD_PACK_FAILURE:-}" = "1" ] && exit 41
          destination=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--pack-destination" ]; then
              shift
              destination="$1"
            fi
            shift
          done
          filename="tobilu-qmd-fixture.tgz"
          if [ "${HIVE_INSTALL_TEST_QMD_PACK_TAMPERED:-}" = "1" ]; then
            printf 'tampered qmd tarball\n' > "$destination/$filename"
          else
            printf 'fixture qmd tarball\n' > "$destination/$filename"
          fi
          printf '[{"filename":"%s"}]\n' "$filename"
          ;;
        ci)
          [ "${HIVE_INSTALL_TEST_QMD_HANG:-}" = "install" ] && /usr/bin/sleep 5
          [ "${HIVE_INSTALL_TEST_QMD_INSTALL_FAILURE:-}" = "1" ] && exit 42
          prefix=""
          while [ "$#" -gt 0 ]; do
            if [ "$1" = "--prefix" ]; then
              shift
              prefix="$1"
            fi
            shift
          done
          mkdir -p "$prefix/node_modules/@tobilu/qmd/node_modules/better-sqlite3"
          mkdir -p "$prefix/node_modules/better-sqlite3" "$prefix/node_modules/node-gyp/bin"
          printf '{"name":"@tobilu/qmd"}\n' > "$prefix/node_modules/@tobilu/qmd/package.json"
          printf '{}\n' > "$prefix/node_modules/better-sqlite3/binding.gyp"
          printf '// fixture\n' > "$prefix/node_modules/node-gyp/bin/node-gyp.js"
          [ "${HIVE_INSTALL_TEST_QMD_MISSING_BIN:-}" = "1" ] && exit 0
          mkdir -p "$prefix/node_modules/.bin"
          cat > "$prefix/node_modules/.bin/qmd" <<'QMD'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  [ "${HIVE_INSTALL_TEST_QMD_HANG:-}" = "version" ] && /usr/bin/sleep 5
  [ "${HIVE_INSTALL_TEST_QMD_VERSION_FAILURE:-}" = "1" ] && exit 44
  printf 'qmd 2.5.3\n'
fi
QMD
          chmod 755 "$prefix/node_modules/.bin/qmd"
          ;;
      esac
    SH
    write_executable(File.join(fake_bin, "node"), <<~'SH')
      #!/bin/sh
      if [ -n "${HIVE_INSTALL_TEST_NODE_ARGS:-}" ]; then
        printf '%s\n' "$*" >> "$HIVE_INSTALL_TEST_NODE_ARGS"
      fi
      if [ "${1:-}" = "-e" ] && printf '%s' "${2:-}" | /usr/bin/grep -q 'include.*node.*node.h'; then
        printf '%s' "$HIVE_INSTALL_TEST_NODE_HEADER_ROOT"
        exit 0
      fi
      if printf '%s' "$*" | /usr/bin/grep -q 'node_modules/node-gyp/bin/node-gyp.js'; then
        [ "${HIVE_INSTALL_TEST_QMD_REBUILD_FAILURE:-}" = "1" ] && exit 42
        exit 0
      fi
      [ "${HIVE_INSTALL_TEST_QMD_NATIVE_FAILURE:-}" = "1" ] && exit 43
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
