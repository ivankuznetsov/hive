require "test_helper"
require "base64"
require "hive/process_kill"
require "hive/web/project_capture_provider"

class WebProjectCaptureProviderTest < Minitest::Test
  include HiveTestHelper

  HOSTILE_CASES = {
    "nonzero" => /failed \(exit 7\)/,
    "timeout" => /timed out/,
    "malformed" => /malformed JSON/,
    "oversized" => /stdout exceeded/,
    "traversal" => /unsafe filename/,
    "symlink" => /not an owned regular file/,
    "special" => /not an owned regular file/,
    "missing" => /is missing/,
    "tampered" => /digest does not match/,
    "corrupt" => /valid decodable PNG/,
    "corrupt-video" => /valid decodable WEBM/,
    "evidence" => /evidence exceeded/,
    "secret" => /secret-shaped content/,
    "cleanup" => /complete cleanup/,
    "orphan" => /left child processes/
  }.freeze

  def test_hostile_provider_results_fail_closed_before_publication
    with_provider_fixture do |root, source, executable|
      HOSTILE_CASES.each do |mode, expected|
        staging = File.join(root, "staging-#{mode}")
        runtime = File.join(root, "runtime-#{mode}")
        FileUtils.mkdir_p(staging)
        provider = Hive::Web::ProjectCaptureProvider.new(
          config: {
            "name" => "fixture",
            "command" => [ "bin/provider", mode ],
            "timeout_sec" => mode == "timeout" ? 1 : 5
          },
          environment: {
            "PATH" => ENV.fetch("PATH", ""),
            "GH_TOKEN" => "must-not-leak"
          }
        )

        error = assert_raises(
          Hive::Web::ProjectCaptureProvider::ProviderError,
          "#{mode} provider result must fail closed"
        ) do
          provider.call(
            task: "demo-task",
            source_root: source,
            source_sha: "a" * 40,
            staging_root: staging,
            runtime_root: runtime
          )
        end

        assert_match expected, error.message, mode
        refute_includes error.message, "ghp_", mode
        refute File.exist?(File.join(root, "capture-manifest.json")), mode
      ensure
        FileUtils.rm_rf(staging) if staging
        FileUtils.rm_rf(runtime) if runtime
      end
      assert File.executable?(executable)
    end
  end

  def test_provider_receives_exact_context_without_ambient_credentials
    with_provider_fixture do |root, source, _executable|
      staging = File.join(root, "staging-success")
      runtime = File.join(root, "runtime-success")
      FileUtils.mkdir_p(staging)
      provider = Hive::Web::ProjectCaptureProvider.new(
        config: {
          "name" => "fixture",
          "command" => [ "bin/provider", "success" ],
          "timeout_sec" => 5
        },
        environment: {
          "PATH" => ENV.fetch("PATH", ""),
          "GH_TOKEN" => "must-not-leak"
        }
      )

      result = provider.call(
        task: "demo-task",
        source_root: source,
        source_sha: "a" * 40,
        staging_root: staging,
        runtime_root: runtime
      )

      assert_equal "demo-task", result.evidence.fetch("task")
      assert_equal File.realpath(source), result.evidence.fetch("source_root")
      assert_equal "a" * 40, result.evidence.fetch("source_sha")
      assert_nil result.evidence.fetch("gh_token")
      refute_includes result.environment_keys, "GH_TOKEN"
      assert_equal [ "proof.png" ], result.artifacts.map { |artifact| artifact.fetch("file") }
    end
  end

  def test_setsid_descendant_holding_output_pipes_is_killed_within_the_deadline
    with_provider_fixture do |root, source, _executable|
      staging = File.join(root, "staging-detached")
      runtime = File.join(root, "runtime-detached")
      pid_path = File.join(root, "detached.pid")
      FileUtils.mkdir_p(staging)
      provider = Hive::Web::ProjectCaptureProvider.new(
        config: {
          "name" => "fixture",
          "command" => [ "bin/provider", "detached", pid_path ],
          "timeout_sec" => 1
        },
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = assert_raises(Hive::Web::ProjectCaptureProvider::ProviderError) do
        provider.call(
          task: "demo-task",
          source_root: source,
          source_sha: "a" * 40,
          staging_root: staging,
          runtime_root: runtime
        )
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      detached_pid = Integer(File.read(pid_path))

      assert_match(/left child processes running/, error.message)
      assert_operator elapsed, :<, 2.5,
                      "provider call exceeded timeout_sec plus bounded custody grace"
      refute Hive::ProcessKill.pid_alive?(detached_pid),
             "detached descendant #{detached_pid} survived provider return"
    ensure
      if defined?(detached_pid) && Hive::ProcessKill.pid_alive?(detached_pid)
        Hive::ProcessKill.terminate_process(detached_pid, grace_seconds: 0.1)
      end
    end
  end

  def test_abnormal_supervisor_death_kills_the_exact_provider_tree_before_return
    with_provider_fixture do |root, source, _executable|
      staging = File.join(root, "staging-supervisor-death")
      runtime = File.join(root, "runtime-supervisor-death")
      provider_pid_path = File.join(root, "provider.pid")
      descendant_pid_path = File.join(root, "descendant.pid")
      FileUtils.mkdir_p(staging)
      provider = Hive::Web::ProjectCaptureProvider.new(
        config: {
          "name" => "fixture",
          "command" => [
            "bin/provider", "supervisor-death", provider_pid_path,
            descendant_pid_path
          ],
          "timeout_sec" => 1
        },
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )

      error = assert_raises(Hive::Web::ProjectCaptureProvider::ProviderError) do
        provider.call(
          task: "demo-task",
          source_root: source,
          source_sha: "a" * 40,
          staging_root: staging,
          runtime_root: runtime
        )
      end
      provider_pid = Integer(File.read(provider_pid_path))
      descendant_pid = Integer(File.read(descendant_pid_path))

      assert_match(/supervisor.*signal 9/i, error.message)
      refute Hive::ProcessKill.pid_alive?(provider_pid),
             "provider #{provider_pid} survived abnormal supervisor death"
      refute Hive::ProcessKill.pid_alive?(descendant_pid),
             "descendant #{descendant_pid} survived abnormal supervisor death"
    ensure
      [ provider_pid, descendant_pid ].compact.each do |pid|
        next unless Hive::ProcessKill.pid_alive?(pid)

        Hive::ProcessKill.terminate_process(pid, grace_seconds: 0.1)
      end
    end
  end

  def test_total_provider_argv_is_bounded_before_execution
    with_provider_fixture do |root, source, _executable|
      staging = File.join(root, "staging-argv")
      runtime = File.join(root, "runtime-argv")
      FileUtils.mkdir_p(staging)
      provider = Hive::Web::ProjectCaptureProvider.new(
        config: {
          "name" => "fixture",
          "command" => [ "bin/provider", "success", "x" * (16 * 1024) ],
          "timeout_sec" => 5
        },
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )

      error = assert_raises(Hive::Web::ProjectCaptureProvider::ProviderError) do
        provider.call(
          task: "demo-task",
          source_root: source,
          source_sha: "a" * 40,
          staging_root: staging,
          runtime_root: runtime
        )
      end

      assert_match(/command argv exceeded/, error.message)
      assert_empty Dir.children(staging)
    end
  end

  def test_one_item_command_executes_a_tracked_punctuation_filename_literally
    Dir.mktmpdir("project-capture-punctuation") do |root|
      source = File.join(root, "source")
      staging = File.join(root, "staging")
      runtime = File.join(root, "runtime")
      executable = File.join(source, "bin", "capture;literal")
      FileUtils.mkdir_p(File.dirname(executable))
      FileUtils.mkdir_p(staging, mode: 0o700)
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        $stdin.read
        puts JSON.generate(
          "schema" => "hive-project-capture-result",
          "schema_version" => 1,
          "status" => "failed",
          "artifacts" => [],
          "evidence" => {},
          "cleanup" => {
            "port" => "released", "processes" => "clean", "runtime" => "cleaned"
          },
          "diagnostic" => "literal executable ran"
        )
      RUBY
      FileUtils.chmod(0o755, executable)
      run!("git", "-C", source, "init", "--quiet")
      run!("git", "-C", source, "add", "--", "bin/capture;literal")
      assert_equal "bin/capture;literal",
                   run!("git", "-C", source, "ls-files", "--", "bin/capture;literal").strip
      provider = Hive::Web::ProjectCaptureProvider.new(
        config: {
          "name" => "punctuation",
          "command" => [ "bin/capture;literal" ],
          "timeout_sec" => 2
        },
        environment: { "PATH" => ENV.fetch("PATH", "") }
      )

      error = assert_raises(Hive::Web::ProjectCaptureProvider::ProviderError) do
        provider.call(
          task: "demo-task",
          source_root: source,
          source_sha: "a" * 40,
          staging_root: staging,
          runtime_root: runtime
        )
      end

      assert_match(/literal executable ran/, error.message)
    end
  end

  def test_blank_failed_diagnostics_use_the_actionable_fallback
    with_provider_fixture do |root, source, _executable|
      expectations = {
        "failed-empty" => "provider reported failure",
        "failed-whitespace" => "provider reported failure",
        "failed-actionable" => "retry after fixing the fixture"
      }
      expectations.each do |mode, expected|
        staging = File.join(root, "staging-#{mode}")
        runtime = File.join(root, "runtime-#{mode}")
        FileUtils.mkdir_p(staging, mode: 0o700)
        provider = Hive::Web::ProjectCaptureProvider.new(
          config: {
            "name" => "fixture",
            "command" => [ "bin/provider", mode ],
            "timeout_sec" => 2
          },
          environment: { "PATH" => ENV.fetch("PATH", "") }
        )

        error = assert_raises(Hive::Web::ProjectCaptureProvider::ProviderError, mode) do
          provider.call(
            task: "demo-task",
            source_root: source,
            source_sha: "a" * 40,
            staging_root: staging,
            runtime_root: runtime
          )
        end

        assert_match(/failed: #{Regexp.escape(expected)}\z/, error.message, mode)
      end
    end
  end

  private

  def with_provider_fixture
    Dir.mktmpdir("project-capture-provider") do |root|
      source = File.join(root, "source")
      executable = File.join(source, "bin", "provider")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, <<~'RUBY')
        #!/usr/bin/env ruby
        require "digest"
        require "base64"
        require "json"
        require "rbconfig"

        request = JSON.parse($stdin.read)
        staging = request.fetch("staging_root")
        mode = ARGV.fetch(0)
        clean = { "port" => "released", "processes" => "clean", "runtime" => "cleaned" }
        result = lambda do |artifacts:, cleanup: clean, status: "captured", diagnostic: nil|
          puts JSON.generate(
            "schema" => "hive-project-capture-result",
            "schema_version" => 1,
            "status" => status,
            "artifacts" => artifacts,
            "evidence" => {},
            "cleanup" => cleanup,
            "diagnostic" => diagnostic
          )
        end
        artifact = lambda do |name, path, sha: nil|
          {
            "file" => name,
            "bytes" => File.size(path),
            "sha256" => sha || Digest::SHA256.file(path).hexdigest
          }
        end
        write_png = lambda do |path|
          File.binwrite(
            path,
            Base64.decode64(
              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
            )
          )
        end

        case mode
        when "success"
          path = File.join(staging, "proof.png")
          write_png.call(path)
          puts JSON.generate(
            "schema" => "hive-project-capture-result",
            "schema_version" => 1,
            "status" => "captured",
            "artifacts" => [ artifact.call("proof.png", path) ],
            "evidence" => {
              "task" => request.fetch("task"),
              "source_root" => request.fetch("source_root"),
              "source_sha" => request.fetch("source_sha"),
              "gh_token" => ENV["GH_TOKEN"]
            },
            "cleanup" => clean,
            "diagnostic" => nil
          )
        when "nonzero"
          warn "provider exploded"
          exit 7
        when "timeout"
          sleep 3
        when "malformed"
          print "{"
        when "oversized"
          print "x" * 300_000
        when "traversal"
          result.call(artifacts: [ { "file" => "../escape.png", "bytes" => 1, "sha256" => "0" * 64 } ])
        when "symlink"
          path = File.join(staging, "link.png")
          File.symlink(__FILE__, path)
          result.call(artifacts: [ artifact.call("link.png", path) ])
        when "special"
          path = File.join(staging, "special.png")
          Dir.mkdir(path)
          result.call(artifacts: [ { "file" => "special.png", "bytes" => 1, "sha256" => "0" * 64 } ])
        when "missing"
          result.call(artifacts: [ { "file" => "missing.png", "bytes" => 1, "sha256" => "0" * 64 } ])
        when "tampered"
          path = File.join(staging, "tampered.png")
          write_png.call(path)
          result.call(artifacts: [ artifact.call("tampered.png", path, sha: "0" * 64) ])
        when "corrupt"
          path = File.join(staging, "corrupt.png")
          File.binwrite(path, "not an image")
          result.call(artifacts: [ artifact.call("corrupt.png", path) ])
        when "corrupt-video"
          path = File.join(staging, "corrupt.webm")
          File.binwrite(path, "not a video")
          result.call(artifacts: [ artifact.call("corrupt.webm", path) ])
        when "evidence"
          path = File.join(staging, "evidence.png")
          write_png.call(path)
          puts JSON.generate(
            "schema" => "hive-project-capture-result",
            "schema_version" => 1,
            "status" => "captured",
            "artifacts" => [ artifact.call("evidence.png", path) ],
            "evidence" => { "blob" => "x" * 70_000 },
            "cleanup" => clean,
            "diagnostic" => nil
          )
        when "secret"
          result.call(
            artifacts: [],
            status: "failed",
            diagnostic: "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
          )
        when "cleanup"
          path = File.join(staging, "cleanup.png")
          write_png.call(path)
          result.call(
            artifacts: [ artifact.call("cleanup.png", path) ],
            cleanup: clean.merge("runtime" => "dirty")
          )
        when "failed-empty"
          result.call(artifacts: [], status: "failed", diagnostic: "")
        when "failed-whitespace"
          result.call(artifacts: [], status: "failed", diagnostic: "   ")
        when "failed-actionable"
          result.call(
            artifacts: [], status: "failed",
            diagnostic: "retry after fixing the fixture"
          )
        when "orphan"
          path = File.join(staging, "orphan.png")
          write_png.call(path)
          Process.spawn(RbConfig.ruby, "-e", "sleep 30")
          result.call(artifacts: [ artifact.call("orphan.png", path) ])
        when "detached"
          path = File.join(staging, "detached.png")
          write_png.call(path)
          child_code = <<~'CHILD'
            Process.setsid
            File.write(ARGV.fetch(0), Process.pid.to_s)
            trap("TERM") {}
            sleep 5
          CHILD
          Process.spawn(
            RbConfig.ruby, "-e", child_code, ARGV.fetch(1),
            out: $stdout, err: $stderr
          )
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          until File.file?(ARGV.fetch(1))
            abort "detached child did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.01
          end
          result.call(artifacts: [ artifact.call("detached.png", path) ])
        when "supervisor-death"
          supervisor_pid = Process.ppid
          File.write(ARGV.fetch(1), Process.pid.to_s)
          trap("TERM") {}
          child_code = <<~'CHILD'
            Process.setsid
            File.write(ARGV.fetch(0), Process.pid.to_s)
            trap("TERM") {}
            sleep 30
          CHILD
          Process.spawn(RbConfig.ruby, "-e", child_code, ARGV.fetch(2))
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          until File.file?(ARGV.fetch(2))
            abort "supervisor-death descendant did not start" if
              Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.01
          end
          Process.kill("KILL", supervisor_pid)
          sleep 30
        else
          abort "unknown mode"
        end
      RUBY
      FileUtils.chmod(0o755, executable)
      yield root, source, executable
    end
  end
end
