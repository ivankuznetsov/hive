require "test_helper"
require "open3"

class PackagingVerifyReleaseTest < Minitest::Test
  SCRIPT = File.expand_path("../../../packaging/verify-release.sh", __dir__).freeze
  HIVEBOX_SMOKE = File.expand_path("../../../packaging/docker/smoke.sh", __dir__).freeze
  HIVEBOX_DOCKERFILE = File.expand_path("../../../packaging/docker/Dockerfile", __dir__).freeze
  RELEASE_WORKFLOW = File.expand_path("../../../.github/workflows/release.yml", __dir__).freeze
  INSTALL_SMOKE_WORKFLOW = File.expand_path("../../../.github/workflows/install-smoke.yml", __dir__).freeze
  MANAGED_WEB_SETUP = File.expand_path("../../../packaging/verify-managed-web-setup.sh", __dir__).freeze
  CHANNEL_SCRIPT = File.expand_path("../../../packaging/verify-channel.sh", __dir__).freeze

  def test_release_and_channel_smokes_use_the_public_status_contracts_for_their_jobs
    release = File.read(SCRIPT)
    channel = File.read(CHANNEL_SCRIPT)

    assert_includes release, "status --operational --json"
    assert_includes release, '"hive-operational-status"'
    assert_includes release, ".tasks[0].position.stage"
    assert_includes release, ".tasks[0].evidence.task_action"
    refute_includes release, ".projects[].tasks[]"

    assert_includes channel, "status --json"
    assert_includes channel, '"schema":"hive-running-status"'
    refute_includes channel, '"schema":"hive-status"'
  end

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

  def test_hivebox_smoke_requires_daemon_backed_health
    body = File.read(HIVEBOX_SMOKE)

    assert_includes body, 'smoke_curl -fsS "http://127.0.0.1:${PORT}/health?deep=1"'
    assert_includes body, "FAIL /health?deep=1 never stayed healthy"
    assert_includes body, 'while [ "$stable_deep_health" -lt 11 ]'
    assert_includes body, 'curl --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME"'
    assert_includes body, "deep_health_deadline=$(($(date +%s) + 120))"
    assert_operator body.index("/health?deep=1"), :<, body.index('body="$(smoke_curl -fsS')
    assert_operator body.rindex("/health?deep=1"), :>, body.index("unauthenticated / expected 302")
    assert_includes body, 'Hive::Web::AppBundle.assets_ready?("/app/web")'
    assert_includes body, "FAIL baked /app/web assets are incomplete"
  end

  def test_hivebox_smoke_fetches_every_stylesheet_and_javascript_advertised_by_login
    body = File.read(HIVEBOX_SMOKE)

    assert_includes body, "stylesheet_path="
    assert_includes body, "javascript_path="
    assert_includes body, "asset_paths="
    assert_includes body, "for asset_path in $asset_paths"
    assert_includes body, 'smoke_curl -fsS "http://127.0.0.1:${PORT}${asset_path}"'
    assert_includes body, 'Hive::Web::AppBundle.assets_ready?("/app/web")'
  end

  def test_hivebox_initializes_current_storage_before_starting_children
    body = File.read(File.expand_path("../../../packaging/docker/entrypoint.sh", __dir__))
    assert_includes body, "-rhive/runtime_control_plane/installation"
    assert_includes body, "Hive::RuntimeControlPlane::Installation.setup; db ="
    assert_includes body, "persistent_admission: -> { lifecycle.current.admission_open? }"
    assert_operator body.index('exec "$@"'), :<, body.index("Installation.setup")
  end

  def test_hivebox_installs_the_native_fiddle_build_dependency
    body = File.read(HIVEBOX_DOCKERFILE)

    assert_includes body, "libffi-dev"
    assert_operator body.index("libffi-dev"), :<, body.index("bundle install")
  end

  def test_release_promotes_only_the_two_native_smoked_digests
    body = File.read(RELEASE_WORKFLOW)

    assert_equal 2, body.scan("push-by-digest=true").size
    assert_includes body, "needs: [hivebox-image-amd64, hivebox-image-arm64]"
    assert_includes body, "AMD64_DIGEST: ${{ needs.hivebox-image-amd64.outputs.digest }}"
    assert_includes body, "ARM64_DIGEST: ${{ needs.hivebox-image-arm64.outputs.digest }}"
    assert_includes body, "docker buildx imagetools create"
    refute_includes body, "platforms: linux/amd64,linux/arm64"
  end


  def test_release_verifier_authenticates_managed_web_before_extraction
    body = File.read(SCRIPT)

    assert_includes body, 'WEB_BUNDLE="hive-web-${HIVE_VERSION#v}.tar.gz"'
    assert_includes body, "cosign verify-blob"
    assert_includes body,
                    '--certificate-identity-regexp "^https://github\\.com/ivankuznetsov/hive/' \
                    '\\.github/workflows/release\\.yml@refs/tags/${HIVE_VERSION}$"'
    assert_includes body, "sha256sum -c -"
    assert_operator body.index("cosign verify-blob"), :<, body.index("sha256sum -c -")
  end

  def test_release_verifier_runs_consent_approved_managed_setup_from_the_authenticated_archive
    verifier = File.read(SCRIPT)
    setup = File.read(MANAGED_WEB_SETUP)

    assert_includes verifier, "verify-managed-web-setup.sh"
    assert_operator verifier.index("cosign verify-blob"), :<,
                    verifier.index("verify-managed-web-setup.sh")
    assert_includes setup, 'HIVE_WEB_BUNDLE_URL="$WEB_ARCHIVE"'
    assert_includes setup, 'HIVE_WEB_BUNDLE_SHA256="$WEB_SHA256"'
    assert_includes setup, '"$HIVE_BIN" setup --no-init --yes --json'
    assert_includes setup, 'select(.name == "agent_skills")'
    assert_includes setup, "for phase in web_bundle daemon_service web_service web"
    assert_includes setup, "select(.name == \$phase)"
    assert_includes setup, 'SERVICE_MANAGER_BIN="$SANDBOX/service-manager-bin"'
  end

  def test_managed_web_systemd_fixture_reports_install_and_reload_transitions
    [ MANAGED_WEB_SETUP, SCRIPT ].each do |fixture|
      assert_systemd_fixture_transitions(fixture)
    end
  end

  def assert_systemd_fixture_transitions(fixture)
    assert_includes File.read(fixture), 'cp "$REPO_ROOT/packaging/fixtures/systemctl" "$SERVICE_MANAGER_BIN/systemctl"'
    body = File.read(File.expand_path("../../../packaging/fixtures/systemctl", __dir__))
    Dir.mktmpdir do |root|
      script = File.join(root, "systemctl")
      File.write(script, body)
      File.chmod(0o755, script)
      unit_dir = File.join(root, ".config/systemd/user")
      FileUtils.mkdir_p(unit_dir)
      unit = "hive-web.service"
      query = lambda do
        output, status = Open3.capture2({ "HOME" => root }, script, "--user", "show", unit.delete_suffix(".service"))
        assert status.success?
        output.lines.to_h { |line| line.chomp.split("=", 2) }
      end
      action = lambda do |*argv|
        _output, status = Open3.capture2({ "HOME" => root }, script, "--user", *argv)
        assert status.success?
      end

      assert_equal "not-found", query.call.fetch("LoadState")
      File.write(File.join(unit_dir, unit), "[Service]\nExecStart=/bin/true\n")
      action.call("daemon-reload")
      action.call("enable", "--now", unit)
      installed = query.call
      assert_equal "loaded", installed.fetch("LoadState")
      assert_equal File.join(unit_dir, unit), installed.fetch("FragmentPath")
      assert_equal "enabled", installed.fetch("UnitFileState")
      assert_equal "active", installed.fetch("ActiveState")
      assert_equal "no", installed.fetch("NeedDaemonReload")

      File.write(File.join(unit_dir, unit), "[Service]\nExecStart=/bin/false\n")
      assert_equal "yes", query.call.fetch("NeedDaemonReload")
      action.call("daemon-reload")
      assert_equal "no", query.call.fetch("NeedDaemonReload")
      original_pid = query.call.fetch("MainPID")
      action.call("restart", unit)
      refute_equal original_pid, query.call.fetch("MainPID")
      action.call("disable", "--now", unit)
      assert_equal "inactive", query.call.fetch("ActiveState")
      assert_equal "disabled", query.call.fetch("UnitFileState")
      File.unlink(File.join(unit_dir, unit))
      action.call("daemon-reload")
      assert_equal "not-found", query.call.fetch("LoadState")
    end
  end

  def test_managed_web_verifier_keeps_bundler_available_under_candidate_gem_isolation
    setup = File.read(MANAGED_WEB_SETUP)

    assert_includes setup, "BUNDLER_EXECUTABLE_SOURCE="
    assert_includes setup, '"$SERVICE_MANAGER_BIN/bundle"'
    assert_includes setup, '"$SERVICE_MANAGER_BIN/ruby"'
    assert_includes setup, 'exec %q -I%q %q "$@"'
    refute_includes setup, "BUNDLE_BIN_DIR="
  end

  def test_managed_web_verifier_allows_unavailable_agent_diagnostics_offline
    Dir.mktmpdir("managed-web-agent-skills") do |dir|
      archive = File.join(dir, "hive-web.tar.gz")
      File.binwrite(archive, "exact-web-candidate")
      hive = File.join(dir, "hive")
      write_executable(hive, <<~'SH')
        #!/bin/sh
        mkdir -p "$HIVE_HOME/web/config" "$HOME/.config/systemd/user"
        : > "$HIVE_HOME/web/config/application.rb"
        printf 'candidate\n' > "$HIVE_HOME/web/.hive-web-version"
        : > "$HOME/.config/systemd/user/hive-daemon.service"
        : > "$HOME/.config/systemd/user/hive-web.service"
        url="$(ruby -ryaml -e 'print YAML.load_file(File.join(ENV.fetch("HIVE_HOME"), "config.yml")).fetch("web").fetch("origin")')"
        curl --fail --silent "$url/health" >/dev/null
        printf '%s\n' '{"schema":"hive-setup","mode":"managed_service","ok":false,"phases":[{"name":"agent_skills","ok":false,"classification":"residual_failure"},{"name":"web_bundle","ok":true},{"name":"daemon_service","ok":true},{"name":"web_service","ok":true},{"name":"web","ok":true}]}' | jq --arg url "$url" '. + {url: $url}'
        exit 1
      SH

      _out, err, status = Open3.capture3(
        MANAGED_WEB_SETUP,
        "--hive-bin=#{hive}",
        "--archive=#{archive}",
        "--sha256=#{Digest::SHA256.file(archive).hexdigest}",
        "--prefix=#{File.join(dir, "prefix")}"
      )

      assert status.success?, err
    end
  end

  def test_verify_release_job_requires_the_managed_web_asset_on_the_pinned_release
    body = File.read(INSTALL_SMOKE_WORKFLOW)

    assert_includes body, 'gh release view "$HIVE_VERSION" --repo ivankuznetsov/hive --json assets'
    assert_includes body, "hive-web-${HIVE_VERSION#v}.tar.gz"
    assert_includes body, 'echo "capable=true" >> "$GITHUB_OUTPUT"'
    assert_includes body, "steps.release.outputs.capable == 'true'"
  end

  def test_hivebox_smoke_rejects_one_transient_deep_health_success
    Dir.mktmpdir("hivebox-smoke-stubs") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      write_executable(File.join(bin, "docker"), <<~SH)
        #!/bin/sh
        case "$1" in
          port) printf '127.0.0.1:4567\n' ;;
          *) exit 0 ;;
        esac
      SH
      write_executable(File.join(bin, "sleep"), "#!/bin/sh\nexit 0\n")
      write_executable(File.join(bin, "curl"), <<~'SH')
        #!/bin/sh
        case "$*" in
          *'/health?deep=1'*)
            count=0
            [ ! -f "$FAKE_DEEP_COUNT" ] || count="$(cat "$FAKE_DEEP_COUNT")"
            count=$((count + 1))
            printf '%s\n' "$count" >"$FAKE_DEEP_COUNT"
            [ "$count" -eq 1 ] && exit 0
            exit 22
            ;;
          *'/health'*) exit 0 ;;
          *'/login'*) printf '%s\n' 'first GitHub sign-in becomes its owner' ;;
          *) printf '302' ;;
        esac
      SH

      count_file = File.join(dir, "deep-count")
      out, err, status = Open3.capture3(
        { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "FAKE_DEEP_COUNT" => count_file },
        "/bin/sh", HIVEBOX_SMOKE, "fake:hivebox"
      )

      refute status.success?, "a one-probe deep-health gate would incorrectly pass the transient daemon"
      assert_includes "#{out}\n#{err}", "FAIL /health?deep=1 never stayed healthy"
      assert_operator File.read(count_file).to_i, :>, 1,
                      "the smoke must keep probing after the transient success"
    end
  end

  private

  def write_executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end
end
