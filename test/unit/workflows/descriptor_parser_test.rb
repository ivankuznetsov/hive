require "test_helper"
require "securerandom"
require "hive/workflows/descriptor_parser"

class WorkflowsDescriptorParserTest < Minitest::Test
  include HiveTestHelper

  def test_valid_descriptor_maps_user_vocabulary_and_resolves_instruction
    with_tmp_dir do |dir|
      path = write_descriptor(dir, "my-flow", <<~YAML)
        id: my-flow
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./my-flow/work.md
            permissions:
              preset: scoped
              tools: [Read, Write]
              dirs: [../extra]
          - name: done
            kind: terminal
            state_file: done.md
            advance_verb: publish
      YAML
      FileUtils.mkdir_p(File.join(dir, "my-flow"))
      File.write(File.join(dir, "my-flow", "work.md"), "Do the work.\n")

      workflow = Hive::Workflows::DescriptorParser.parse_file(path)

      assert_equal :"my-flow", workflow.id
      assert_equal %w[1-inbox 2-work 3-done], workflow.stage_dirs
      assert_equal :inert, workflow.stage_named("inbox").kind

      work = workflow.stage_named("work")
      assert_equal :agent, work.kind
      assert_nil work.skill
      assert_equal File.join(dir, "my-flow", "work.md"), work.instruction
      assert_equal "work", work.advance_verb.name
      # Pin the round-tripped values, not just `.frozen?`: a stringify_hash /
      # deep_freeze regression that dropped `dirs:` or mangled `tools` would
      # still leave the (corrupted) hash frozen — `.frozen?` alone wouldn't
      # catch it on this security-relevant field.
      assert work.permissions.frozen?
      assert_equal "scoped", work.permissions.fetch("preset")
      assert_equal %w[Read Write], work.permissions.fetch("tools")
      assert_equal %w[../extra], work.permissions.fetch("dirs")
      assert work.permissions.fetch("tools").frozen?
      assert work.permissions.fetch("dirs").frozen?

      assert_equal "publish", workflow.stage_named("done").advance_verb.name
    end
  end

  def test_skill_backed_agent_stage_is_valid
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "skill-flow",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship" },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/skill-flow.yml"
    )

    assert_equal "/ship", workflow.stage_named("work").skill
  end

  def test_parse_file_wraps_yaml_errors_with_path
    with_tmp_dir do |dir|
      path = File.join(dir, "broken.yml")
      File.write(path, "id: [\n")

      error = assert_raises(Hive::ConfigError) { Hive::Workflows::DescriptorParser.parse_file(path) }

      assert_includes error.message, path
      assert_includes error.message, "not valid YAML"
    end
  end

  def test_parse_file_wraps_read_errors_with_path
    path = "/tmp/hive-missing-workflow-#{SecureRandom.hex(4)}.yml"

    error = assert_raises(Hive::ConfigError) { Hive::Workflows::DescriptorParser.parse_file(path) }

    assert_includes error.message, path
    assert_includes error.message, "not readable"
  end

  def test_descriptor_must_be_a_map
    error = assert_config_error(nil, path: "/tmp/blank.yml")

    assert_includes error.message, "descriptor must be a map"
  end

  def test_descriptor_rejects_non_string_keys
    error = assert_config_error({ 1 => "bad" }, path: "/tmp/bad.yml")

    assert_includes error.message, "descriptor contains non-string key 1"
  end

  def test_descriptor_rejects_unknown_top_level_keys
    error = assert_config_error({ "id" => "bad", "stages" => [], "extra" => true }, path: "/tmp/bad.yml")

    assert_includes error.message, 'descriptor contains unknown key(s) ["extra"]'
  end

  def test_id_must_be_a_safe_slug
    error = assert_config_error({ "id" => "Bad_Flow", "stages" => [] }, path: "/tmp/Bad_Flow.yml")

    assert_includes error.message, 'id "Bad_Flow" must match'
  end

  def test_id_must_match_filename
    error = assert_config_error({ "id" => "actual", "stages" => [] }, path: "/tmp/expected.yml")

    assert_includes error.message, 'id "actual" must match filename "expected"'
  end

  def test_stages_must_be_an_array
    error = assert_config_error({ "id" => "bad", "stages" => "nope" }, path: "/tmp/bad.yml")

    assert_includes error.message, "stages must be an array"
  end

  def test_stage_must_be_a_map
    error = assert_config_error({ "id" => "bad", "stages" => [ "nope" ] }, path: "/tmp/bad.yml")

    assert_includes error.message, "stage 1 must be a map"
  end

  def test_stage_rejects_non_string_keys
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md", 1 => "bad" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "stage 1 contains non-string key 1"
  end

  def test_stage_rejects_unknown_keys
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md", "unknown" => true }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, 'stage 1 contains unknown key(s) ["unknown"]'
  end

  def test_stage_name_must_be_a_safe_slug
    error = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "Work_Now", "kind" => "terminal", "state_file" => "x.md" } ] },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, 'stage 1 name "Work_Now" must match'
  end

  def test_required_stage_fields_must_be_present
    error = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "inbox", "kind" => "terminal" } ] },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "stage 1 state_file must be a non-empty string"
  end

  # state_file is joined onto task.folder at run time and flows into
  # Markers.set → mkdir_p/write_atomic. It must be a BARE BASENAME: an
  # absolute path or a `..` segment escapes the task tree, and even a benign
  # subdirectory (`sub/idea.md`) is unwritable — `hive new` only mkdir_p's the
  # task folder, so a nested path raises Errno::ENOENT and a descriptor that
  # passed validation could never capture its first task.
  def test_state_file_rejects_path_traversal
    %w[../escape.md ../../etc/passwd nested/../../escape.md].each do |bad|
      error = assert_config_error(
        { "id" => "bad", "stages" => [ { "name" => "inbox", "kind" => "terminal", "state_file" => bad } ] },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, "must be a bare filename inside the task folder", "#{bad} must be rejected"
    end
  end

  def test_state_file_rejects_absolute_path
    error = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "inbox", "kind" => "terminal", "state_file" => "/etc/passwd" } ] },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "must be a bare filename inside the task folder"
  end

  # A nested-but-non-escaping path (`sub/idea.md`) must ALSO be rejected: it
  # passes the old leading-'/' + '..' guard but is unwritable because `hive new`
  # only creates the task folder, not its subdirectories — so the write raises
  # Errno::ENOENT after validation already accepted the descriptor.
  def test_state_file_rejects_nested_subdirectory
    [ "sub/idea.md", ".", ".." ].each do |bad|
      error = assert_config_error(
        { "id" => "bad", "stages" => [ { "name" => "inbox", "kind" => "terminal", "state_file" => bad } ] },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, "must be a bare filename inside the task folder", "#{bad} must be rejected"
    end
  end

  def test_council_kind_is_reserved
    error = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "review", "kind" => "council", "state_file" => "review.md" } ] },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "kind 'council' is not yet supported"
  end

  def test_unknown_kind_is_rejected
    error = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "work", "kind" => "marker", "state_file" => "work.md" } ] },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, 'stage 1 kind "marker" must be agent or terminal'

    # The coding runtime kinds (execute/review_council/finalize) are Ruby-only:
    # only Workflows::Coding declares them via Stage.new, and parse_kind must keep
    # rejecting them from YAML descriptors. That rejection is load-bearing — it is
    # exactly what lets task_action.rb's kind_action route those kinds straight to
    # the coding-hardcoded helpers with NO coding_id? guard (see its safety
    # comment). Pin the three exact strings so a future `when "execute"` clause in
    # parse_kind can't silently widen the YAML kind space and break that invariant.
    %w[execute review_council finalize].each do |coding_runtime_kind|
      runtime_error = assert_config_error(
        { "id" => "bad",
          "stages" => [ { "name" => "work", "kind" => coding_runtime_kind, "state_file" => "work.md" } ] },
        path: "/tmp/bad.yml"
      )

      assert_includes runtime_error.message, %(stage 1 kind "#{coding_runtime_kind}" must be agent or terminal),
                      "YAML descriptors must not be able to declare Ruby-only coding runtime kind " \
                      "#{coding_runtime_kind.inspect}"
    end
  end

  def test_agent_stage_requires_exactly_one_skill_or_instruction
    neither = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "work", "kind" => "agent", "state_file" => "work.md" } ] },
      path: "/tmp/bad.yml"
    )
    assert_includes neither.message, "agent stages must declare exactly one"

    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bad"))
      File.write(File.join(dir, "bad", "work.md"), "x\n")
      both = assert_raises(Hive::ConfigError) do
        Hive::Workflows::DescriptorParser.parse_file(
          write_descriptor(dir, "bad", <<~YAML)
            id: bad
            stages:
              - name: work
                kind: agent
                state_file: work.md
                skill: /ship
                instruction: ./bad/work.md
          YAML
        )
      end
      assert_includes both.message, "agent stages must declare exactly one"
    end
  end

  def test_instruction_must_reference_readable_file
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "instruction" => "./missing.md" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, 'instruction "./missing.md" must reference a readable file'
  end

  def test_permissions_are_validated_fail_closed
    blank = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship", "permissions" => nil }
        ]
      },
      path: "/tmp/bad.yml"
    )
    assert_includes blank.message, "permissions"
    assert_includes blank.message, "blank"

    unknown = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          {
            "name" => "work",
            "kind" => "agent",
            "state_file" => "work.md",
            "skill" => "/ship",
            "permissions" => "reckless"
          }
        ]
      },
      path: "/tmp/bad.yml"
    )
    assert_includes unknown.message, 'unknown preset "reckless"'
  end

  # The parser's fail-fast promise extends to `dirs:` resolution: a scoped
  # permission whose `dirs:` can never resolve (an unknown `~user`) must surface
  # at LOAD time, not blow up into an attributed :error marker on every run.
  def test_permissions_with_unresolvable_dirs_rejected_at_parse_time
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
          {
            "name" => "work",
            "kind" => "agent",
            "state_file" => "work.md",
            "skill" => "/ship",
            "permissions" => { "preset" => "scoped", "tools" => %w[Read], "dirs" => [ "~hive_no_such_user_42/x" ] }
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "could not be resolved"
  end

  def test_optional_strings_must_be_non_empty_when_present
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => " " }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "stage 1 skill must be a non-empty string"
  end

  def test_nil_advance_verb_is_allowed_for_bare_mv_stage
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "bare-mv",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
          {
            "name" => "work",
            "kind" => "agent",
            "state_file" => "work.md",
            "skill" => "/ship",
            "advance_verb" => nil
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/bare-mv.yml"
    )

    assert_nil workflow.stage_named("work").advance_verb
  end

  def test_last_stage_must_be_terminal
    error = assert_config_error(
      {
        "id" => "no-terminal",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship" }
        ]
      },
      path: "/tmp/no-terminal.yml"
    )

    assert_includes error.message, "last stage \"work\" must be a terminal stage"
    assert_includes error.message, "undroppable"
  end

  def test_terminal_stage_rejects_agent_only_fields
    %w[skill instruction permissions].each do |field|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md", field => "x" }
          ]
        },
        path: "/tmp/bad.yml"
      )

      assert_includes error.message, field, "#{field} on a terminal stage must be rejected"
      assert_includes error.message, "only valid on an agent stage"
    end
  end

  def test_workflow_structure_errors_are_wrapped_with_path
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "work", "kind" => "terminal", "state_file" => "a.md" },
          { "name" => "work", "kind" => "terminal", "state_file" => "b.md" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "/tmp/bad.yml"
    assert_includes error.message, "duplicate stage names"
  end

  private

    def assert_config_error(data, path:)
      assert_raises(Hive::ConfigError) do
        Hive::Workflows::DescriptorParser.parse_hash(data, path: path)
      end
    end

    def write_descriptor(dir, id, body)
      path = File.join(dir, "#{id}.yml")
      File.write(path, body)
      path
    end
end
