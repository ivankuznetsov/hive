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

  private

  def launch(task, output)
    Hive::Stages::ManagedAgentCustody.launch_agent(
      task: task, cfg: {}, prompt: "Inspect the selected finding.",
      output_path: output, protected_files: PROTECTED_FILES,
      actor: "patrol_review", slot: "stages.inbox", cwd: task.project_root,
      add_dirs: [ task.project_root, task.folder ], stage: "inbox",
      log_label: "patrol-fix-inbox"
    )
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
