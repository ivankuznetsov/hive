require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/workflow"
require "hive/workflow_selection"
require "hive/workflows/descriptor_parser"
require "hive/workflows/project"

class WorkflowNewTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

  def test_scaffolds_blank_workflow_descriptor_and_instruction
    with_initialized_project do |project_root|
      stdout = StringIO.new

      payload = Hive::Commands::Workflow.new!("my-flow", project_root: project_root, stdout: stdout)

      descriptor_path = File.join(project_root, ".hive-state", "workflows", "my-flow.yml")
      instruction_path = File.join(project_root, ".hive-state", "workflows", "my-flow", "work.md")
      assert_equal true, payload.fetch("ok")
      assert_equal "my-flow", payload.fetch("id")
      assert_equal descriptor_path, payload.fetch("descriptor_path")
      assert_equal instruction_path, payload.fetch("instruction_path")
      assert_includes stdout.string, "hive: created workflow my-flow"
      assert_includes stdout.string, "hive new #{File.basename(project_root)} --workflow my-flow"

      assert File.file?(descriptor_path)
      assert_equal "Edit this file to define what the `work` stage should do.\n", File.read(instruction_path)

      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
      assert_equal :"my-flow", workflow.id
      assert_equal %w[inbox work done], workflow.stage_names
      assert_equal :inert, workflow.stages[0].kind
      assert_equal :agent, workflow.stages[1].kind
      assert_equal instruction_path, workflow.stages[1].instruction
      assert_nil workflow.stages[1].skill
      assert_equal :inert, workflow.stages[2].kind

      assert_equal :"my-flow", Hive::WorkflowSelection.fetch!("my-flow", project_root: project_root).id
      assert_includes Hive::Workflows.all_stage_dirs, "2-work"

      log = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s", "-1").strip
      assert_equal "hive: workflows/my-flow created", log
    end
  end

  def test_json_success_payload
    with_initialized_project do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("new", "json-flow", project_root: project_root, json: true).call
      end

      assert_equal Hive::ExitCodes::SUCCESS, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal true, payload.fetch("ok")
      assert_equal "json-flow", payload.fetch("id")
      assert_match(%r{/\.hive-state/workflows/json-flow\.yml\z}, payload.fetch("descriptor_path"))
    end
  end

  def test_refuses_to_overwrite_existing_scaffold
    with_initialized_project do |project_root|
      Hive::Commands::Workflow.new!("my-flow", project_root: project_root, stdout: StringIO.new)
      instruction_path = File.join(project_root, ".hive-state", "workflows", "my-flow", "work.md")
      File.write(instruction_path, "custom body\n")

      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("my-flow", project_root: project_root, stdout: StringIO.new)
      end

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_includes error.message, "already exists"
      assert_equal "custom body\n", File.read(instruction_path)
    end
  end

  def test_json_error_payload
    with_initialized_project do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("new", "coding", project_root: project_root, json: true).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_equal "UsageError", payload.fetch("error_class")
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
      assert_includes payload.fetch("message"), "reserved"
      # The rejected id rides a structured `value` field so an agent recovers it
      # without regexing the message (UsageError#value surfaced via extras).
      assert_equal "coding", payload.fetch("value")
    end
  end

  # Round-trip: hive-workflow-new is enveloped like every other hive-* command,
  # so BOTH arms must validate against the published schema. The usage arm
  # covers extras too: reserved-id errors carry `value`; missing-subcommand
  # errors carry `expected`. The no-id ("missing workflow id") case also carries
  # `value`, but is exercised only as a raised message via `new!`
  # (test_rejects_reserved_and_invalid_ids) — its enveloped `value` shape is
  # locked here by the reserved-id arm, not driven through the envelope separately.
  def test_json_envelopes_validate_against_published_schema
    with_initialized_project do |project_root|
      schemer = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-new")))
      )

      ok_out, = with_captured_exit do
        Hive::Commands::Workflow.new("new", "round-trip-flow", project_root: project_root, json: true).call
      end
      ok_payload = JSON.parse(ok_out)
      ok_errors = schemer.validate(ok_payload).map { |e| e["error"] }
      assert_empty ok_errors,
                   "hive-workflow-new SuccessPayload must validate (errors: #{ok_errors.inspect})"

      err_out, = with_captured_exit do
        Hive::Commands::Workflow.new("new", "coding", project_root: project_root, json: true).call
      end
      err_payload = JSON.parse(err_out)
      assert_equal "coding", err_payload.fetch("value")
      err_errors = schemer.validate(err_payload).map { |e| e["error"] }
      assert_empty err_errors,
                   "hive-workflow-new usage ErrorPayload (with `value`) must validate " \
                   "against the published schema (errors: #{err_errors.inspect})"

      missing_out, = with_captured_exit do
        Hive::Commands::Workflow.new(nil, nil, project_root: project_root, json: true).call
      end
      missing_payload = JSON.parse(missing_out)
      assert_equal [ "new" ], missing_payload.fetch("expected")
      missing_errors = schemer.validate(missing_payload).map { |e| e["error"] }
      assert_empty missing_errors,
                   "hive-workflow-new usage ErrorPayload (with `expected`) must validate " \
                   "against the published schema (errors: #{missing_errors.inspect})"
    end
  end

  def test_json_config_error_payload_rolls_back_and_classifies_config
    with_initialized_project do |project_root|
      error = Hive::ConfigError.new("descriptor boom")
      out, err, status = with_replaced_singleton_method(
        Hive::Workflows::DescriptorParser, :parse_file, ->(_path) { raise error }
      ) do
        with_captured_exit do
          Hive::Commands::Workflow.new("new", "cfg-flow", project_root: project_root, json: true).call
        end
      end

      assert_equal error.exit_code, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_equal "config", payload.fetch("error_kind")
      # validate_descriptor! raised inside the rollback-protected begin, so the
      # scaffold files must be gone.
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "cfg-flow.yml"))
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "cfg-flow"))
    end
  end

  def test_json_git_error_payload_classifies_git
    with_initialized_project do |project_root|
      out, err, status = with_replaced_singleton_method(
        Hive::Lock, :with_commit_lock, ->(_path, &_blk) { raise Hive::GitError, "push failed" }
      ) do
        with_captured_exit do
          Hive::Commands::Workflow.new("new", "git-flow", project_root: project_root, json: true).call
        end
      end

      assert_equal Hive::ExitCodes::SOFTWARE, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal "git", payload.fetch("error_kind")
      # commit_scaffold! is inside the rollback-protected begin: the scaffold
      # files must be removed when the commit fails.
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "git-flow.yml"))
    end
  end

  def test_json_concurrent_run_error_payload_classifies_concurrent
    with_initialized_project do |project_root|
      out, err, status = with_replaced_singleton_method(
        Hive::Lock, :with_commit_lock, ->(_path, &_blk) { raise Hive::ConcurrentRunError.new("locked") }
      ) do
        with_captured_exit do
          Hive::Commands::Workflow.new("new", "busy-flow", project_root: project_root, json: true).call
        end
      end

      assert_equal Hive::ExitCodes::TEMPFAIL, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal "concurrent_run", payload.fetch("error_kind")
    end
  end

  def test_json_disk_write_error_rides_the_envelope_as_error_kind
    with_initialized_project do |project_root|
      out, err, status = with_replaced_singleton_method(
        FileUtils, :mkdir_p, ->(*_args) { raise Errno::EACCES, "denied" }
      ) do
        with_captured_exit do
          Hive::Commands::Workflow.new("new", "disk-flow", project_root: project_root, json: true).call
        end
      end

      # The disk fault from write_scaffold!'s mkdir_p must ride the JSON envelope
      # (error_kind=error, no raw backtrace on stderr), not escape to bin/hive.
      assert_empty err
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_equal "error", payload.fetch("error_kind")
      assert_equal Hive::ExitCodes::GENERIC, status
    end
  end

  def test_rejects_reserved_and_invalid_ids
    with_tmp_dir do |project_root|
      missing = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("", project_root: project_root, stdout: StringIO.new)
      end
      assert_includes missing.message, "missing workflow id"

      reserved = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("coding", project_root: project_root, stdout: StringIO.new)
      end
      assert_includes reserved.message, "reserved"

      invalid = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("Bad_Id", project_root: project_root, stdout: StringIO.new)
      end
      assert_includes invalid.message, "invalid workflow id"
    end
  end

  def test_rolls_back_files_when_generated_descriptor_fails_validation
    with_initialized_project do |project_root|
      error = Hive::ConfigError.new("boom")
      with_replaced_singleton_method(Hive::Workflows::DescriptorParser, :parse_file, lambda { |_path|
        raise error
      }) do
        raised = assert_raises(Hive::ConfigError) do
          Hive::Commands::Workflow.new!("broken-flow", project_root: project_root, stdout: StringIO.new)
        end
        assert_same error, raised
      end

      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "broken-flow.yml"))
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "broken-flow"))
    end
  end

  def test_call_reports_unknown_subcommand_as_usage
    with_initialized_project do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("save", "my-flow", project_root: project_root).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty out
      assert_equal "hive workflow: unknown workflow subcommand \"save\" (expected: new)\n", err
    end
  end

  def test_call_reports_missing_subcommand_as_usage
    with_tmp_dir do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new(nil, nil, project_root: project_root).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty out
      assert_equal "hive workflow: missing SUBCOMMAND (expected: new)\n", err
    end
  end

  def test_json_reports_missing_subcommand_with_expected_values
    with_tmp_dir do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new(nil, nil, project_root: project_root, json: true).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
      assert_equal "missing SUBCOMMAND (expected: new)", payload.fetch("message")
      assert_equal [ "new" ], payload.fetch("expected")
      refute payload.key?("value")
    end
  end

  def test_json_reports_unknown_subcommand_with_value_and_expected_values
    with_tmp_dir do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("bogus", nil, project_root: project_root, json: true).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty err
      payload = JSON.parse(out)
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal "unknown workflow subcommand \"bogus\" (expected: new)", payload.fetch("message")
      assert_equal "bogus", payload.fetch("value")
      assert_equal [ "new" ], payload.fetch("expected")
    end
  end

  private

    def with_initialized_project
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          capture_io { Hive::Commands::Init.new(project_root).call }
          yield project_root
        end
      end
    end
end
