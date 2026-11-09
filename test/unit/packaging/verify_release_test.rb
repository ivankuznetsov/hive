require "test_helper"
require "open3"

class PackagingVerifyReleaseTest < Minitest::Test
  SCRIPT = File.expand_path("../../../packaging/verify-release.sh", __dir__).freeze
  RELEASE_WORKFLOW = File.expand_path("../../../.github/workflows/release.yml", __dir__).freeze
  INSTALL_SMOKE_WORKFLOW = File.expand_path("../../../.github/workflows/install-smoke.yml", __dir__).freeze
  MANAGED_WEB_SETUP = File.expand_path("../../../packaging/verify-managed-web-setup.sh", __dir__).freeze
  CHANNEL_SCRIPT = File.expand_path("../../../packaging/verify-channel.sh", __dir__).freeze
  INSTALL_VERIFY_WORKFLOW = File.expand_path("../../../.github/workflows/install-verify.yml", __dir__).freeze
  INSTALL_COSIGN_ACTION = File.expand_path("../../../.github/actions/install-cosign/action.yml", __dir__).freeze
  FIXTURE_TOKEN = "ghs_fixtureTokenValue123".freeze

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

  def test_release_no_longer_builds_or_publishes_a_hivebox_image
    body = File.read(RELEASE_WORKFLOW)

    refute_match(/hivebox/i, body)
    refute_includes body, "docker/build-push-action"
    refute_includes body, "packages: write"
    refute_path_exists File.expand_path("../../../packaging/docker", __dir__)
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

  def test_install_jobs_use_authenticated_cosign_install_and_scope_the_token_to_release_downloads
    smoke = YAML.safe_load_file(INSTALL_SMOKE_WORKFLOW, aliases: true).fetch("jobs")
    verify = YAML.safe_load_file(INSTALL_VERIFY_WORKFLOW, aliases: true).fetch("jobs")
    jobs = {
      "full-smoke" => [ smoke.fetch("full-smoke"), [ "install + verify" ] ],
      "verify-release" => [ smoke.fetch("verify-release"), [ "Run verify-release.sh" ] ],
      "verify" => [ verify.fetch("verify"), [ "Verify channel" ] ]
    }

    jobs.each do |name, (job, token_steps)|
      steps = job.fetch("steps")
      installers = steps.select { |step| step["uses"] == "./.github/actions/install-cosign" }
      assert_equal 1, installers.size, name
      assert_equal "${{ github.token }}", installers.first.fetch("with").fetch("github-token"), name
      checkout = steps.index { |step| step["uses"].to_s.start_with?("actions/checkout@") }
      assert_operator checkout, :<, steps.index(installers.first), "#{name}: local action needs checkout first"

      actual = steps.filter_map { |step| step["name"] if step.fetch("env", {}).key?("GITHUB_TOKEN") }
      assert_equal token_steps, actual, "#{name}: GITHUB_TOKEN is scoped to the release-download step"
      refute job.fetch("env", {}).key?("GITHUB_TOKEN"), name
    end
    assert_equal "${{ github.token }}",
                 smoke.fetch("verify-release").fetch("steps").find { |step| step["name"] == "Run verify-release.sh" }
                      .fetch("env").fetch("GITHUB_TOKEN")
    assert_equal "${{ matrix.channel == 'bash' && github.token || '' }}",
                 verify.fetch("verify").fetch("steps").find { |step| step["name"] == "Verify channel" }
                       .fetch("env").fetch("GITHUB_TOKEN")
    [ INSTALL_SMOKE_WORKFLOW, INSTALL_VERIFY_WORKFLOW ].each do |path|
      refute_includes File.read(path), "sigstore/cosign-installer", "#{path}: anonymous bootstrap download"
    end
  end

  def test_install_cosign_action_downloads_authenticated_and_verifies_a_pinned_digest
    action = YAML.safe_load_file(INSTALL_COSIGN_ACTION, aliases: true)
    step = action.fetch("runs").fetch("steps").first
    env = step.fetch("env")
    run = step.fetch("run")

    assert_equal "${{ inputs.github-token }}", env.fetch("GH_TOKEN")
    assert_equal "v2.5.2", env.fetch("COSIGN_VERSION")
    # Upstream sigstore/cosign v2.5.2 cosign_checksums.txt (same digests the
    # cosign-installer v3 bootstrap pinned).
    assert_equal "bcfeae05557a9f313ee4392d2f335d0ff69ebbfd232019e3736fb04999fe1734",
                 env.fetch("COSIGN_LINUX_AMD64_SHA256")
    assert_equal "2cbcea1873ad76274c3f241ef175d204654e3aac3e73e6ec4504e5227015cb0a",
                 env.fetch("COSIGN_LINUX_ARM64_SHA256")
    assert_includes run, 'gh release download "$COSIGN_VERSION" --repo sigstore/cosign'
    assert_includes run, "for attempt in 1 2 3 4 5; do"
    assert_includes run, 'sleep "$delay"'
    assert_includes run, '[[ "$actual" != "$expected" ]]'
    assert_operator run.index("sha256sum"), :<, run.index('chmod +x "$dir/cosign"')
    assert_operator run.index('chmod +x "$dir/cosign"'), :<, run.index('>> "$GITHUB_PATH"')
    refute_match(/\bcurl\b/, run)
  end

  def test_release_fetch_authenticates_only_github_with_a_redirect_safe_curl
    [
      [ { "GITHUB_TOKEN" => FIXTURE_TOKEN }, "8.5.0", "https://github.com/o/r/releases/download/v1/SHA256SUMS", true ],
      [ { "GH_TOKEN" => FIXTURE_TOKEN }, "8.5.0", "https://github.com/o/r/releases/download/v1/SHA256SUMS", true ],
      [ { "GITHUB_TOKEN" => FIXTURE_TOKEN }, "7.82.0", "https://github.com/o/r/releases/download/v1/SHA256SUMS", false ],
      [ { "GITHUB_TOKEN" => FIXTURE_TOKEN }, "8.5.0", "https://example.com/github.com/SHA256SUMS", false ],
      [ { "GITHUB_TOKEN" => FIXTURE_TOKEN }, "8.5.0", "https://github.com.evil.test/SHA256SUMS", false ],
      [ {}, "8.5.0", "https://github.com/o/r/releases/download/v1/SHA256SUMS", false ]
    ].each do |env, version, url, authenticated|
      out, err, calls = run_release_fetch(env, version, url)

      assert_equal 1, calls.size, url
      call = calls.first
      assert_includes call[:argv], "--retry 4 --retry-delay 5 --retry-max-time 60"
      refute_includes call[:argv], FIXTURE_TOKEN
      refute_includes call[:argv], "--location-trusted"
      refute_includes out + err, FIXTURE_TOKEN
      if authenticated
        assert_equal "Authorization: Bearer #{FIXTURE_TOKEN}", call[:header], url
        assert_includes call[:argv], "--proto-redir =https"
      else
        assert_empty call[:header], "#{url} / curl #{version} must stay anonymous"
        assert_includes call[:argv], "-fsSL"
      end
    end
  end

  def test_release_fetch_retries_anonymously_when_github_rejects_the_token
    out, err, calls = run_release_fetch(
      { "GITHUB_TOKEN" => FIXTURE_TOKEN }, "8.5.0",
      "https://github.com/o/r/releases/download/v1/SHA256SUMS", reject_auth: true
    )

    assert_includes err, "GitHub rejected the configured token (HTTP 401); retrying anonymously"
    assert_equal 2, calls.size
    assert_equal "Authorization: Bearer #{FIXTURE_TOKEN}", calls.first[:header]
    assert_empty calls.last[:header]
    refute_includes out + err, FIXTURE_TOKEN
  end

  private

  # Extract verify-release.sh's download helpers and run release_fetch against
  # a fake curl that records argv and the content of any `-H @file` header.
  def run_release_fetch(env, curl_version, url, reject_auth: false)
    body = File.read(SCRIPT)
    helpers = body[/^RELEASE_CURL_RETRY_ARGS=.*?^release_fetch\(\) \{\n.*?^\}\n/m]
    refute_nil helpers, "release_fetch helpers not found"
    Dir.mktmpdir("hive-release-fetch") do |dir|
      fake_bin = File.join(dir, "bin")
      FileUtils.mkdir_p(fake_bin)
      log = File.join(dir, "curl.log")
      write_executable(File.join(fake_bin, "curl"), <<~'SH')
        #!/bin/bash
        if [[ "${1:-}" == "--version" ]]; then
          printf 'curl %s (fixture)\n' "$FAKE_CURL_VERSION"
          exit 0
        fi
        auth=""
        out=""
        args=("$@")
        for ((i = 0; i < ${#args[@]}; i++)); do
          [[ "${args[$i]}" == "-H" && "${args[$((i + 1))]:-}" == @* ]] && auth="$(cat "${args[$((i + 1))]#@}")"
          [[ "${args[$i]}" == "-o" ]] && out="${args[$((i + 1))]}"
        done
        { printf 'ARGV'; printf ' %s' "$@"; printf '\nHEADER %s\n' "$auth"; } >> "$FAKE_CURL_LOG"
        printf 'fixture\n' > "$out"
        if [[ -n "$auth" && "$FAKE_CURL_REJECT" == "1" ]]; then printf '401'; exit 0; fi
        printf '200'
      SH
      script = File.join(dir, "run.sh")
      File.write(script, "set -euo pipefail\n#{helpers}release_fetch \"$1\" \"$2\"\n")
      run_env = {
        "PATH" => "#{fake_bin}:/usr/bin:/bin",
        "GITHUB_TOKEN" => nil, "GH_TOKEN" => nil,
        "FAKE_CURL_VERSION" => curl_version, "FAKE_CURL_LOG" => log,
        "FAKE_CURL_REJECT" => reject_auth ? "1" : "0"
      }.merge(env)
      out, err, status = Open3.capture3(run_env, "/bin/bash", script, url, File.join(dir, "out"))
      assert status.success?, err
      calls = File.read(log).scan(/^ARGV(.*)\nHEADER ?(.*)$/).map { |argv, header| { argv: argv, header: header } }
      [ out, err, calls ]
    end
  end

  def write_executable(path, body)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end
end
