require "test_helper"
require "open3"
require "hive/task"
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
      assert_equal [ output ], captured.fetch(:opencode_edit_patterns)
      assert_empty captured.fetch(:opencode_bash_patterns)
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
                   captured.fetch(:opencode_edit_patterns)
      assert_equal [ "*" ], captured.fetch(:opencode_bash_patterns)
    end
  end

  private

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
