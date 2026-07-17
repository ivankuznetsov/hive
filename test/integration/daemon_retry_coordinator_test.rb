require "test_helper"
require "hive/attempts/store"
require "hive/daemon/child_supervisor"
require "hive/daemon/retry_coordinator"
require "hive/diagnostic_evidence"
require_relative "../support/retry_coordinator_helpers"

class DaemonRetryCoordinatorIntegrationTest < Minitest::Test
  include HiveTestHelper
  include RetryCoordinatorTestHelpers

  NOW = Time.utc(2026, 7, 17, 12, 0, 0)

  def test_restart_preserves_retry_four_absolute_deadline_and_partial_work
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      task_dir = File.join(dir, "task")
      FileUtils.mkdir_p(task_dir)
      artifact = File.join(task_dir, "partial-work.txt")
      File.write(artifact, "preserve me\n")
      current_time = NOW
      coordinator = coordinator(task_dir, store, -> { current_time })

      fourth = nil
      4.times do |index|
        attempt = create_failed_retry_attempt(store, id: "attempt-#{index}", now: current_time)
        fourth = coordinator.report_failure(
          **retry_failure_args(attempt, code: "agent_died", terminal_event_id: "terminal-#{index}")
        )
        current_time += 1_000
      end
      deadline = Time.iso8601(fourth.to_h.fetch("retry_after"))
      current_time = deadline - 120

      restarted = coordinator(task_dir, store, -> { current_time })
      assert_equal fourth.to_h, restarted.current.to_h
      assert_nil restarted.evaluate_due
      assert_equal "preserve me\n", File.read(artifact)

      current_time = deadline
      assert_equal "ready", restarted.evaluate_due.state
      assert_equal 4, restarted.current.retry_count
    end
  end

  def test_successor_spawn_uses_current_daemon_environment_without_persisting_secrets
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      task_dir = File.join(dir, "task")
      FileUtils.mkdir_p(task_dir)
      attempt = create_failed_retry_attempt(store, id: "failed", now: NOW)
      coordinator = coordinator(task_dir, store, -> { NOW })
      evidence = Hive::DiagnosticEvidence.sanitize_retry(
        "provider" => "codex", "tool" => "honeycomb-mcp",
        "message" => "401 missing bearer auth API_TOKEN=environment-a-secret",
        "authorization" => "Bearer durable-secret"
      )
      coordinator.report_failure(
        **retry_failure_args(
          attempt, code: "codex_auth", terminal_event_id: "terminal-auth", evidence: evidence
        )
      )

      output = File.join(dir, "observed.json")
      fake_hive = File.join(dir, "fake-hive")
      File.write(fake_hive, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        File.write(ENV.fetch("OBSERVED_ENV_PATH"), JSON.generate(
          "profile" => ENV["HIVE_PROVIDER_PROFILE"],
          "path" => ENV["PATH"],
          "mcp" => ENV["HIVE_MCP_CONFIG"]
        ))
        puts JSON.generate("ok" => true)
      RUBY
      File.chmod(0o755, fake_hive)
      supervisor = Hive::Daemon::ChildSupervisor.new(
        hive_bin: fake_hive,
        log_dir_for_task: ->(_project, _slug) { File.join(dir, "logs") }
      )

      with_env(
        "OBSERVED_ENV_PATH" => output,
        "HIVE_PROVIDER_PROFILE" => "profile-b",
        "HIVE_MCP_CONFIG" => "mcp-b.json",
        "PATH" => "/runtime-b:#{ENV.fetch('PATH', '')}"
      ) do
        supervisor.spawn(
          command_string: "hive run durable-task --stage 4-execute",
          project: "demo", slug: "durable-task", stage: "4-execute",
          log_state_path: File.join(dir, "logs", "successor.log")
        )
        deadline = Time.now + 5
        loop do
          break unless supervisor.reap_all.empty?
          raise "successor did not exit" if Time.now >= deadline

          sleep 0.02
        end
      end

      observed = JSON.parse(File.read(output))
      assert_equal "profile-b", observed.fetch("profile")
      assert_includes observed.fetch("path"), "/runtime-b",
                      "successor must inherit the daemon's environment at spawn time"
      assert_equal "mcp-b.json", observed.fetch("mcp")
      durable = File.read(File.join(task_dir, "events.jsonl")) +
        File.read(File.join(task_dir, "task-projection.json"))
      refute_includes durable, "environment-a-secret"
      refute_includes durable, "durable-secret"
      refute_includes durable, "profile-b"
      refute_includes durable, "mcp-b.json"
    end
  end

  private

  def coordinator(task_dir, store, clock)
    Hive::Daemon::RetryCoordinator.new(
      task_folder: task_dir, attempt_store: store, clock: clock,
      id_generator: -> { SecureRandom.uuid }
    )
  end
end
