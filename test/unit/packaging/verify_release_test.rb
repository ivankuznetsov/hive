require "test_helper"
require "open3"

class PackagingVerifyReleaseTest < Minitest::Test
  SCRIPT = File.expand_path("../../../packaging/verify-release.sh", __dir__).freeze
  HIVEBOX_SMOKE = File.expand_path("../../../packaging/docker/smoke.sh", __dir__).freeze
  RELEASE_WORKFLOW = File.expand_path("../../../.github/workflows/release.yml", __dir__).freeze
  INSTALL_SMOKE_WORKFLOW = File.expand_path("../../../.github/workflows/install-smoke.yml", __dir__).freeze

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
