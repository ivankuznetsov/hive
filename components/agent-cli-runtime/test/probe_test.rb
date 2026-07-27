require_relative "test_helper"

class AgentCliRuntimeProbeTest < Minitest::Test
  def test_version_check_honors_the_supplied_subprocess_environment
    Dir.mktmpdir do |dir|
      binary_name = "agent-cli-runtime-env-only-fixture"
      write_executable(File.join(dir, binary_name), <<~RUBY)
        #!/usr/bin/env ruby
        puts "fixture-agent 1.2.3"
      RUBY
      profile = fixture_profile(bin: binary_name)
      env = ENV.to_h.merge(
        "PATH" => [ dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      )

      refute profile.binary_installed?
      assert profile.binary_installed?(env:)
      assert_equal "1.2.3", profile.check_version!(env:)
    end
  end

  def test_version_check_accepts_prefixed_prerelease_versions
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "fixture-agent")
      write_executable(bin, <<~RUBY)
        #!/usr/bin/env ruby
        puts "fixture-agent v1.2.3-beta.1"
      RUBY

      assert_equal "1.2.3-beta.1", fixture_profile(bin:).check_version!
    end
  end

  def test_version_check_rejects_ambiguous_version_output
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "fixture-agent")
      write_executable(bin, <<~RUBY)
        #!/usr/bin/env ruby
        puts "wrapper 9.9.9 delegates to fixture-agent 1.2.3"
      RUBY

      error = assert_raises(AgentCliRuntime::VersionError) do
        fixture_profile(bin:).check_version!
      end
      assert_match(/ambiguous/, error.message)
      assert_match(/9\.9\.9, 1\.2\.3/, error.message)
    end
  end

  def test_timeout_kills_term_ignoring_descendants_that_hold_capture_pipes
    Dir.mktmpdir do |dir|
      pid_path = File.join(dir, "child.pid")
      wrapper = File.join(dir, "wrapper")
      child_code = <<~'RUBY'
        File.write(ARGV.fetch(0), Process.pid.to_s)
        Signal.trap("TERM", "IGNORE")
        sleep 30
      RUBY
      write_executable(wrapper, <<~RUBY)
        #!/usr/bin/env ruby
        require "rbconfig"
        child = Process.spawn(
          RbConfig.ruby, "-e", #{child_code.dump}, #{pid_path.dump}
        )
        100.times do
          break if File.file?(#{pid_path.dump})

          sleep 0.01
        end
        Process.detach(child)
      RUBY
      profile = fixture_profile(bin: wrapper)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Timeout::Error) do
        profile.send(:bounded_capture3, wrapper, timeout_sec: 1)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 3
      assert wait_until(timeout: 1) { File.file?(pid_path) }
      child_pid = Integer(File.read(pid_path))
      assert wait_until(timeout: 2) { !process_alive?(child_pid) },
             "expected timed-out descendant #{child_pid} to be reaped"
    ensure
      Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
    end
  end

  def test_custom_capabilities_are_visible_in_probe_and_runtime_evidence
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "fixture-agent")
      write_executable(bin, <<~RUBY)
        #!/usr/bin/env ruby
        if ARGV == ["--version"]
          puts "fixture-agent 1.2.3"
        elsif ARGV.include?("--help")
          puts "Usage: fixture-agent --safe-mode"
        else
          exit 1
        end
      RUBY
      profile = fixture_profile(
        bin:,
        cli_capabilities: { safe_mode: [ "--safe-mode" ] }
      )

      result = AgentCliRuntime.probe(profile)
      probe_evidence = result.capability_evidence.find do |item|
        item.capability == :safe_mode
      end
      runtime_evidence =
        AgentCliRuntime.require_capability!(profile, :safe_mode)

      assert result.ready
      assert probe_evidence.supported
      assert runtime_evidence.supported
      assert_equal [ "--safe-mode" ], runtime_evidence.arguments
    end
  end

  def test_custom_capabilities_cannot_shadow_standard_capabilities
    error = assert_raises(ArgumentError) do
      fixture_profile(
        bin: Gem.ruby,
        cli_capabilities: { headless: [ "--not-really-headless" ] }
      )
    end

    assert_match(/collides with a standard capability/, error.message)
  end

  def test_ready_probe_reports_only_local_observations
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "fixture-agent")
      write_executable(bin, <<~RUBY)
        #!/usr/bin/env ruby
        puts "fixture-agent 1.2.3"
      RUBY
      profile = AgentCliRuntime::Profile.new(
        name: :fixture,
        bin_default: bin,
        headless_flag: "-p",
        version_flag: "--version",
        min_version: "1.0.0",
        auth_configuration_probe: ->(**) {
          AgentCliRuntime::AuthConfiguration.new(status: :configured, source: "fixture")
        }
      )

      result = AgentCliRuntime.probe(profile)

      assert result.ready
      assert result.installed
      assert_equal "1.2.3", result.version
      assert_equal :configured, result.auth_configuration.status
      assert_nil result.diagnostic
      refute_respond_to result, :healthy
      refute_respond_to result, :quota
      refute_respond_to result, :credentials_valid
    end
  end

  def test_missing_binary_is_fail_soft_and_typed
    profile = AgentCliRuntime::Profile.new(
      name: :missing,
      bin_default: "/definitely/missing/agent",
      headless_flag: "-p",
      version_flag: "--version"
    )

    result = AgentCliRuntime.probe(profile)

    refute result.ready
    refute result.installed
    assert_nil result.version
    assert_equal :not_checked, result.auth_configuration.status
    assert_match(/not runnable/, result.diagnostic)
  end

  def test_probe_all_uses_stable_provider_order
    results = AgentCliRuntime.probe_all

    assert_equal %i[claude codex pi grok], results.map(&:provider)
  end

  private

  def fixture_profile(bin:, cli_capabilities: {})
    AgentCliRuntime::Profile.new(
      name: :fixture,
      bin_default: bin,
      headless_flag: "-p",
      version_flag: "--version",
      min_version: "1.0.0",
      cli_capabilities:,
      auth_configuration_probe: ->(**) {
        AgentCliRuntime::AuthConfiguration.new(
          status: :configured,
          source: "fixture"
        )
      }
    )
  end

  def wait_until(timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
