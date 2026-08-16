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

  def test_plain_output_and_missing_log_are_explicit
    command = Hive::Commands::Task.new("unused")
    document = {
      "headline" => { "label" => "Needs review" },
      "action" => { "label" => "Review" },
      "result" => { "primary" => { "reference" => "report.md" } },
      "usage" => { "coverage" => "partial" }
    }

    out, err = capture_io { command.send(:emit, document) }
    assert_empty err
    assert_equal "Needs review\nAction: Review\nPrimary result: report.md\nUsage: partial\n", out

    error = assert_raises(Hive::Error) do
      Hive::Commands::Task.new("unused", log: true).send(:emit, document)
    end
    assert_match(/no receipt-correlated diagnostic log/, error.message)
  end

  def test_default_log_reader_uses_explicit_and_default_attempt_roots
    with_tmp_global_config do |home|
      default_root = File.join(home, "attempts", "v4")
      explicit_root = File.join(home, "explicit-attempts")
      FileUtils.mkdir_p(default_root)
      FileUtils.mkdir_p(explicit_root)
      command = Hive::Commands::Task.new("unused", log: true)

      with_env("HIVE_ATTEMPT_STORE_ROOT" => nil) do
        assert_instance_of Hive::TaskWorkspace::CorrelatedLog,
                           command.send(:default_log_reader)
      end
      with_env("HIVE_ATTEMPT_STORE_ROOT" => explicit_root) do
        assert_instance_of Hive::TaskWorkspace::CorrelatedLog,
                           command.send(:default_log_reader)
      end
    end
  end

  def test_status_lookup_falls_back_to_archive_and_rejects_missing_tasks
    task = Struct.new(:stage_index, :stage_name, :slug).new(4, "execute", "task")
    command = Hive::Commands::Task.new(
      "unused", clock: -> { Time.utc(2026, 8, 17, 1, 2, 3) }
    )
    command.define_singleton_method(:status_project) do |_project, archive:, stage:|
      raise "wrong stage" unless stage == "4-execute"

      { "tasks" => archive ? [ { "slug" => "task", "action" => "archived" } ] : [] }
    end

    row, archived, observed_at = command.send(:status_attributes, {}, task)
    assert_equal "task", row.fetch("slug")
    assert archived
    assert_equal "2026-08-17T01:02:03.000000Z", observed_at

    command.define_singleton_method(:status_project) { |*| { "tasks" => [] } }
    assert_raises(Hive::InvalidTaskPath) do
      command.send(:status_attributes, {}, task)
    end
  end
end
