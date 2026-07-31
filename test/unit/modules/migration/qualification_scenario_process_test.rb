require "test_helper"
require "json"
require "rbconfig"
require "hive/modules/migration/qualification_scenario_process"
require "hive/modules/migration/qualification_provider_broker"

class ModulesMigrationQualificationScenarioProcessTest <
    Minitest::Test
  include HiveTestHelper

  PROCESS =
    Hive::Modules::Migration::QualificationScenarioProcess
  BROKER =
    Hive::Modules::Migration::QualificationProviderBroker
  TRANSPORT =
    Hive::Modules::Migration::QualificationOpenRouterTransport
  SOURCE_ROOT = File.expand_path("../../../..", __dir__).freeze

  ProviderTransport = Data.define(:calls) do
    def call(prompt:, kind:, timeout_seconds:)
      calls << {
        prompt: prompt,
        kind: kind,
        timeout_seconds: timeout_seconds
      }
      TRANSPORT::Result.new(
        content: '{"findings":[]}',
        input_tokens: 17,
        output_tokens: 4
      ).freeze
    end
  end

  class SidecarSignalGuard
    def initialize
      @delegate = Hive::Attempts::ProcessIdentity.new
    end

    def capture(pid)
      @delegate.capture(pid)
    end

    def status(_identity)
      raise "candidate sidecar identity reached host signal authority"
    end
  end

  class MissingIdentity
    attr_reader :pid

    def capture(pid)
      @pid = pid
      nil
    end

    def status(_identity)
      raise "missing identity reached ordinary signal authority"
    end
  end

  class RecordingIdentity
    attr_reader :snapshot

    def initialize
      @delegate = Hive::Attempts::ProcessIdentity.new
    end

    def capture(pid)
      @snapshot = @delegate.capture(pid)
    end

    def status(identity)
      @delegate.status(identity)
    end
  end

  def test_executes_exact_target_in_closed_networkless_environment
    with_process_workspace do |context|
      probe = File.join(context.fetch(:case), "probe.json")
      write_executable(
        context.fetch(:executable),
        <<~RUBY
          require "json"
          require "socket"
          blocked = begin
            Socket.tcp("1.1.1.1", 53, connect_timeout: 0.2).close
            false
          rescue SystemCallError, IOError
            true
          end
          File.binwrite(
            ARGV.fetch(0),
            JSON.generate(
              "secret_present" => ENV.key?("QUALIFICATION_AMBIENT_SECRET"),
              "home" => ENV.fetch("HOME"),
              "hive_home" => ENV.fetch("HIVE_HOME"),
              "gem_home" => ENV.fetch("GEM_HOME"),
              "network_blocked" => blocked
            )
          )
        RUBY
      )

      with_env("QUALIFICATION_AMBIENT_SECRET" => "must-not-leak") do
        result = call_process(
          context,
          argv: [
            "/qualification/cases/case-one/probe.json"
          ],
          network: false
        )

        assert_equal "passed", result.status
        assert_equal 0, result.exit_status
        assert_equal true, result.network_isolated
        assert_match(
          /\A[0-9a-f]{64}\z/,
          result.sandbox_profile_sha256
        )
        assert_match(
          /\A[0-9a-f]{64}\z/,
          result.source_inventory_sha256
        )
        assert_match(
          /\A[0-9a-f]{64}\z/,
          result.installed_inventory_sha256
        )
        assert_equal(
          "host_pid_namespace",
          result.teardown.fetch("kill_authority")
        )
      end
      data = JSON.parse(File.binread(probe))
      assert_equal false, data.fetch("secret_present")
      assert_equal true, data.fetch("network_blocked")
      assert_equal(
        "/qualification/cases/case-one/runtime/home",
        data.fetch("home")
      )
      assert_equal(
        "/qualification/cases/case-one/sandbox/hive-home",
        data.fetch("hive_home")
      )
      assert_equal(
        "/qualification/targets/installed",
        data.fetch("gem_home")
      )
    end
  end

  def test_installed_candidate_reaches_only_the_broker_and_packaged_source
    with_process_workspace do |context|
      transport = ProviderTransport.new([])
      broker = BROKER.new(
        workspace: context.fetch(:workspace),
        run_id: "patrol-#{"a" * 64}",
        lane: "installed",
        case_id: "case-one",
        generation: 1,
        scenario_request_sha256: "b" * 64,
        deadline:
          Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5,
        api_key: "provider-token",
        transport: transport
      )
      binding = broker.binding
      installed_executable = File.join(
        context.fetch(:installed),
        "bin",
        "hive"
      )
      probe = File.join(context.fetch(:case), "provider-probe.json")
      write_executable(
        installed_executable,
        <<~RUBY
          require "json"
          require "socket"
          $LOAD_PATH.unshift(
            "/qualification/targets/candidate/lib"
          )
          require "hive/modules/migration/qualification_provider_client"
          blocked = begin
            Socket.tcp("1.1.1.1", 53, connect_timeout: 0.2).close
            false
          rescue SystemCallError, IOError
            true
          end
          client =
            Hive::Modules::Migration::
              QualificationProviderClient.from_environment
          response = client.call(
            kind: "ordinary_findings",
            prompt: "review installed boundary",
            context_refs: [],
            output_ref:
              "/qualification/cases/case-one/" \
                "sandbox/repository/.hive-state/" \
                "provider/findings.json"
          )
          output = File.join(
            "/qualification/cases/case-one",
            response.output_ref
          )
          raise "provider response failed" unless File.file?(output)
          File.binwrite(
            ARGV.fetch(0),
            JSON.generate(
              "network_blocked" => blocked,
              "source_visible" =>
                File.exist?("/qualification/targets/source"),
              "source_sentinel_visible" =>
                File.exist?(
                  "/qualification/targets/candidate/lib/source-only.rb"
                ),
              "installed_sentinel_visible" =>
                File.exist?(
                  "/qualification/targets/candidate/lib/installed-only.rb"
                ),
              "credential_present" =>
                ENV.keys.any? do |name|
                  name.include?("OPENROUTER") ||
                    name.end_with?("API_KEY")
                end,
              "model_present" =>
                ENV.keys.any? { |name| name.include?("MODEL") },
              "provider_output" => JSON.parse(File.binread(output))
            )
          )
        RUBY
      )

      result = call_process(
        context,
        executable: installed_executable,
        candidate_root: context.fetch(:installed_package),
        provider_binding: binding,
        argv: [
          "/qualification/cases/case-one/provider-probe.json"
        ],
        network: false
      )

      assert_equal "passed", result.status, result.inspect
      assert_equal 1, result.provider_call_count
      assert_match(
        /\A[0-9a-f]{64}\z/,
        result.provider_evidence_sha256
      )
      assert_nil result.provider_failure
      assert_equal 1, transport.calls.length
      refute File.exist?(binding.host_root)
      data = JSON.parse(File.binread(probe))
      assert_equal true, data.fetch("network_blocked")
      assert_equal false, data.fetch("source_visible")
      assert_equal false, data.fetch("source_sentinel_visible")
      assert_equal true, data.fetch("installed_sentinel_visible")
      assert_equal false, data.fetch("credential_present")
      assert_equal false, data.fetch("model_present")
      assert_equal(
        { "findings" => [] },
        data.fetch("provider_output")
      )
    ensure
      broker&.seal! unless broker&.sealed?
    end
  end

  def test_bounds_streams_and_returns_only_digests
    with_process_workspace do |context|
      write_executable(
        context.fetch(:executable),
        <<~RUBY
          STDOUT.write("o" * 100_000)
          STDERR.write("e" * 100_000)
        RUBY
      )

      result = call_process(
        context,
        process: PROCESS.new(output_limit: 1_024),
        argv: [],
        network: false
      )

      assert_equal 100_000, result.stdout.fetch("bytes")
      assert_equal 100_000, result.stderr.fetch("bytes")
      assert_equal true, result.stdout.fetch("truncated")
      assert_equal true, result.stderr.fetch("truncated")
      assert_match(
        /\A[0-9a-f]{64}\z/,
        result.stdout.fetch("sha256")
      )
      refute result.stdout.key?("content")
    end
  end

  def test_confines_hive_home_and_runtime_to_one_scenario
    with_process_workspace do |context|
      probe = File.join(context.fetch(:case), "probe.json")
      write_executable(
        context.fetch(:executable),
        <<~RUBY
          require "json"
          File.binwrite(
            ARGV.fetch(0),
            JSON.generate(
              "home" => ENV.fetch("HOME"),
              "hive_home" => ENV.fetch("HIVE_HOME"),
              "custody" =>
                ENV.fetch("HIVE_QUALIFICATION_CUSTODY_ROOT")
            )
          )
        RUBY
      )

      result = call_process(
        context,
        argv: [
          "/qualification/cases/case-one/probe.json"
        ],
        network: false
      )

      assert_equal "passed", result.status
      data = JSON.parse(File.binread(probe))
      assert_equal(
        "/qualification/cases/case-one/sandbox/hive-home",
        data.fetch("hive_home")
      )
      assert_equal(
        "/qualification/cases/case-one/runtime/home",
        data.fetch("home")
      )
      assert_equal(
        "/qualification/cases/case-one/runtime/custody",
        data.fetch("custody")
      )
      refute File.exist?(
        File.join(context.fetch(:workspace), "runtime")
      )
    end
  end

  def test_timeout_terminates_the_foreground_group
    with_process_workspace do |context|
      identity = RecordingIdentity.new
      pid_path =
        File.join(context.fetch(:case), "child.pid")
      write_executable(
        context.fetch(:executable),
        <<~RUBY
          child = spawn(
            RbConfig.ruby,
            "-e",
            "sleep 30",
            pgroup: Process.getpgrp
          )
          File.binwrite(ARGV.fetch(0), child.to_s)
          sleep 30
        RUBY
      )

      result = call_process(
        context,
        process: PROCESS.new(process_identity: identity),
        argv: [
          "/qualification/cases/case-one/child.pid"
        ],
        timeout_seconds: 0.2,
        network: false
      )

      assert_equal "failed", result.status
      assert_equal true, result.timed_out
      child_pid = Integer(File.binread(pid_path))
      assert_operator child_pid, :positive?
      refute_nil identity.snapshot
      assert_raises(Errno::ESRCH) do
        Process.kill(
          0,
          -identity.snapshot.process_group_id
        )
      end
      assert_equal(
        "host_pid_namespace",
        result.teardown.fetch("kill_authority")
      )
    end
  end

  def test_unbound_detached_custody_fails_closed_without_host_signalling
    with_process_workspace do |context|
      pid_path =
        File.join(context.fetch(:case), "detached.pid")
      write_executable(
        context.fetch(:executable),
        <<~RUBY
          require "json"
          child = fork do
            STDIN.reopen(File::NULL)
            STDOUT.reopen(File::NULL, "w")
            STDERR.reopen(File::NULL, "w")
            Process.setsid
            sleep 30
          end
          sleep 0.05
          identity = {
            "pid" => child,
            "process_group_id" => Process.getpgid(child),
            "session_id" => Process.getsid(child),
            "start_fingerprint" => "candidate-namespace"
          }
          attempt_id =
            "11111111-1111-4111-8111-111111111111"
          custody = {
            "attempt_id" => attempt_id,
            "schema" =>
              "hive-patrol-qualification-process-custody",
            "schema_version" => 1,
            "wrapper" => identity
          }
          custody_path = File.join(
            ENV.fetch("HIVE_QUALIFICATION_CUSTODY_ROOT"),
            "\#{attempt_id}.json"
          )
          File.binwrite(
            custody_path,
            "\#{JSON.generate(custody)}\\n"
          )
          File.chmod(0o600, custody_path)
          File.binwrite(ARGV.fetch(0), child.to_s)
        RUBY
      )

      error = assert_raises(PROCESS::PostSpawnFailure) do
        call_process(
          context,
          process: PROCESS.new(
            process_identity: SidecarSignalGuard.new
          ),
          argv: [
            "/qualification/cases/case-one/detached.pid"
          ],
          network: false
        )
      end

      evidence = error.evidence
      assert_equal "custody_verify",
                   evidence.to_h.fetch("phase")
      assert_equal "custody_unverified",
                   evidence.to_h.fetch("reason")
      assert_equal "failed",
                   evidence.to_h.dig("cleanup", "status")
      assert_nil evidence.to_h.dig(
        "cleanup",
        "live_processes"
      )
      assert_operator(
        Hive::WorkflowPackage::CanonicalJSON
          .generate(evidence.to_h)
          .bytesize,
        :<=,
        PROCESS::FAILURE_MAX_BYTES
      )
      serialized = JSON.generate(evidence.to_h)
      refute evidence.to_h.key?("pid")
      refute evidence.to_h.key?("path")
      refute evidence.to_h.key?("environment")
      refute_includes serialized, "custody is unbound"
      assert_equal(
        evidence.to_h,
        PROCESS::FailureEvidence.from_h(evidence.to_h).to_h
      )
      tampered = JSON.parse(serialized)
      tampered["reason"] = "controller_failure"
      assert_raises(Hive::ConfigError) do
        PROCESS::FailureEvidence.from_h(tampered)
      end
      assert_operator Integer(File.binread(pid_path)), :positive?
    end
  end

  def test_identity_failure_reaps_the_owned_process_group
    with_process_workspace do |context|
      identity = MissingIdentity.new
      write_executable(
        context.fetch(:executable),
        "sleep 30\n"
      )

      error = assert_raises(PROCESS::PostSpawnFailure) do
        call_process(
          context,
          process: PROCESS.new(process_identity: identity),
          argv: [],
          network: false
        )
      end

      assert_equal "identity",
                   error.evidence.to_h.fetch("phase")
      assert_equal "identity_unavailable",
                   error.evidence.to_h.fetch("reason")
      assert_equal "unverified",
                   error.evidence.to_h.dig("cleanup", "status")
      assert_nil error.evidence.to_h.dig(
        "cleanup",
        "live_processes"
      )
      assert_raises(Errno::ESRCH) do
        Process.kill(0, identity.pid)
      end
      assert_raises(Errno::ESRCH) do
        Process.kill(0, -identity.pid)
      end
    end
  end

  def test_pre_spawn_failure_remains_an_ordinary_configuration_error
    with_process_workspace do |context|
      error = assert_raises(Hive::ConfigError) do
        call_process(
          context,
          argv: [],
          network: false
        )
      end

      refute_kind_of PROCESS::PostSpawnFailure, error
      assert_match(/process is unavailable/, error.message)
    end
  end

  private

  def with_process_workspace
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      workspace = File.join(root, "workspace")
      source = File.join(workspace, "targets", "source")
      installed =
        File.join(workspace, "targets", "installed")
      installed_package =
        File.join(installed, "gems", "hive-cli-test")
      case_root =
        File.join(workspace, "cases", "case-one")
      request =
        File.join(workspace, "requests", "case-one.json")
      scenario = File.join(
        workspace,
        "inputs",
        "scenarios",
        "case-one.yml"
      )
      [
        File.join(source, "bin"),
        File.join(source, "lib"),
        File.join(source, "config"),
        File.join(source, "schemas"),
        File.join(source, "templates"),
        File.join(source, "modules", "patrol"),
        File.join(source, "modules", "architecture-patrol"),
        File.join(installed, "bin"),
        File.join(installed, "rubygems-bin"),
        File.join(installed_package, "lib"),
        File.join(installed_package, "modules", "patrol"),
        File.join(
          installed_package,
          "modules",
          "architecture-patrol"
        ),
        case_root,
        File.dirname(request),
        File.dirname(scenario)
      ].each do |path|
        FileUtils.mkdir_p(path, mode: 0o700)
      end
      [
        workspace,
        source,
        installed,
        case_root
      ].each { |path| File.chmod(0o700, path) }
      File.binwrite(request, "{}")
      File.binwrite(scenario, "case: one\n")
      File.binwrite(
        File.join(source, "lib", "source-only.rb"),
        "SOURCE_ONLY = true\n"
      )
      File.binwrite(
        File.join(
          installed_package,
          "lib",
          "installed-only.rb"
        ),
        "INSTALLED_ONLY = true\n"
      )
      %w[
        hive/errors.rb
        hive/modules/migration/qualification_provider_client.rb
        hive/modules/migration/qualification_provider_protocol.rb
        hive/workflow_package/canonical_json.rb
      ].each do |relative|
        destination = File.join(
          installed_package,
          "lib",
          relative
        )
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        FileUtils.copy_file(
          File.join(SOURCE_ROOT, "lib", relative),
          destination
        )
        File.chmod(0o600, destination)
      end
      [ request, scenario ].each do |path|
        File.chmod(0o600, path)
      end
      [
        File.join(source, "lib", "source-only.rb"),
        File.join(
          installed_package,
          "lib",
          "installed-only.rb"
        )
      ].each { |path| File.chmod(0o600, path) }
      executable = File.join(source, "bin", "hive")
      yield(
        workspace: workspace,
        source: source,
        installed: installed,
        installed_package: installed_package,
        case: case_root,
        executable: executable
      )
    end
  end

  def call_process(
    context,
    process: PROCESS.new,
    executable: context.fetch(:executable),
    candidate_root: context.fetch(:source),
    provider_binding: nil,
    argv:,
    timeout_seconds: 5,
    network:
  )
    process.call(
      executable: executable,
      argv: argv,
      workspace: context.fetch(:workspace),
      source_root: context.fetch(:source),
      installed_root: context.fetch(:installed),
      candidate_root: candidate_root,
      case_root: context.fetch(:case),
      request_ref: "requests/case-one.json",
      scenario_ref: "inputs/scenarios/case-one.yml",
      timeout_seconds: timeout_seconds,
      network: network,
      provider_binding: provider_binding,
      hive_home: File.join(
        context.fetch(:case),
        "sandbox",
        "hive-home"
      )
    )
  end

  def write_executable(path, body)
    File.binwrite(
      path,
      "#!#{RbConfig.ruby}\n#{body}"
    )
    File.chmod(0o700, path)
  end
end
