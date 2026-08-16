require "test_helper"
require "json_schemer"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/task"

class TaskCommandTest < Minitest::Test
  include HiveTestHelper

  def test_native_task_json_emits_the_schema_valid_semantic_workspace
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        project = File.basename(project_root)
        capture_io { Hive::Commands::New.new(project, "inspect task").call }
        folder = Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(folder)

        out, err = capture_io do
          Hive::CLI.start([ "task", slug, "--project", project, "--json" ])
        end
        document = JSON.parse(out)
        schemer = JSONSchemer.schema(
          JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 2)))
        )

        assert_empty err
        assert_empty schemer.validate(document).to_a
        assert_equal 2, document.fetch("schema_version")
        assert_equal slug, document.dig("task", "slug")
        assert_equal "idea.md", document.dig("result", "primary", "reference")
        refute document.key?("panels")
        refute_includes document.to_s, project_root
      end
    end
  end

  def test_native_task_log_reads_only_the_current_correlated_reference
    reference = { "path" => "logs/attempt.frames", "size" => 12, "sha256" => "a" * 64 }
    document = {
      "diagnostic" => {
        "log" => { "state" => "current", "reference" => reference }
      }
    }
    observed = nil
    reader = lambda do |value|
      observed = value
      { "tail" => "exact failure\n" }
    end
    command = Hive::Commands::Task.new("unused", log: true, log_reader: reader)

    out, err = capture_io { command.send(:emit, document) }

    assert_empty err
    assert_equal "exact failure\n", out
    assert_equal reference, observed
  end

  def test_cli_forwards_the_read_only_log_option
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:call) { true }
    factory = lambda do |target, **options|
      captured = [ target, options ]
      fake
    end

    with_replaced_singleton_method(Hive::Commands::Task, :new, factory) do
      Hive::CLI.start([ "task", "task-260816-abcd", "--project", "demo", "--log" ])
    end

    assert_equal "task-260816-abcd", captured.first
    assert_equal "demo", captured.last.fetch(:project)
    assert captured.last.fetch(:log)
    refute captured.last.fetch(:json)
  end

  def test_log_and_json_are_mutually_exclusive
    error = assert_raises(Hive::InvalidTaskPath) do
      Hive::Commands::Task.new("unused", log: true, json: true)
    end

    assert_equal "--log cannot be combined with --json", error.message
  end
end
