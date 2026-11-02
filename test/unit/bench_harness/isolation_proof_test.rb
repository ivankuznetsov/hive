# frozen_string_literal: true

require "test_helper"
require_relative "../../support/bench_isolation"

# Kept outside the default suite and coverage shards by HIVE_CI_GATE_TESTS.
class BenchIsolationProofTest < Minitest::Test
  include BenchIsolationFixture

  ROOT = File.expand_path("../../..", __dir__)
  MATRIX_TESTS = %w[test/unit/bench_harness/isolation_exec_test.rb test/unit/bench_harness/isolation_shell_test.rb].freeze
  PROBE_IMAGE = "docker.io/library/alpine:3.22.2@sha256:4b7ce07002c69e8f3d704a9c5d6fd3053be500b7f1c69fc0d80990c2ad8dd412"
  PROBE = <<~'SH'
    set -eu
    for key in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY HB_API_KEYS HB_CLAUDE_AUTH HB_CODEX_AUTH; do
      if printenv "$key" >/dev/null; then
        printf 'ENV %s %s\n' "$key" "$(printenv "$key")"
      fi
    done
    for mode in CLAUDE CODEX; do
      case "$mode" in
        CLAUDE) path=/tmp/.claude/.credentials.json ;;
        CODEX) path=/root/.codex/auth.json ;;
      esac
      if [ -f "$path" ]; then
        printf 'AUTH %s %s\n' "$mode" "$(cat "$path")"
        if (printf 'unexpected-write' >> "$path") 2>/dev/null; then
          printf 'WRITABLE %s\n' "$mode"
        else
          printf 'READONLY %s\n' "$mode"
        fi
      fi
    done
    printf 'HOME %s\n' "$HOME"
  SH

  def test_current_bash_runs_the_complete_credential_matrix
    paths = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "bash") }
    bash = paths.find { |path| File.file?(path) && File.executable?(path) }

    refute_nil bash, "current Bash is required"
    prove_interpreter(bash, required_version: RUBY_PLATFORM.include?("darwin") ? nil : "5.")
  end

  def test_actual_bash_32_runs_the_complete_credential_matrix
    bash = RUBY_PLATFORM.include?("darwin") ? "/bin/bash" : ENV.fetch("HB_TEST_BASH_32", nil)
    unless bash
      reason = "Linux has no HB_TEST_BASH_32 override; macos-15 /bin/bash is the required Bash 3.2 CI proof"
      puts reason
      skip reason
    end

    assert File.file?(bash) && File.executable?(bash), "configured Bash 3.2 binary must exist and be executable"
    prove_interpreter(File.expand_path(bash), required_version: "3.2.")
  end

  def test_real_docker_exposes_only_the_declared_decoy_credential
    require_docker_and_probe_image
    cases = KEYS.map { |key| [ "gen", { "HB_API_KEYS" => key }, [ "ENV #{key} decoy-#{key}", "HOME /tmp" ] ] }
    cases << [ "gen", { "HB_API_KEYS" => "", "HB_CLAUDE_AUTH" => @claude_auth },
              [ "AUTH CLAUDE decoy-claude-oauth", "READONLY CLAUDE", "HOME /tmp" ] ]
    cases << [ "gen", { "HB_API_KEYS" => "", "HB_CODEX_AUTH" => @codex_auth },
              [ "AUTH CODEX decoy-codex-oauth", "READONLY CODEX", "HOME /root" ] ]
    cases << [ "gate", { "HB_API_KEYS" => "invalid declaration", "HB_CLAUDE_AUTH" => @claude_auth,
                        "HB_CODEX_AUTH" => @codex_auth }, [ "HOME /tmp" ] ]

    cases.each do |mode, declaration, expected|
      env = fixture_env.merge("PATH" => ENV.fetch("PATH"), "HB_RUNNER_IMAGE" => PROBE_IMAGE,
                              "HB_CPUS" => "1").merge(declaration)
      out, err, status = Open3.capture3(env, "bash", HiveBench::IsolationExec::SCRIPT, mode, @work, "sh", "-c", PROBE)

      assert_predicate status, :success?, "real Docker #{mode} credential probe failed (exit #{status.exitstatus}): #{err}"
      assert_equal expected.sort, out.lines.map(&:chomp).sort
      assert_empty err
    end
    assert_equal "decoy-claude-oauth", File.read(@claude_auth)
    assert_equal "decoy-codex-oauth", File.read(@codex_auth)
    puts "Real Docker: all three API providers, Claude OAuth, Codex OAuth, and gate passed with exec-style sh -c argv"
  end

  private

  def prove_interpreter(bash, required_version:)
    shim = File.join(@isolation_dir, "bash-path")
    FileUtils.mkdir_p(shim)
    File.symlink(File.realpath(bash), File.join(shim, "bash"))
    env = { "PATH" => "#{shim}:#{ENV.fetch("PATH")}", "BASH_ENV" => nil }
    version, err, status = Open3.capture3(env, "bash", "--noprofile", "--norc", "-c", 'printf "%s" "$BASH_VERSION"')

    assert_predicate status, :success?, err
    assert version.start_with?(required_version), "expected Bash #{required_version}, got #{version}" if required_version
    provenance, err, status = Open3.capture3(env, "bash", "--version")

    assert_predicate status, :success?, err
    puts "Interpreter proof: #{File.realpath(bash)}; BASH_VERSION=#{version}"
    puts provenance
    _out, err, status = Open3.capture3(env, "bash", "-n", HiveBench::IsolationExec::SCRIPT)

    assert_predicate status, :success?, err
    args = MATRIX_TESTS.flat_map { |path| [ "-r", "./#{path}" ] }
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-Itest", "-Ilib", *args, "-e", "", chdir: ROOT)

    assert_predicate status, :success?, "Bash #{version} credential matrix failed:\n#{out}\n#{err}"
    puts out
  end

  def require_docker_and_probe_image
    version, _err, status = Open3.capture3("docker", "version", "--format", "{{.Server.Version}}")
    unless status.success?
      reason = "Docker unavailable: Docker client cannot reach a usable server; image setup was not attempted"
      puts reason
      skip reason
    end

    puts "Docker server #{version.strip}; pinned probe image #{PROBE_IMAGE}"
    digests, _err, status = Open3.capture3("docker", "image", "inspect", "--format", "{{json .RepoDigests}}", PROBE_IMAGE)
    unless status.success?
      _out, _err, status = Open3.capture3("docker", "pull", PROBE_IMAGE)

      assert_predicate status, :success?, "probe image setup failed: cannot pull #{PROBE_IMAGE} (Docker is available)"
      digests, _err, status = Open3.capture3("docker", "image", "inspect", "--format", "{{json .RepoDigests}}", PROBE_IMAGE)
    end

    assert_predicate status, :success?, "probe image setup failed: cannot inspect #{PROBE_IMAGE}"
    assert JSON.parse(digests).any? { |reference| reference.end_with?(PROBE_IMAGE.split("@").last) },
           "probe image setup failed: image digest did not match"
  rescue Errno::ENOENT
    reason = "Docker unavailable: no Docker client executable; image setup was not attempted"
    puts reason
    skip reason
  end
end
