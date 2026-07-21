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
      assert_includes stdout.string, "edit: #{instruction_path}"
      assert_includes stdout.string, "hive new #{File.basename(project_root)} --workflow my-flow"

      assert File.file?(descriptor_path)
      assert_equal "Edit this file to define what the `work` stage should do.\n", File.read(instruction_path)
      assert File.file?(File.join(File.dirname(instruction_path), "README.md"))
      assert File.file?(File.join(File.dirname(instruction_path), "honeycomb.yml"))
      readme = File.read(File.join(File.dirname(instruction_path), "README.md"))
      assert_includes readme, "# my-flow"
      %w[Behavior Prerequisites Inputs Outputs Permissions\ and\ Risks Recovery].each do |section|
        assert_includes readme, "## #{section.gsub('\\ ', ' ')}"
      end
      metadata = YAML.safe_load(File.read(File.join(File.dirname(instruction_path), "honeycomb.yml")))
      assert_equal %w[assets author description hive_min_version license source], metadata.keys.sort

      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
      assert_equal :"my-flow", workflow.id
      assert_equal %w[inbox work done], workflow.stage_names
      assert_equal :inert, workflow.stages[0].kind
      assert_equal :agent, workflow.stages[1].kind
      assert_equal instruction_path, workflow.stages[1].instruction
      assert_nil workflow.stages[1].skill
      assert_equal "development", workflow.stages[1].mapping_role
      assert_equal "my-flow-work-v1", workflow.stages[1].mapping_contract
      assert_equal :inert, workflow.stages[2].kind

      assert_equal :"my-flow", Hive::WorkflowSelection.fetch!("my-flow", project_root: project_root).id
      assert_includes Hive::Workflows.all_stage_dirs, "2-work"

      log = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s", "-1").strip
      assert_equal "hive: workflows/my-flow created", log
    end
  end

  def test_scaffolds_keyword_like_id_with_quoted_descriptor_so_it_parses
    # `no`/`yes`/`off` are valid SAFE_SLUG ids that YAML.safe_load coerces to
    # booleans when the descriptor's `id:` is emitted unquoted, failing
    # DescriptorParser's required-string check. The descriptor template quotes
    # `id:` to prevent that — pin it directly at the command that owns the
    # template, not only transitively through the init path.
    with_initialized_project do |project_root|
      payload = Hive::Commands::Workflow.new!("no", project_root: project_root, stdout: StringIO.new)

      assert_equal "no", payload.fetch("id")
      descriptor_path = File.join(project_root, ".hive-state", "workflows", "no.yml")

      # The raw descriptor quotes the id, so YAML round-trips it as the String.
      assert_includes File.read(descriptor_path), %(id: "no")
      assert_equal "no", YAML.safe_load(File.read(descriptor_path)).fetch("id"),
                   "a keyword-like id must survive YAML.safe_load as a String, not coerce to false"

      # And the descriptor parses, resolving its id back to the symbol form.
      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
      assert_equal :no, workflow.id
      assert_equal :no, Hive::WorkflowSelection.fetch!("no", project_root: project_root).id
    end
  end

  def test_scaffolds_from_a_named_template
    with_initialized_project do |project_root|
      stdout = StringIO.new

      payload = Hive::Commands::Workflow.new!(
        "brief", project_root: project_root, stdout: stdout, template: "research"
      )

      workflows = File.join(project_root, ".hive-state", "workflows")
      assert_equal "brief", payload.fetch("id")

      # The descriptor carries the SAMPLE's multi-stage shape, renamed to the id.
      workflow = Hive::Workflows::DescriptorParser.parse_file(File.join(workflows, "brief.yml"))
      assert_equal %w[inbox gather synthesize report done], workflow.stage_names
      assert_equal %i[inert agent agent agent inert], workflow.stages.map(&:kind)
      workflow.executable_slots.each do |slot|
        assert slot.actor.mapping_role
        assert slot.actor.mapping_contract
      end

      # Every stage instruction is copied verbatim from the sample — real
      # content, not the blank placeholder — and named per stage.
      %w[gather synthesize report].each do |stage|
        path = File.join(workflows, "brief", "#{stage}.md")
        assert File.file?(path), "#{stage}.md should be scaffolded"
        refute_includes File.read(path), "Edit this file",
                        "#{stage}.md must be the sample instruction, not the blank stub"
      end
      assert_equal File.join(workflows, "brief", "gather.md"),
                   workflow.stages.find { |s| s.name == "gather" }.instruction

      # A multi-stage template points the operator at the directory of stage
      # instructions to fill in, not a single file.
      assert_includes stdout.string, "edit: #{File.join(workflows, 'brief')}/"
      assert_includes stdout.string, "3 stage instructions"
    end
  end

  def test_retired_flagship_templates_point_to_honeycomb
    with_initialized_project do |project_root|
      %w[architecture writing].each do |template|
        error = assert_raises(Hive::Commands::Workflow::UsageError) do
          Hive::Commands::Workflow.new!(
            "flagship", project_root: project_root, stdout: StringIO.new, template: template
          )
        end

        assert_equal Hive::ExitCodes::USAGE, error.exit_code
        assert_includes error.message, %(workflow template "#{template}" moved to Honeycomb)
        assert_includes error.message, "hive workflow install honeycomb/#{template}"
        assert_equal %w[blank research], error.expected
      end
    end
  end

  def test_unknown_template_is_a_usage_error_listing_available
    with_initialized_project do |project_root|
      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.new!("x", project_root: project_root, stdout: StringIO.new, template: "bogus")
      end

      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_includes error.message, %(unknown workflow template "bogus")
      assert_equal %w[blank research], error.expected
      # An invalid template is rejected before any scaffold is written.
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "x.yml"))
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
  # errors carry `expected`; unknown-subcommand errors carry both `value` and
  # `expected` (the only shape exercising the combined payload). The
  # "missing workflow id" case is exercised only as a raised message via
  # `new!("")` (test_rejects_reserved_and_invalid_ids): an empty-string id
  # raises with `value: ""` (kept), while an omitted id (nil) is stripped by
  # error_extras so the envelope carries no `value` key. Either way its
  # enveloped shape is locked here by the reserved-id arm's `value`, not driven
  # through the envelope separately.
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
      assert_equal %w[new install list update remove publish], missing_payload.fetch("expected")
      missing_errors = schemer.validate(missing_payload).map { |e| e["error"] }
      assert_empty missing_errors,
                   "hive-workflow-new usage ErrorPayload (with `expected`) must validate " \
                   "against the published schema (errors: #{missing_errors.inspect})"

      unknown_out, = with_captured_exit do
        Hive::Commands::Workflow.new("bogus", nil, project_root: project_root, json: true).call
      end
      unknown_payload = JSON.parse(unknown_out)
      assert_equal "bogus", unknown_payload.fetch("value")
      assert_equal %w[new install list update remove publish], unknown_payload.fetch("expected")
      unknown_errors = schemer.validate(unknown_payload).map { |e| e["error"] }
      assert_empty unknown_errors,
                   "hive-workflow-new usage ErrorPayload (with `value` AND `expected`) must " \
                   "validate against the published schema (errors: #{unknown_errors.inspect})"
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

  def test_normalize_and_validate_id_reuses_workflow_new_errors
    assert_equal "my-flow", Hive::Commands::Workflow.normalize_and_validate_id!(" my-flow ")

    [ "coding", "content", "bench" ].each do |id|
      error = assert_raises(Hive::Commands::Workflow::UsageError) do
        Hive::Commands::Workflow.normalize_and_validate_id!(id)
      end
      assert_equal Hive::ExitCodes::USAGE, error.exit_code
      assert_includes error.message, "workflow id #{id.inspect} is reserved by a built-in workflow"
    end

    missing = assert_raises(Hive::Commands::Workflow::UsageError) do
      Hive::Commands::Workflow.normalize_and_validate_id!(" ")
    end
    assert_equal Hive::ExitCodes::USAGE, missing.exit_code
    assert_includes missing.message, "missing workflow id"

    invalid = assert_raises(Hive::Commands::Workflow::UsageError) do
      Hive::Commands::Workflow.normalize_and_validate_id!("Bad_Id")
    end
    assert_equal Hive::ExitCodes::USAGE, invalid.exit_code
    assert_includes invalid.message, "invalid workflow id"
  end

  def test_scaffold_files_writes_and_validates_without_committing
    with_initialized_project do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      before_log = run!("git", "-C", hive_state, "rev-parse", "HEAD").strip

      scaffold = Hive::Commands::Workflow.scaffold_files!("drafting", project_root: project_root)
      paths = scaffold.fetch(:paths)

      assert_equal "drafting", scaffold.fetch(:id)
      assert File.file?(paths.fetch(:descriptor))
      assert File.file?(paths.fetch(:instruction))
      workflow = Hive::Workflows::DescriptorParser.parse_file(paths.fetch(:descriptor))
      assert_equal :drafting, workflow.id
      assert_equal before_log, run!("git", "-C", hive_state, "rev-parse", "HEAD").strip,
                   "scaffold_files! must leave commit ownership to its caller"

      Hive::Commands::Workflow.rollback_scaffold(paths)
      refute File.exist?(paths.fetch(:descriptor))
      refute File.exist?(paths.fetch(:instruction_dir))
    end
  end

  def test_scaffold_collision_reports_existing_scaffold_paths
    with_initialized_project do |project_root|
      refute Hive::Commands::Workflow.scaffold_collision?("drafting", project_root: project_root),
             "a free workflow id should not report a scaffold collision"

      scaffold = Hive::Commands::Workflow.scaffold_files!("drafting", project_root: project_root)

      assert Hive::Commands::Workflow.scaffold_collision?("drafting", project_root: project_root),
             "an existing descriptor/instruction scaffold should report a collision"
      Hive::Commands::Workflow.rollback_scaffold(scaffold.fetch(:paths))
    end
  end

  def test_scaffold_files_rolls_back_when_generated_descriptor_fails_validation
    with_initialized_project do |project_root|
      error = Hive::ConfigError.new("boom")
      with_replaced_singleton_method(Hive::Workflows::DescriptorParser, :parse_file, lambda { |_path|
        raise error
      }) do
        raised = assert_raises(Hive::ConfigError) do
          Hive::Commands::Workflow.scaffold_files!("broken-helper-flow", project_root: project_root)
        end
        assert_same error, raised
      end

      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "broken-helper-flow.yml"))
      refute File.exist?(File.join(project_root, ".hive-state", "workflows", "broken-helper-flow"))
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
    with_tmp_dir do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new("save", "my-flow", project_root: project_root).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty out
      assert_equal "hive workflow: unknown workflow subcommand \"save\" (expected: new, install, list, update, remove, publish)\n", err
    end
  end

  def test_call_reports_missing_subcommand_as_usage
    with_tmp_dir do |project_root|
      out, err, status = with_captured_exit do
        Hive::Commands::Workflow.new(nil, nil, project_root: project_root).call
      end

      assert_equal Hive::ExitCodes::USAGE, status
      assert_empty out
      assert_equal "hive workflow: missing SUBCOMMAND (expected: new, install, list, update, remove, publish)\n", err
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
      assert_equal "UsageError", payload.fetch("error_class")
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
      assert_equal "missing SUBCOMMAND (expected: new, install, list, update, remove, publish)", payload.fetch("message")
      assert_equal %w[new install list update remove publish], payload.fetch("expected")
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
      assert_equal false, payload.fetch("ok")
      assert_equal "UsageError", payload.fetch("error_class")
      assert_equal "usage", payload.fetch("error_kind")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
      assert_equal "unknown workflow subcommand \"bogus\" (expected: new, install, list, update, remove, publish)", payload.fetch("message")
      assert_equal "bogus", payload.fetch("value")
      assert_equal %w[new install list update remove publish], payload.fetch("expected")
    end
  end

  def test_rollback_scaffold_warns_with_errno_when_a_leftover_cannot_be_removed
    with_initialized_project do |project_root|
      scaffold = Hive::Commands::Workflow.scaffold_files!("stuck-flow", project_root: project_root)
      paths = scaffold.fetch(:paths)

      # Force the removal to fault (EACCES) so the files genuinely survive
      # cleanup; the warning must then name each leftover AND its captured errno,
      # not a bare path list.
      with_replaced_singleton_method(FileUtils, :remove_entry, lambda { |path, *_args|
        raise Errno::EACCES, path.to_s
      }) do
        _out, err = capture_io { Hive::Commands::Workflow.rollback_scaffold(paths) }

        assert_includes err, "scaffold cleanup could not remove"
        assert_includes err, paths.fetch(:descriptor)
        assert_includes err, paths.fetch(:instruction_dir)
        assert_includes err, "Errno::EACCES",
                         "the cleanup warning must surface the underlying errno, not just the path"
      end

      # The stub blocked removal (remove_entry is restored now); tidy up.
      FileUtils.rm_f(paths.fetch(:descriptor))
      FileUtils.rm_rf(paths.fetch(:instruction_dir))
    end
  end

  def test_rollback_scaffold_swallows_epipe_from_the_cleanup_warning
    with_initialized_project do |project_root|
      scaffold = Hive::Commands::Workflow.scaffold_files!("epipe-flow", project_root: project_root)
      paths = scaffold.fetch(:paths)

      broken = Object.new
      broken.define_singleton_method(:write) { |*| raise Errno::EPIPE }
      broken.define_singleton_method(:puts) { |*| raise Errno::EPIPE }
      broken.define_singleton_method(:flush) { nil }

      with_replaced_singleton_method(FileUtils, :remove_entry, lambda { |path, *_args|
        raise Errno::EACCES, path.to_s
      }) do
        real_stderr = $stderr
        $stderr = broken
        begin
          # A broken-pipe stderr during the leftover warning must not crash the
          # rollback — warn_failed_scaffold_cleanup's `rescue Errno::EPIPE`
          # swallows it.
          result = Hive::Commands::Workflow.rollback_scaffold(paths)
          assert_nil result, "an EPIPE while warning must be swallowed, leaving rollback a no-op return"
        ensure
          $stderr = real_stderr
        end
      end

      FileUtils.rm_f(paths.fetch(:descriptor))
      FileUtils.rm_rf(paths.fetch(:instruction_dir))
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
