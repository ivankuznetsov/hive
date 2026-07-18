require "test_helper"
require "securerandom"
require "hive/workflows/descriptor_parser"

class WorkflowsDescriptorParserTest < Minitest::Test
  def test_package_descriptor_binds_workflow_yml_to_expected_package_name
    with_tmp_dir do |dir|
      path = File.join(dir, "workflow.yml")
      File.write(path, <<~YAML)
        id: packaged
        stages:
          - name: done
            kind: terminal
            state_file: done.md
      YAML

      workflow = Hive::Workflows::DescriptorParser.parse_package_file(path, package_name: "packaged")
      assert_equal :packaged, workflow.id

      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::DescriptorParser.parse_package_file(path, package_name: "other")
      end
      assert_includes error.message, "package name"
    end
  end

  def test_package_descriptor_rejects_instruction_escape
    with_tmp_dir do |dir|
      package = File.join(dir, "package")
      FileUtils.mkdir_p(package)
      File.write(File.join(dir, "outside.md"), "outside")
      path = File.join(package, "workflow.yml")
      File.write(path, <<~YAML)
        id: packaged
        stages:
          - name: work
            kind: agent
            state_file: work.md
            instruction: ../outside.md
      YAML

      assert_raises(Hive::ConfigError) do
        Hive::Workflows::DescriptorParser.parse_package_file(path, package_name: "packaged")
      end
    end
  end
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

  def test_dependency_gate_must_resolve_inside_the_descriptor
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "gated-flow",
        "dependency_gate_stage" => "2-release",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/work" },
          { "name" => "release", "kind" => "terminal", "state_file" => "release.md" }
        ]
      },
      path: "/tmp/gated-flow.yml"
    )
    assert_equal "2-release", workflow.dependency_gate_stage

    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::DescriptorParser.parse_hash(
        {
          "id" => "gated-flow",
          "dependency_gate_stage" => "3-missing",
          "stages" => [
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
          ]
        },
        path: "/tmp/gated-flow.yml"
      )
    end
    assert_match(/dependency_gate_stage/, error.message)
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

  def test_stage_conditions_select_registered_semantics_only
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "condition-flow",
        "stages" => [
          {
            "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship",
            "conditions" => {
              "version" => 1,
              "transition" => "work_complete",
              "required" => [ "ChangesPresent" ],
              "inhibitors" => [ "AwaitingHuman" ],
              "options" => { "no_commit_success" => true }
            }
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/condition-flow.yml"
    )
    rule = workflow.stage_named("work").condition_policy
    assert_equal "work_complete", rule.transition
    assert rule.options.fetch("no_commit_success")

    error = assert_raises(Hive::ConfigError) do
      Hive::Workflows::DescriptorParser.parse_hash(
        {
          "id" => "bad-conditions",
          "stages" => [
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md",
              "conditions" => { "transition" => "done", "required" => [ "MadeUp" ] } }
          ]
        },
        path: "/tmp/bad-conditions.yml"
      )
    end
    assert_includes error.message, "unknown condition"
  end

  def test_agent_stage_accepts_per_stage_agent_model_and_effort
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "agent-choice",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
          {
            "name" => "work",
            "kind" => "agent",
            "state_file" => "work.md",
            "skill" => "/ship",
            "agent" => "codex",
            "model" => "opus",
            "effort" => "high"
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/agent-choice.yml"
    )

    work = workflow.stage_named("work")
    assert_equal "codex", work.agent
    assert_equal "opus", work.model
    assert_equal "high", work.effort
  end

  def test_active_stages_accept_per_stage_budget_and_timeout
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "resource-limits",
        "stages" => [
          {
            "name" => "work",
            "kind" => "agent",
            "state_file" => "work.md",
            "skill" => "/ship",
            "budget_usd" => 12.5,
            "timeout_sec" => 7200
          },
          {
            "name" => "review",
            "kind" => "council",
            "state_file" => "review.md",
            "budget_usd" => 25,
            "timeout_sec" => 3600,
            "reviewers" => [ { "name" => "one", "prompt" => "Review." } ]
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/resource-limits.yml"
    )

    work = workflow.stage_named("work")
    assert_equal 12.5, work.budget_usd
    assert_equal 7200, work.timeout_sec

    review = workflow.stage_named("review")
    assert_equal 25, review.budget_usd
    assert_equal 3600, review.timeout_sec
  end

  def test_per_stage_budget_and_timeout_default_to_nil
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "resource-defaults",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship" },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/resource-defaults.yml"
    )

    work = workflow.stage_named("work")
    assert_nil work.budget_usd
    assert_nil work.timeout_sec
  end

  def test_per_stage_budget_and_timeout_must_be_positive
    {
      "budget_usd" => [ 0, -1, "12" ],
      "timeout_sec" => [ 0, -1, 1.5, "7200" ]
    }.each do |field, invalid_values|
      invalid_values.each do |value|
        error = assert_config_error(
          {
            "id" => "bad",
            "stages" => [
              { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship",
                field => value }
            ]
          },
          path: "/tmp/bad.yml"
        )

        assert_includes error.message, "stage 1 #{field} must be a positive"
      end
    end
  end

  def test_yaml_infinite_budget_is_rejected
    with_tmp_dir do |dir|
      path = write_descriptor(dir, "infinite-budget", <<~YAML)
        id: infinite-budget
        stages:
          - name: work
            kind: agent
            state_file: work.md
            skill: /ship
            budget_usd: .inf
      YAML

      error = assert_raises(Hive::ConfigError) do
        Hive::Workflows::DescriptorParser.parse_file(path)
      end

      assert_includes error.message, "stage 1 budget_usd must be a positive finite number"
    end
  end

  def test_terminal_stage_rejects_budget_and_timeout
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md",
            "budget_usd" => 10, "timeout_sec" => 60 }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, '["budget_usd", "timeout_sec"] are only valid on an agent stage'
  end

  def test_agent_stage_defaults_per_stage_agent_model_and_effort_to_nil
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "agent-defaults",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship" },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/agent-defaults.yml"
    )

    work = workflow.stage_named("work")
    assert_nil work.agent
    assert_nil work.model
    assert_nil work.effort
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

  def test_council_stage_parses_reviewers_and_config
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "doc-review",
        "stages" => [
          { "name" => "draft", "kind" => "agent", "state_file" => "draft.md", "skill" => "/draft" },
          {
            "name" => "review",
            "kind" => "council",
            "state_file" => "review.md",
            "input" => "draft.md",
            "agent" => "claude",
            "model" => "opus",
            "effort" => "high",
            "reviewers" => [
              { "name" => "fable-doc", "agent" => "codex", "skill" => "/doc-review", "output_basename" => "fable" },
              { "name" => "codex-doc", "prompt" => "Review the document." }
            ],
            "council" => {
              "quorum" => 2,
              "max_rounds" => 3,
              "exit_rule" => "consensus",
              "triage_output" => "reviews/triage.md",
              "revise" => { "agent" => "claude", "skill" => "/revise" }
            }
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/doc-review.yml"
    )

    review = workflow.stage_named("review")
    assert_equal :council, review.kind
    assert_equal "draft.md", review.input
    assert_equal "claude", review.agent
    assert_equal "opus", review.model
    assert_equal "high", review.effort
    assert_equal 2, review.reviewers.length
    assert_equal "fable-doc", review.reviewers.first.name
    assert_equal "codex", review.reviewers.first.agent
    assert_equal "/doc-review", review.reviewers.first.skill
    assert_equal "fable", review.reviewers.first.output_basename
    assert_equal "Review the document.", review.reviewers.last.prompt
    assert_equal 2, review.council.quorum
    assert_equal 3, review.council.max_rounds
    assert_equal :consensus, review.council.exit_rule
    assert_equal "reviews/triage.md", review.council.triage_output
    assert_equal "/revise", review.council.revise.skill
  end

  def test_council_defaults_input_to_nil_and_config_to_reviewer_count
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "doc-review",
        "stages" => [
          { "name" => "draft", "kind" => "agent", "state_file" => "draft.md", "skill" => "/draft" },
          {
            "name" => "review",
            "kind" => "council",
            "state_file" => "review.md",
            "reviewers" => [
              { "name" => "one", "prompt" => "Review." }
            ]
          },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/doc-review.yml"
    )

    review = workflow.stage_named("review")
    assert_nil review.input
    assert_equal 1, review.council.quorum
    assert_equal 1, review.council.max_rounds
    assert_equal :human, review.council.exit_rule
    assert_equal "reviews/triage.md", review.council.triage_output
    assert_nil review.council.revise
  end

  def test_nonterminal_deliverable_is_rejected
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "draft", "kind" => "agent", "state_file" => "draft.md", "skill" => "/draft",
            "deliverable" => "draft.md" },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "deliverable is only consumed on the last stage"
  end

  def test_parser_terminal_last_stage_validation_reports_internal_kind_drift
    parser = Hive::Workflows::DescriptorParser.new("/tmp/bad.yml")
    stage = Hive::Workflow::Stage.new(name: "execute", index: 1, state_file: "x.md", kind: :execute)

    error = assert_raises(Hive::ConfigError) do
      parser.send(:validate_terminal_last_stage!, [ stage ])
    end

    assert_includes error.message, 'last stage "execute" must be terminal, agent, or council'
  end

  def test_council_stage_requires_reviewers
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "review", "kind" => "council", "state_file" => "review.md" },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, "council stage must declare reviewers"
  end

  def test_council_rejects_duplicate_reviewer_names_and_sanitized_outputs
    [
      [
        [
          { "name" => "same", "prompt" => "Review." },
          { "name" => "same", "prompt" => "Review." }
        ],
        'duplicate reviewer names: ["same"]'
      ],
      [
        [
          { "name" => "one", "prompt" => "Review.", "output_basename" => "a b" },
          { "name" => "two", "prompt" => "Review.", "output_basename" => "a/b" }
        ],
        'duplicate reviewer output_basenames: ["a-b"]'
      ]
    ].each do |reviewers, message|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            { "name" => "review", "kind" => "council", "state_file" => "review.md", "reviewers" => reviewers },
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
          ]
        },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, message
    end
  end

  def test_council_stage_rejects_invalid_quorum_exit_rule_and_rounds
    [
      [ { "quorum" => 2 }, "quorum 2 cannot exceed reviewer count 1" ],
      [ { "max_rounds" => 0 }, "max_rounds must be a positive integer" ],
      [ { "exit_rule" => "whatever" }, 'exit_rule "whatever" must be one of' ]
    ].each do |council, message|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            {
              "name" => "review",
              "kind" => "council",
              "state_file" => "review.md",
              "reviewers" => [ { "name" => "one", "prompt" => "Review." } ],
              "council" => council
            },
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
          ]
        },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, message
    end
  end

  def test_council_reviewer_requires_exactly_one_instruction_source
    [
      [ {}, "must declare exactly one of" ],
      [ { "skill" => "/review", "prompt" => "Review." }, "must declare exactly one of" ]
    ].each do |extra, message|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            {
              "name" => "review",
              "kind" => "council",
              "state_file" => "review.md",
              "reviewers" => [ { "name" => "one" }.merge(extra) ]
            },
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
          ]
        },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, message
    end
  end

  def test_council_revise_requires_exactly_one_instruction_source
    [
      [ {}, "must declare exactly one of" ],
      [ { "skill" => "/revise", "prompt" => "Revise." }, "must declare exactly one of" ]
    ].each do |revise, message|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            {
              "name" => "review",
              "kind" => "council",
              "state_file" => "review.md",
              "reviewers" => [ { "name" => "one", "prompt" => "Review." } ],
              "council" => { "revise" => revise }
            },
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
          ]
        },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, message
    end
  end

  def test_council_revise_noop_combinations_warn
    [
      [ { "revise" => { "skill" => "/revise" } }, /max_rounds: 1/ ],
      [ { "max_rounds" => 2, "exit_rule" => "human", "revise" => { "skill" => "/revise" } }, /exit_rule: human/ ]
    ].each do |council, warning|
      _out, err = capture_io do
        Hive::Workflows::DescriptorParser.parse_hash(
          {
            "id" => "warn",
            "stages" => [
              { "name" => "review", "kind" => "council", "state_file" => "review.md",
                "reviewers" => [ { "name" => "one", "prompt" => "Review." } ],
                "council" => council },
              { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
            ]
          },
          path: "/tmp/warn.yml"
        )
      end
      assert_match warning, err
    end
  end

  def test_council_triage_output_stays_inside_stage_folder
    [ "/tmp/triage.md", "../triage.md", "reviews/../triage.md" ].each do |triage_output|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            { "name" => "review", "kind" => "council", "state_file" => "review.md",
              "reviewers" => [ { "name" => "one", "prompt" => "Review." } ],
              "council" => { "triage_output" => triage_output } },
            { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
          ]
        },
        path: "/tmp/bad.yml"
      )
      assert_includes error.message, "must stay inside the stage folder"
    end
  end

  def test_unknown_kind_is_rejected
    error = assert_config_error(
      { "id" => "bad", "stages" => [ { "name" => "work", "kind" => "marker", "state_file" => "work.md" } ] },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, 'stage 1 kind "marker" must be agent, council, or terminal'

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

      assert_includes runtime_error.message, %(stage 1 kind "#{coding_runtime_kind}" must be agent, council, or terminal),
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

  def test_kind_specific_fields_are_rejected
    agent_error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship",
            "reviewers" => [ { "name" => "one", "prompt" => "Review." } ] }
        ]
      },
      path: "/tmp/bad.yml"
    )
    assert_includes agent_error.message, '["reviewers"] is only valid on a council stage'

    council_error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "review", "kind" => "council", "state_file" => "review.md",
            "skill" => "/ship", "reviewers" => [ { "name" => "one", "prompt" => "Review." } ] }
        ]
      },
      path: "/tmp/bad.yml"
    )
    assert_includes council_error.message, '["skill"] is only valid on a agent stage'
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

  def test_per_stage_model_and_effort_must_be_non_empty_when_present
    %w[model effort].each do |field|
      error = assert_config_error(
        {
          "id" => "bad",
          "stages" => [
            { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship", field => " " }
          ]
        },
        path: "/tmp/bad.yml"
      )

      assert_includes error.message, "stage 1 #{field} must be a non-empty string"
    end
  end

  def test_unknown_per_stage_agent_is_rejected_with_registered_names
    error = assert_config_error(
      {
        "id" => "bad",
        "stages" => [
          { "name" => "work", "kind" => "agent", "state_file" => "work.md", "skill" => "/ship", "agent" => "nonesuch" },
          { "name" => "done", "kind" => "terminal", "state_file" => "done.md" }
        ]
      },
      path: "/tmp/bad.yml"
    )

    assert_includes error.message, 'agent "nonesuch" is not registered'
    assert_includes error.message, "registered:"
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

  def test_last_stage_may_be_agent_with_deliverable
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "agent-terminal",
        "stages" => [
          { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
          {
            "name" => "work",
            "kind" => "agent",
            "state_file" => "work.md",
            "skill" => "/ship",
            "deliverable" => "architecture.md"
          }
        ]
      },
      path: "/tmp/agent-terminal.yml"
    )

    assert_equal :agent, workflow.stage_named("work").kind
    assert_equal "architecture.md", workflow.stage_named("work").deliverable
  end

  def test_last_stage_may_be_council
    workflow = Hive::Workflows::DescriptorParser.parse_hash(
      {
        "id" => "council-terminal",
        "stages" => [
          { "name" => "draft", "kind" => "agent", "state_file" => "draft.md", "skill" => "/draft" },
          {
            "name" => "review",
            "kind" => "council",
            "state_file" => "review.md",
            "reviewers" => [ { "name" => "one", "prompt" => "Review." } ],
            "council" => { "quorum" => 1 }
          }
        ]
      },
      path: "/tmp/council-terminal.yml"
    )

    assert_equal :council, workflow.stage_named("review").kind
  end

  def test_terminal_stage_rejects_agent_only_fields
    %w[skill instruction agent model effort permissions].each do |field|
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
