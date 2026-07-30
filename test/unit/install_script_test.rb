require "test_helper"
require "open3"

class InstallScriptTest < Minitest::Test
  INSTALL_SCRIPT = File.expand_path("../../install.sh", __dir__)
  OLD_WRAPPER = <<~SH.freeze
    #!/bin/sh
    # hive-managed: install-wrapper/v1
    printf 'old wrapper\n'
  SH
  OLD_HV = "#!/bin/sh\nprintf 'old hv\\n'\n".freeze
  OLD_SHIM = "#!/bin/sh\nprintf 'old shim\\n'\n".freeze

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
    install = script.index(
      'GEM_HOME="$gem_home" "$GEM_COMMAND" install'
    )

    refute_nil removal, "a managed wrapper must be removed before RubyGems writes its binstub"
    refute_nil install, "the managed gem install command must remain present"
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

  def test_installer_runs_candidate_registry_migration_before_daemon_setup
    script = File.read(INSTALL_SCRIPT)
    migration = script.rindex("job_schema_migration_setup")
    daemon = script.rindex("daemon_autostart_setup")

    refute_nil migration
    refute_nil daemon
    assert_operator migration, :<, daemon
    assert_includes script,
                    "migration_args=(refactor-patrol-migrate-installed)"
    assert_includes script,
                    "migration_args+=(--all-users --ensure-retry-service)"
    assert_includes script, "--ensure-retry-service"
    assert_includes script, 'data_base="/usr/local/share"'
    assert_includes script, 'bin_home="/usr/local/bin"'
    assert_includes script,
                    "shared installation coverage is not complete"
    assert_includes script,
                    "root-owned system package for shared installations"
    refute_match(/administrator must run.*link_path/, script)
    refute_match(/sudo.*refactor-patrol-migrate-installed/, script)
  end

  def test_installer_requires_cosign_for_release_identity_verification
    script = File.read(INSTALL_SCRIPT)

    assert_includes script, 'command -v cosign >/dev/null 2>&1 || die "missing installer prerequisite \'cosign\''
    assert_includes script,
                    '--certificate-identity-regexp "^https://github\\\\.com/${REPO_OWNER}/${REPO_NAME}/' \
                    '\\\\.github/workflows/release\\\\.yml@refs/tags/${VERSION}$"'
    refute_includes script, "install cosign for additional keyless signature verification"
  end

  private

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

  def run_installer(dir, failure)
    fake_bin = create_installer_fakes(dir)
    Open3.capture3(
      {
        "PATH" => "#{fake_bin}:/usr/bin:/bin",
        "HOME" => File.join(dir, "home"),
        "HIVE_PREFIX" => File.join(dir, "prefix"),
        "XDG_BIN_HOME" => File.join(dir, "bin"),
        "HIVE_VERSION" => "v0.0.0",
        "HIVE_INSTALL_QMD" => "0",
        "HIVE_INSTALL_TEST_FAILURE" => failure
      },
      "/bin/bash", INSTALL_SCRIPT
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
    write_executable(File.join(fake_bin, "cosign"), "#!/bin/sh\nexit 0\n")
    write_executable(File.join(fake_bin, "ruby"), <<~'SH')
      #!/bin/sh
      case "$*" in
        *'print RUBY_VERSION'*) printf '3.4.7' ;;
      esac
      exit 0
    SH
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
