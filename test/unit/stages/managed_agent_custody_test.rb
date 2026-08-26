require "test_helper"
require "open3"
require "hive/task"
require "hive/attempts/context"
require "hive/attempts/diagnostic_channel"
require "hive/stages/managed_agent_custody"

class ManagedAgentCustodyTest < Minitest::Test
  include HiveTestHelper

  PROTECTED_FILES = %w[meta.yml worktree.yml].freeze

  def test_launch_agent_forwards_stage_parameters_and_classifies_clean_custody
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      captured = nil
      spawn = lambda do |_task, **kwargs|
        captured = kwargs
        kwargs.fetch(:agent_custody).call do
          File.write(output, "{}")
          { status: :ok }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal({ status: :ok, custody: :clean,
                     diagnostic: "artifact custody validated" }, result)
      assert_equal task.project_root, captured.fetch(:cwd)
      assert_equal "patrol-fix-inbox", captured.fetch(:log_label)
      assert_equal :exit_code_only, captured.fetch(:status_mode)
      assert_includes captured.fetch(:add_dirs), task.project_root
      assert_includes captured.fetch(:add_dirs), task.folder
      assert_includes captured.fetch(:prompt),
                      "Return that same JSON object as your complete final response"
    end
  end

  def test_launch_agent_classifies_missing_output
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call { { status: :ok } }
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :invalid_output, result.fetch(:custody)
      assert_includes result.fetch(:diagnostic), "required output"
    end
  end

  def test_launch_agent_materializes_an_exact_final_json_report_before_validation
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      report = {
        "schema" => "hive-patrol-fix-inbox-report",
        "schema_version" => 1,
        "route" => "reject"
      }
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :ok,
            final_message: JSON.generate(report),
            final_message_truncated: false
          }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :clean, result.fetch(:custody)
      assert_equal report, JSON.parse(File.read(output))
    end
  end

  def test_launch_agent_accepts_clean_output_after_pi_retries_a_provider_error
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      report = {
        "schema" => "hive-patrol-fix-inbox-report",
        "schema_version" => 1,
        "route" => "reject"
      }
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :error,
            exit_code: 0,
            timed_out: false,
            error_reason: "provider_error",
            final_message: JSON.generate(report),
            final_message_truncated: false,
            provider_error: {
              kind: :provider_error,
              provider: :pi,
              message: "Stream ended without finish_reason"
            }
          }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :clean, result.fetch(:custody)
      assert_equal report, JSON.parse(File.read(output))
    end
  end

  def test_launch_agent_accepts_clean_output_after_pi_retries_a_rate_limit
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      report = {
        "schema" => "hive-patrol-fix-inbox-report",
        "schema_version" => 1,
        "route" => "reject"
      }
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :error,
            exit_code: 0,
            timed_out: false,
            error_reason: "limits_reached",
            final_message: JSON.generate(report),
            final_message_truncated: false,
            provider_error: {
              kind: :rate_limited,
              provider: :pi,
              status_code: 429,
              message: "provider is temporarily rate-limited"
            }
          }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :ok, result.fetch(:status)
      assert_equal :clean, result.fetch(:custody)
      assert_equal report, JSON.parse(File.read(output))
    end
  end

  def test_launch_agent_does_not_accept_a_provider_retry_without_clean_output
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :error,
            exit_code: 0,
            timed_out: false,
            error_reason: "provider_error",
            provider_error: { kind: :provider_error, provider: :pi }
          }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :error, result.fetch(:status)
      assert_equal :invalid_output, result.fetch(:custody)
    end
  end

  def test_failed_agent_publishes_typed_process_diagnostic_through_attempt_context
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :error, exit_code: 17, timed_out: false,
            cancelled: false, signal: nil, error_reason: "agent_exit"
          }
        end
      end

      result, frame = capture_diagnostic(stage: "1-inbox") do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          launch(task, output)
        end
      end

      assert_equal :error, result.fetch(:status)
      assert_equal "valid", frame.status
      assert_equal "agent_exit_nonzero", frame.document.fetch("code")
      assert_equal 17, frame.document.fetch("exit_code")
      assert_equal "opaque-generation", frame.document.fetch("task_generation")
      assert_nil frame.document.fetch("log_reference")
    end
  end

  def test_provider_failure_keeps_class_hint_and_provenance_without_raw_message
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      secret = "provider raw token github" + "_pat_" + ("A" * 24)
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          {
            status: :error, exit_code: 1, timed_out: false,
            provider_error: {
              kind: :rate_limited, provider: :pi, retry_after: 45,
              provenance: "pi_jsonl", message: secret
            }
          }
        end
      end

      _result, frame = capture_diagnostic(stage: "1-inbox") do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          launch(task, output)
        end
      end

      assert_equal "provider_rate_limited", frame.document.fetch("code")
      assert_equal "provider", frame.document.fetch("owner")
      assert_equal "45", frame.document.dig("provider", "retry_hint")
      assert_equal "pi_jsonl", frame.document.dig("provider", "provenance")
      refute_includes JSON.generate(frame.document), secret
    end
  end

  def test_invalid_fix_and_review_parser_results_publish_typed_report_diagnostics
    {
      "2-fix" => [ "fix_report", "fix_report_invalid" ],
      "4-review" => [ "review_report", "agent_report_invalid" ]
    }.each do |stage, (parser, code)|
      _result, frame = capture_diagnostic(stage: stage) do
        Hive::Stages::ManagedAgentCustody.publish_report_invalid(
          stage: stage, parser: parser, detail: "malformed report"
        )
      end

      assert_equal code, frame.document.fetch("code")
      assert_equal "invalid", frame.document.fetch("report_status")
      assert_equal parser, frame.document.fetch("report_parser")
    end
  end

  def test_git_config_firewall_tamper_normalizes_restoration_state
    restoration = Hive::ArtifactFirewall::Restoration.new(
      attempted: true, succeeded: true, diagnostic: "restored"
    )
    violation = Hive::ArtifactFirewall::Violation.new(
      kind: :protected_changed, label: "repository config",
      path: "/private/repository/config", diagnostic: "changed"
    )
    report = Hive::ArtifactFirewall::Report.new(
      snapshot_id: "snapshot", status: :tampered_restored,
      violations: [ violation ], restoration: restoration,
      diagnostic: "repository config restored"
    )
    envelope = Hive::Stages::ManagedAgentCustody.send(
      :diagnostic_envelope,
      { status: :ok, exit_code: 0, timed_out: false }, report,
      status: :ok, custody_status: :tampered, provider: :pi
    )
    diagnostic = Hive::PatrolFix::AttemptDiagnostic.normalize(
      envelope,
      stage: "2-fix", task_generation: "generation-1",
      attempt_id: "attempt-1", recorded_at: Time.now.utc
    )

    assert_equal "protected_git_config_tamper", diagnostic.fetch("code")
    assert_equal "tampered_restored", diagnostic.fetch("firewall_status")
    assert_equal "restored", diagnostic.fetch("firewall_restoration")
  end

  def test_launch_agent_does_not_recover_rate_limits_without_a_clean_process_exit
    [
      { exit_code: 1, timed_out: false },
      { exit_code: 0, timed_out: true }
    ].each do |process_result|
      with_task do |task|
        output = File.join(task.folder, "patrol-fix-inbox-report.json")
        spawn = lambda do |_task, agent_custody:, **|
          agent_custody.call do
            File.write(output, "{}")
            {
              status: :error,
              error_reason: "limits_reached",
              provider_error: { kind: :rate_limited, provider: :pi },
              **process_result
            }
          end
        end

        result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          launch(task, output)
        end

        assert_equal :error, result.fetch(:status), process_result.inspect
        assert_equal :clean, result.fetch(:custody), process_result.inspect
      end
    end
  end

  def test_launch_agent_does_not_recover_resource_exhaustion_with_provider_evidence
    [
      { error_reason: "model_output_limit", provider_kind: :model_output_limit },
      { error_reason: "turn_limit", provider_kind: :rate_limited }
    ].each do |failure|
      with_task do |task|
        output = File.join(task.folder, "patrol-fix-inbox-report.json")
        spawn = lambda do |_task, agent_custody:, **|
          agent_custody.call do
            File.write(output, "{}")
            {
              status: :error,
              exit_code: 0,
              timed_out: false,
              error_reason: failure.fetch(:error_reason),
              provider_error: {
                kind: failure.fetch(:provider_kind),
                provider: :pi
              }
            }
          end
        end

        result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
          launch(task, output)
        end

        assert_equal :error, result.fetch(:status), failure.inspect
        assert_equal :clean, result.fetch(:custody), failure.inspect
      end
    end
  end

  def test_launch_agent_does_not_replace_a_dangling_report_symlink_from_final_json
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          File.symlink(File.join(task.folder, "missing-target"), output)
          { status: :ok, final_message: "{}", final_message_truncated: false }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :invalid_output, result.fetch(:custody)
      assert File.symlink?(output)
    end
  end

  def test_launch_agent_classifies_protected_file_tampering
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      original_meta = File.binread(task.meta_yml_path)
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          File.write(task.meta_yml_path, "tampered: true\n")
          File.write(output, "{}")
          { status: :ok }
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :tampered, result.fetch(:custody)
      assert_includes result.fetch(:diagnostic), "meta.yml"
      assert_equal original_meta, File.binread(task.meta_yml_path)
    end
  end

  def test_launch_agent_classifies_non_hash_runner_result_as_error
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      spawn = lambda do |_task, agent_custody:, **|
        agent_custody.call do
          File.write(output, "{}")
          :unexpected
        end
      end

      result = with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
        launch(task, output)
      end

      assert_equal :error, result.fetch(:status)
      assert_equal :clean, result.fetch(:custody)
    end
  end

  def test_review_does_not_inherit_a_distinct_fix_agent
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      captured = capture_launch(task, output, cfg: opencode_config)

      assert_equal :codex, captured.fetch(:profile).name
    end
  end

  def test_opencode_review_can_write_only_its_report_without_shell
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-inbox-report.json")
      cfg = opencode_config
      cfg.fetch("patrol")["agent"] = "opencode"
      cfg.fetch("patrol")["model"] = "openrouter/stealth/ox-alpha"
      cfg.fetch("patrol")["effort"] = "high"
      captured = capture_launch(task, output, cfg: cfg)

      assert_equal "workspace-write", captured.fetch(:permission_mode)
      assert_equal :opencode, captured.fetch(:profile).name
      assert_equal "openrouter/stealth/ox-alpha", captured.fetch(:model)
      assert_equal "high", captured.fetch(:effort)
      assert_equal [ task.folder ], captured.fetch(:additional_write_roots)
      assert_equal [ output ], captured.fetch(:edit_patterns)
      assert_empty captured.fetch(:bash_patterns)
    end
  end

  def test_opencode_fix_can_edit_the_owned_worktree_and_run_shell_commands
    with_task do |task|
      output = File.join(task.folder, "patrol-fix-fix-report.json")
      captured = capture_launch(
        task, output, cfg: opencode_config, actor: "patrol_fix",
        stage: "fix", log_label: "patrol-fix-fix"
      )

      assert_equal [ task.project_root, task.folder ],
                   captured.fetch(:additional_write_roots)
      assert_equal [ File.join(task.project_root, "**"), output ],
                   captured.fetch(:edit_patterns)
      assert_equal [ "*" ], captured.fetch(:bash_patterns)
    end
  end

  private

  def capture_diagnostic(stage:)
    reader, writer = IO.pipe
    diagnostic_writer = Hive::Attempts::DiagnosticChannel::Writer.new(writer)
    context = Hive::Attempts::Context.send(
      :new,
      attempt_id: "attempt-managed", task_generation: 9,
      ownership_generation: "opaque-generation", intended_stage: stage,
      diagnostic_writer: diagnostic_writer
    )
    result = with_replaced_singleton_method(
      Hive::Attempts::Context, :current, -> { context }
    ) { yield }
    [ result, Hive::Attempts::DiagnosticChannel.read(reader) ]
  ensure
    context&.close
    [ reader, writer ].compact.each do |io|
      io.close unless io.closed?
    rescue Errno::EBADF
      nil
    end
  end

  def launch(task, output, cfg: {}, actor: "patrol_review", stage: "inbox",
             log_label: "patrol-fix-inbox")
    Hive::Stages::ManagedAgentCustody.launch_agent(
      task: task, cfg: cfg, prompt: "Inspect the selected finding.",
      output_path: output, protected_files: PROTECTED_FILES,
      actor: actor, slot: "stages.#{stage}", cwd: task.project_root,
      add_dirs: [ task.project_root, task.folder ], stage: stage,
      log_label: log_label
    )
  end

  def capture_launch(task, output, **options)
    captured = nil
    spawn = lambda do |_task, **kwargs|
      captured = kwargs
      kwargs.fetch(:agent_custody).call do
        File.write(output, "{}")
        { status: :ok }
      end
    end
    with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, spawn) do
      launch(task, output, **options)
    end
    captured
  end

  def opencode_config
    {
      "patrol" => {
        "agent" => "codex",
        "fix" => {
          "agent" => "opencode",
          "model" => "openrouter/stealth/ox-alpha",
          "effort" => "high"
        }
      }
    }
  end

  def with_task
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      git(repo, "init", "-b", "main")
      git(repo, "config", "user.email", "test@example.com")
      git(repo, "config", "user.name", "Test")
      File.write(File.join(repo, "app.rb"), "puts :ok\n")
      git(repo, "add", "app.rb")
      git(repo, "commit", "-m", "Initial")
      folder = File.join(repo, ".hive-state", "stages", "1-inbox", "repair-one")
      FileUtils.mkdir_p(folder)
      File.write(
        File.join(folder, "meta.yml"),
        { "slug" => "repair-one", "workflow" => "patrol-fix" }.to_yaml
      )
      yield Hive::Task.new(folder)
    end
  end

  def git(path, *args)
    _out, error, status = Open3.capture3("git", "-C", path, *args)
    raise error unless status.success?
  end
end
