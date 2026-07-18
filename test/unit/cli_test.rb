require "test_helper"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/forget"
require "hive/commands/prune"
require "hive/commands/doctor"
require "hive/commands/update"
require "hive/commands/connect"
require "hive/commands/disconnect"
require "hive/commands/uninstall"
require "hive/commands/migrate"
require "hive/commands/new"
require "hive/commands/workflow"
require "hive/commands/generate_name"
require "hive/commands/run"
require "hive/commands/rebase_status"
require "hive/commands/stage_action"
require "hive/commands/adhoc_review"
require "hive/commands/status"
require "hive/commands/approve"
require "hive/commands/findings"
require "hive/commands/finding_toggle"
require "hive/commands/patrol"
require "hive/commands/refactor_patrol"
require "hive/commands/digest"
require "hive/commands/pairing"
require "hive/commands/answer_digest"
require "hive/commands/markers"
require "hive/commands/daemon"
require "hive/commands/bot"
require "hive/commands/metrics"
require "hive/commands/setup"
require "hive/commands/setup_agents"

class HiveCliTest < Minitest::Test
  include HiveTestHelper

  def test_setup_agents_help_exposes_consent_json_and_filters
    out, _err = capture_io { Hive::CLI.start([ "help", "setup-agents" ]) }

    assert_includes out, "--yes"
    assert_includes out, "--json"
    assert_includes out, "--agent"
    assert_includes out, "--skill"
  end

  def test_doctor_help_advertises_v2_read_only_health_contract
    out, _err = capture_io { Hive::CLI.start([ "help", "doctor" ]) }

    assert_includes out, "hive-doctor.v2"
    assert_includes out, "setup-agents"
    assert_includes out, "never installs"
  end

  CommandDouble = Struct.new(:return_value, :calls) do
    def call
      calls << :call
      return_value
    end

    # `hive review --pr` drives AdhocReview through #enqueue (not #call) so it
    # can return the resolved {slug:, project:} the CLI forwards to StageAction.
    def enqueue
      calls << :enqueue
      return_value
    end
  end


  def with_command_new_stub(klass, return_value: true)
    calls = []
    double = CommandDouble.new(return_value, calls)
    with_replaced_singleton_method(klass, :new, lambda { |*args, **kwargs|
      calls << { args: args, kwargs: kwargs }
      double
    }) do
      yield calls
    end
  end

  def test_exit_on_failure_and_version_output
    assert_equal true, Hive::CLI.exit_on_failure?

    out, _err = capture_io { Hive::CLI.start([ "version" ]) }
    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_init_forget_prune_update_uninstall_and_migrate_pass_options
    with_command_new_stub(Hive::Commands::Init) do |calls|
      Hive::CLI.start([ "init", "/tmp/project", "--force", "--json", "--workflow", "content_fixture" ])
      assert_equal [ "/tmp/project" ], calls.first.fetch(:args)
      assert_equal({
                     force: true, json: true, workflow: "content_fixture",
                     new_workflow: nil, refactor_patrol: nil
                   },
                   calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end

    with_command_new_stub(Hive::Commands::Init) do |calls|
      Hive::CLI.start([ "init", "/tmp/project", "--new-workflow", "writing" ])
      assert_equal [ "/tmp/project" ], calls.first.fetch(:args)
      assert_equal({
                     force: false, json: false, workflow: nil,
                     new_workflow: "writing", refactor_patrol: nil
                   },
                   calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end

    with_command_new_stub(Hive::Commands::Init) do |calls|
      Hive::CLI.start([ "init", "/tmp/project", "--no-refactor-patrol" ])
      assert_equal false, calls.first.fetch(:kwargs).fetch(:refactor_patrol)
      assert_equal :call, calls.last
    end

    with_command_new_stub(Hive::Commands::Forget) do |calls|
      Hive::CLI.start([ "forget", "demo", "--json" ])
      Hive::CLI.start([ "forget", "demo", "--json", "--if-exists" ])

      constructor_calls = calls.grep(Hash)
      assert_equal [ "demo" ], constructor_calls.first.fetch(:args)
      assert_equal({ json: true, if_exists: false }, constructor_calls.first.fetch(:kwargs))
      assert_equal [ "demo" ], constructor_calls.last.fetch(:args)
      assert_equal({ json: true, if_exists: true }, constructor_calls.last.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Prune) do |calls|
      Hive::CLI.start([ "prune", "--dry-run", "--json" ])
      assert_equal({ dry_run: true, json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Update) do |calls|
      Hive::CLI.start([ "update", "--dry-run" ])
      assert_equal({ dry_run: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Connect) do |calls|
      Hive::CLI.start([ "connect", "screenote", "--base-url", "https://screenote.test", "--json" ])
      assert_equal [ "screenote" ], calls.first.fetch(:args)
      assert_equal({ base_url: "https://screenote.test", json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Disconnect) do |calls|
      Hive::CLI.start([ "disconnect", "screenote", "--json" ])
      assert_equal [ "screenote" ], calls.first.fetch(:args)
      assert_equal({ json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Uninstall) do |calls|
      Hive::CLI.start([ "uninstall", "--purge", "--force-purge-state" ])
      assert_equal({ purge: true, force_purge_state: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Migrate) do |calls|
      Hive::CLI.start([ "migrate", "/tmp/project" ])
      assert_equal [ "/tmp/project" ], calls.first.fetch(:args)
    end
  end

  def test_doctor_loads_project_config_and_exits_with_command_status
    loaded = []
    with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
      loaded << path
      { "ok" => true }
    }) do
      with_command_new_stub(Hive::Commands::Doctor, return_value: 65) do |calls|
        _out, _err, status = with_captured_exit { Hive::CLI.start([ "doctor", "--json" ]) }

        assert_equal 65, status
        assert_equal [ Dir.pwd ], loaded
        assert_equal({ config: { "ok" => true }, project_root: Dir.pwd, json: true }, calls.first.fetch(:kwargs))
      end
    end
  end

  def test_setup_agents_loads_project_config_forwards_filters_and_exits
    loaded = []
    with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
      loaded << path
      { "ok" => true }
    }) do
      with_command_new_stub(Hive::Commands::SetupAgents, return_value: 1) do |calls|
        _out, _err, status = with_captured_exit do
          Hive::CLI.start([
            "setup-agents", "--yes", "--json",
            "--agent", "claude", "codex", "--skill", "ce-brainstorm"
          ])
        end

        assert_equal 1, status
        assert_equal [ Dir.pwd ], loaded
        assert_equal(
          {
            config: { "ok" => true }, project_root: Dir.pwd,
            yes: true, json: true, agents: %w[claude codex], skills: [ "ce-brainstorm" ]
          },
          calls.first.fetch(:kwargs)
        )
      end
    end
  end

  def test_setup_wires_options_and_exits_with_command_status
    with_command_new_stub(Hive::Commands::Setup, return_value: 3) do |calls|
      _out, _err, status = with_captured_exit do
        Hive::CLI.start([ "setup", "--json", "--service", "--no-bootstrap", "--no-init" ])
      end

      assert_equal 3, status, "the CLI must exit with the Setup command's return value"
      assert_equal(
        { json: true, service: true, no_bootstrap: true, no_init: true },
        calls.first.fetch(:kwargs),
        "every setup flag must be forwarded to Hive::Commands::Setup.new"
      )
      assert_includes calls, :call, "the setup command must actually be invoked"
    end
  end

  def test_setup_defaults_when_no_flags_given
    with_command_new_stub(Hive::Commands::Setup, return_value: 0) do |calls|
      _out, _err, status = with_captured_exit { Hive::CLI.start([ "setup" ]) }

      assert_equal 0, status
      assert_equal(
        { json: false, service: false, no_bootstrap: false, no_init: false },
        calls.first.fetch(:kwargs),
        "with no flags the CLI must pass the documented defaults"
      )
    end
  end

  def test_new_task_dispatches_joined_text_and_rejects_blank_text
    with_command_new_stub(Hive::Commands::New) do |calls|
      Hive::CLI.start([ "new", "proj", "build", "thing" ])
      assert_equal [ "proj", "build thing" ], calls.first.fetch(:args)
      assert_equal({ depends_on: nil, workflow: nil }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::New) do |calls|
      Hive::CLI.start([ "new", "proj", "--depends-on", "base-task", "--workflow", "content_fixture", "build", "thing" ])
      assert_equal [ "proj", "build thing" ], calls.first.fetch(:args)
      assert_equal({ depends_on: "base-task", workflow: "content_fixture" }, calls.first.fetch(:kwargs))
    end

    _out, err, status = with_captured_exit { Hive::CLI.start([ "new", "proj" ]) }
    assert_equal Hive::ExitCodes::GENERIC, status
    assert_match(/missing task text/, err)
  end

  def test_workflow_option_help_advertises_project_authored_workflows
    new_out, _new_err = capture_io { Hive::CLI.start([ "help", "new" ]) }
    init_out, _init_err = capture_io { Hive::CLI.start([ "help", "init" ]) }

    [ new_out, init_out ].each do |out|
      assert_match(/or any project-authored workflow/, out,
                   "--workflow help must say project-authored workflows are valid")
      assert_match(/hive workflow new/, out,
                   "--workflow help must point at the authoring command")
      assert_includes out, Hive::CLI::WORKFLOW_VOCABULARY,
                      "--workflow help must advertise the built-in workflows (#{Hive::CLI::WORKFLOW_VOCABULARY})"
    end
  end

  def test_init_help_advertises_the_current_schema_registry_version
    out, _err = capture_io { Hive::CLI.start([ "help", "init" ]) }
    current = Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-init")

    assert_includes out, "hive-init.v#{current}",
                    "init help must derive its JSON contract version from SCHEMA_VERSIONS"
  end

  def test_digest_help_exposes_merged_pr_source
    out, _err = capture_io { Hive::CLI.start([ "help", "digest" ]) }

    assert_includes out, "--source"
    assert_includes out, "merged-prs"
    assert_includes out, "--repo"
    assert_includes out, "never mutates Hive state"
  end

  def test_workflow_option_help_does_not_enumerate_project_workflows
    # Plan-central contract: `--workflow` help lists built-ins only and never
    # enumerates active-project descriptors, so the rendered string stays static
    # regardless of which project is registered (WORKFLOW_VOCABULARY is frozen to
    # built-ins at class load). Register a fixture into the runtime overlay and
    # assert its id never leaks into `help new`.
    with_registered_workflow(content_workflow) do
      # Direct helper-level guard: assert the contract at its source, not only
      # after Thor renders the option desc. A future rewrite of
      # `workflow_option_desc` to dynamically enumerate `Registry.ids` would
      # leave the frozen, class-load option desc unchanged, so the rendered
      # check below would stay green while the helper silently became
      # project-dependent. Calling the helper inside the runtime overlay catches
      # that regression directly. (A deliberate dynamic upgrade would update
      # this assertion on purpose.)
      refute_includes Hive::CLI.workflow_option_desc, content_workflow.id.to_s,
                      "workflow_option_desc must stay built-ins-only, independent of the registered project workflow"

      new_out, _new_err = capture_io { Hive::CLI.start([ "help", "new" ]) }
      refute_includes new_out, content_workflow.id.to_s,
                      "--workflow help must list built-ins only, never active-project workflows"
    end
  end

  def test_workflow_option_desc_is_symmetric_and_dry
    desc = Hive::CLI.workflow_option_desc
    # Anchor on the frozen constant the helper actually interpolates, not a live
    # Registry.ids recomputation: WORKFLOW_VOCABULARY is built-ins-only at class
    # load, so a sibling test that registers a project/runtime workflow (even
    # under Minitest's randomized order) can't make this diverge and flake.
    built_ins = Hive::CLI::WORKFLOW_VOCABULARY

    assert_includes desc, built_ins
    assert_includes desc, "or any project-authored workflow"
    assert_includes desc, "hive workflow new ID"

    new_out, _new_err = capture_io { Hive::CLI.start([ "help", "new" ]) }
    init_out, _init_err = capture_io { Hive::CLI.start([ "help", "init" ]) }
    assert_includes new_out, desc
    assert_includes init_out, desc

    cli_source = File.read(File.expand_path("../../lib/hive/cli.rb", __dir__))
    # Match the bare built-in names regardless of a leading prefix: the prior
    # `/["']coding, content/` only caught a quote-hugging literal, so it would
    # have missed the most-likely regression — the pre-PR prefixed form
    # `"valid: coding, content"`. The names never appear verbatim in cli.rb;
    # they must come from the registry.
    refute_match(/coding, content/, cli_source,
                 "built-in workflow names must come from the registry")
  end

  def test_workflow_new_dispatches_to_command_with_json
    with_command_new_stub(Hive::Commands::Workflow) do |calls|
      Hive::CLI.start([ "workflow", "new", "my-flow", "--json" ])

      assert_equal [ "new", "my-flow" ], calls.first.fetch(:args)
      assert_equal(
        { project_root: Dir.pwd, json: true, template: nil, yes: false, dry_run: false,
          allow_escalation: false, version: nil },
        calls.first.fetch(:kwargs)
      )
      assert_equal :call, calls.last
    end
  end

  def test_generate_name_passes_lookup_options
    with_command_new_stub(Hive::Commands::GenerateName) do |calls|
      Hive::CLI.start([ "generate-name", "slug", "--project", "proj", "--stage", "inbox" ])

      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ project: "proj", stage: "inbox" }, calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end
  end

  def test_run_and_rebase_status_pass_lookup_options
    with_command_new_stub(Hive::Commands::Run) do |calls|
      Hive::CLI.start([ "run", "slug", "--project", "proj", "--stage", "plan", "--json", "--no-rebase" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ project: "proj", stage: "plan", json: true, no_rebase: true, durable: true },
                   calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::RebaseStatus) do |calls|
      Hive::CLI.start([ "rebase-status", "slug", "--project", "proj", "--stage", "execute", "--json" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ project: "proj", stage: "execute", json: true }, calls.first.fetch(:kwargs))
    end
  end

  def test_workflow_verbs_dispatch_stage_action_with_options
    expected = {
      "brainstorm" => "brainstorm",
      "plan" => "plan",
      "develop" => "develop",
      "open-pr" => "open-pr",
      "pr" => "open-pr",
      "review" => "review",
      "artifacts" => "artifacts",
      "finalize" => "finalize",
      "archive" => "archive"
    }

    with_command_new_stub(Hive::Commands::StageAction) do |calls|
      expected.each_key do |verb|
        Hive::CLI.start([ verb, "slug", "--from", "inbox", "--project", "proj", "--json" ])
      end

      actual = calls.grep(Hash).map { |call| [ call.fetch(:args), call.fetch(:kwargs) ] }
      assert_equal expected.values.map { |verb|
        [ [ verb, "slug" ], { project: "proj", from: "inbox", json: true, durable: true } ]
      }, actual
    end
  end

  def test_review_pr_dispatches_adhoc_enqueue_then_stage_action
    # enqueue returns the RESOLVED project (here "resolved-proj"), deliberately
    # different from the raw --project "proj", so the assertion proves the CLI
    # forwards the resolved name to StageAction rather than the raw option.
    enqueue_result = { slug: "adhoc-review-pr-197", project: "resolved-proj" }
    with_command_new_stub(Hive::Commands::AdhocReview, return_value: enqueue_result) do |adhoc_calls|
      with_command_new_stub(Hive::Commands::StageAction) do |stage_calls|
        Hive::CLI.start([ "review", "--pr", "#197", "--project", "proj", "--json" ])

        adhoc_ctor = adhoc_calls.grep(Hash).first
        assert_equal [], adhoc_ctor.fetch(:args)
        assert_equal({ pr: "#197", project: "proj", json: true }, adhoc_ctor.fetch(:kwargs))
        assert_equal :enqueue, adhoc_calls.last

        stage_ctor = stage_calls.grep(Hash).first
        assert_equal [ "review", "adhoc-review-pr-197" ], stage_ctor.fetch(:args)
        assert_equal({ project: "resolved-proj", json: true, durable: true }, stage_ctor.fetch(:kwargs))
        assert_equal :call, stage_calls.last
      end
    end
  end

  def test_review_bare_number_still_dispatches_as_task_target
    with_command_new_stub(Hive::Commands::StageAction) do |calls|
      Hive::CLI.start([ "review", "197", "--project", "proj", "--json" ])

      ctor = calls.grep(Hash).first
      assert_equal [ "review", "197" ], ctor.fetch(:args)
      assert_equal({ project: "proj", from: nil, json: true, durable: true }, ctor.fetch(:kwargs))
      assert_equal :call, calls.last
    end
  end

  def test_review_pr_rejects_positional_target
    _out, err, status = with_captured_exit do
      Hive::CLI.start([ "review", "197", "--pr", "198" ])
    end

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/pass either TARGET or --pr/, err)
  end

  def test_review_pr_rejects_from_flag
    # --from only disambiguates a TARGET lookup; combining it with --pr must
    # be a usage error, not a silently-dropped flag.
    _out, err, status = with_captured_exit do
      Hive::CLI.start([ "review", "--pr", "197", "--from", "6-review" ])
    end

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/--from is not valid with --pr/, err)
  end

  def test_review_requires_target_or_pr
    _out, err, status = with_captured_exit { Hive::CLI.start([ "review" ]) }

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/missing TARGET/, err)
  end

  def test_review_usage_error_warns_when_envelope_is_not_serialisable
    # The JSON usage-error envelope's GeneratorError arm must warn (a
    # non-serialisable payload is a bug) rather than be silently swallowed;
    # the bare-text rescue in bin/hive still carries the failure.
    with_replaced_singleton_method(JSON, :generate, ->(*_args) { raise JSON::GeneratorError, "nope" }) do
      _out, err, status = with_captured_exit { Hive::CLI.start([ "review", "--json" ]) }

      assert_equal Hive::ExitCodes::USAGE, status
      assert_match(/review usage-error envelope was not serialisable/, err)
    end
  end

  def test_review_help_mentions_pr_option
    out, _err = capture_io { Hive::CLI.start([ "help", "review" ]) }

    assert_match(/--pr/, out)
    assert_match(/ad-hoc review/, out)
  end

  def test_archive_without_target_lists_archived_tasks_via_status
    with_command_new_stub(Hive::Commands::Status) do |calls|
      Hive::CLI.start([ "archive", "--json" ])

      assert_equal({ json: true, project: nil, archive: true }, calls.first.fetch(:kwargs))
      assert_equal :call, calls.last
    end
  end

  def test_archive_without_target_warns_when_from_is_supplied
    with_command_new_stub(Hive::Commands::Status) do |calls|
      _stdout, stderr = capture_io do
        Hive::CLI.start([ "archive", "--from", "8-finalize" ])
      end

      assert_includes stderr, "--from is ignored when listing"
      assert_equal({ json: false, project: nil, archive: true }, calls.first.fetch(:kwargs))
    end
  end

  def test_archive_without_target_scopes_to_project
    with_command_new_stub(Hive::Commands::Status) do |calls|
      Hive::CLI.start([ "archive", "--project", "proj" ])

      assert_equal({ json: false, project: "proj", archive: true }, calls.first.fetch(:kwargs))
    end
  end

  def test_status_approve_findings_and_finding_toggles_pass_options
    with_command_new_stub(Hive::Commands::Status) do |calls|
      Hive::CLI.start([ "status", "--diagnose", "slug", "--project", "proj", "--stage", "2-gather", "--write", "--force", "--json" ])
      assert_equal({ json: true, diagnose: "slug", project: "proj", stage: "2-gather", write: true, force: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Approve) do |calls|
      Hive::CLI.start([ "approve", "slug", "--to", "3-report", "--from", "2-gather", "--project", "proj", "--force", "--json" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ to: "3-report", from: "2-gather", project: "proj", force: true, json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Findings) do |calls|
      Hive::CLI.start([ "findings", "slug", "--pass", "2", "--project", "proj", "--stage", "execute", "--json" ])
      assert_equal [ "slug" ], calls.first.fetch(:args)
      assert_equal({ pass: 2, project: "proj", stage: "execute", json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::FindingToggle) do |calls|
      Hive::CLI.start([ "accept-finding", "slug", "1", "2", "--all", "--severity", "high", "--pass", "3", "--project", "proj", "--stage", "execute", "--json" ])
      Hive::CLI.start([ "reject-finding", "slug", "4", "--severity", "low", "--project", "proj", "--json" ])

      accept = calls.grep(Hash).first
      reject = calls.grep(Hash).last
      assert_equal [ Hive::Commands::FindingToggle::ACCEPT, "slug" ], accept.fetch(:args)
      assert_equal({ ids: [ "1", "2" ], all: true, severity: "high", pass: 3, project: "proj", stage: "execute", json: true }, accept.fetch(:kwargs))
      assert_equal [ Hive::Commands::FindingToggle::REJECT, "slug" ], reject.fetch(:args)
      assert_equal({ ids: [ "4" ], all: false, severity: "low", pass: nil, project: "proj", stage: nil, json: true }, reject.fetch(:kwargs))
    end
  end

  def test_patrol_markers_daemon_bot_and_metrics_pass_options
    with_command_new_stub(Hive::Commands::Patrol) do |calls|
      Hive::CLI.start([ "patrol", "proj", "--dry-run", "--json" ])
      assert_equal [ "proj" ], calls.first.fetch(:args)
      assert_equal({ json: true, dry_run: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::RefactorPatrol) do |calls|
      Hive::CLI.start([
        "refactor-patrol", "proj", "--list", "--limit", "25",
        "--cursor", "cursor-1", "--json"
      ])
      assert_equal [ "proj" ], calls.first.fetch(:args)
      assert_equal true, calls.first.fetch(:kwargs).fetch(:list)
      assert_nil calls.first.fetch(:kwargs).fetch(:show)
      assert_equal 25, calls.first.fetch(:kwargs).fetch(:limit)
      assert_equal "cursor-1", calls.first.fetch(:kwargs).fetch(:cursor)
      assert_equal false, calls.first.fetch(:kwargs).fetch(:full)
      assert_equal true, calls.first.fetch(:kwargs).fetch(:json)
    end

    with_command_new_stub(Hive::Commands::Digest) do |calls|
      Hive::CLI.start([ "digest", "--date", "2026-06-13", "--dry-run", "--json",
                        "--source", "merged-prs", "--repo", "owner/repo" ])
      assert_equal [], calls.first.fetch(:args)
      assert_equal({
        date: "2026-06-13",
        json: true,
        dry_run: true,
        source: "merged-prs",
        repos: [ "owner/repo" ]
      }, calls.first.fetch(:kwargs))
    end

    # Repeated `--repo` must accumulate, not silently keep only the last repo —
    # the documented multi-repo form (`--repo a/b --repo c/d`).
    with_command_new_stub(Hive::Commands::Digest) do |calls|
      Hive::CLI.start([ "digest", "--source", "merged-prs",
                        "--repo", "owner/repo", "--repo", "other/repo" ])
      assert_equal [ "owner/repo", "other/repo" ], calls.first.fetch(:kwargs).fetch(:repos),
                   "repeated --repo flags must accumulate every repo, not overwrite"
    end

    # The undocumented space-listed form (`--repo a/b c/d`) must also flatten
    # to the same list of slugs.
    with_command_new_stub(Hive::Commands::Digest) do |calls|
      Hive::CLI.start([ "digest", "--source", "merged-prs",
                        "--repo", "owner/repo", "other/repo" ])
      assert_equal [ "owner/repo", "other/repo" ], calls.first.fetch(:kwargs).fetch(:repos)
    end

    with_command_new_stub(Hive::Commands::AnswerDigest) do |calls|
      Hive::CLI.start([ "answer-digest", "--date", "2026-06-27", "--dry-run", "--json" ])
      assert_equal [], calls.first.fetch(:args)
      assert_equal({ date: "2026-06-27", json: true, dry_run: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Markers) do |calls|
      Hive::CLI.start([ "markers", "clear", "slug", "--name", "ERROR", "--project", "proj", "--match-attr", "exit_code=1", "--json" ])
      assert_equal [ "clear", "slug" ], calls.first.fetch(:args)
      assert_equal({ name: "ERROR", project: "proj", match_attr: "exit_code=1", json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Daemon) do |calls|
      Hive::CLI.start([ "daemon", "start", "--detach", "--dry-run", "--json" ])
      assert_equal [ "start", nil ], calls.first.fetch(:args)
      assert_equal({ detach: true, dry_run: true, all: false, json: true, force: false, queue_args: [] },
                   calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Bot) do |calls|
      Hive::CLI.start([ "bot", "start", "--detach", "--dry-run", "--json" ])
      assert_equal [ "start" ], calls.first.fetch(:args)
      assert_equal({ foreground: false, dry_run: true, json: true, force: false }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Pairing) do |calls|
      Hive::CLI.start([ "pairing", "approve", "telegram", "ABCDEFGH", "--json" ])
      assert_equal [ "approve" ], calls.first.fetch(:args)
      assert_equal({ args: [ "telegram", "ABCDEFGH" ], json: true }, calls.first.fetch(:kwargs))
    end

    with_command_new_stub(Hive::Commands::Metrics) do |calls|
      Hive::CLI.start([ "metrics", "rollback-rate", "--days", "30", "--project", "proj", "--json" ])
      assert_equal [ "rollback-rate" ], calls.first.fetch(:args)
      assert_equal({ days: 30, project: "proj", json: true }, calls.first.fetch(:kwargs))
    end
  end


  def test_bot_rejects_foreground_and_detach_together
    _out, err, status = with_captured_exit do
      Hive::CLI.start([ "bot", "start", "--foreground", "--detach" ])
    end

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/do not combine it with --foreground/, err)
  end

  def test_bot_rejects_force_on_non_install_subcommand
    _out, err, status = with_captured_exit do
      Hive::CLI.start([ "bot", "start", "--force" ])
    end

    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/--force only applies to `install`/, err)
  end

  # A closed stdout (broken pipe) while writing the bot argv-error --json
  # envelope must be swallowed: emit_bot_argv_error still raises the
  # InvalidTaskPath usage failure rather than letting a raw Errno::EPIPE
  # escape. Covers the `rescue Errno::EPIPE, JSON::GeneratorError` arm around
  # `puts JSON.generate(payload)`.
  def test_bot_argv_error_json_swallows_broken_pipe
    cli = Hive::CLI.new([], { json: true, force: true })
    cli.define_singleton_method(:puts) { |_payload| raise Errno::EPIPE, "closed pipe" }

    error = assert_raises(Hive::InvalidTaskPath) { cli.bot("status") }
    assert_match(/--force only applies to `install`/, error.message)
  end

  # P3: `hive web --json` previously accepted the global --json and silently
  # ignored it. Mirror `hive tui`'s rejection: emit a structured error
  # envelope and exit with EX_USAGE rather than booting a long-lived server.
  def test_web_rejects_json_with_usage_error
    out, _err, status = with_captured_exit { Hive::CLI.start([ "web", "--json" ]) }

    assert_equal Hive::ExitCodes::USAGE, status, "hive web --json must exit EX_USAGE, not start a server"
    payload = JSON.parse(out)
    assert_equal false, payload.fetch("ok")
    assert_equal "invalid_task_path", payload.fetch("error_kind")
    assert_match(/no JSON output/, payload.fetch("message"))
  end

  # The non-JSON `hive web` path boots the long-lived server via
  # Commands::Web.new(...).call. A unit test can't run Puma, so swap
  # Commands::Web for a recorder class for the duration of the call (the same
  # constant-swap technique web_command_test.rb uses for Puma::Server). This
  # proves the CLI wires bind/port through to the command and invokes #call,
  # without booting a socket.
  def test_web_wires_bind_and_port_into_the_web_command
    require "hive/commands/web"
    captured = []
    recorder = Class.new do
      # The constructor now takes a positional `subcommand` (nil for the
      # foreground server) plus the bind/port/no_bootstrap/unsafe/force/json/
      # detach kwargs the CLI forwards. Accept the positional + swallow the
      # extra kwargs so the recorder matches the real signature.
      define_method(:initialize) { |subcommand = nil, bind:, port:, **| captured << { bind: bind, port: port } }
      define_method(:call) { captured << :called }
    end

    original = Hive::Commands.const_get(:Web)
    Hive::Commands.send(:remove_const, :Web)
    Hive::Commands.const_set(:Web, recorder)
    begin
      capture_io { Hive::CLI.start([ "web", "--bind", "0.0.0.0", "--port", "9123" ]) }
    ensure
      Hive::Commands.send(:remove_const, :Web)
      Hive::Commands.const_set(:Web, original)
    end

    assert_equal({ bind: "0.0.0.0", port: 9123 }, captured.first,
                 "the --bind/--port flags must reach the web command")
    assert_equal :called, captured.last, "hive web must invoke the web command's #call"
  end

  def test_daemon_argv_errors_emit_json_envelopes_before_raising
    out, _err, status = with_captured_exit { Hive::CLI.start([ "daemon", "--json" ]) }
    payload = JSON.parse(out)
    assert_equal Hive::ExitCodes::USAGE, status
    assert_equal "hive-daemon-enroll", payload.fetch("schema")
    assert_equal Hive::Schemas::EnrollErrorKind::MISSING_PROJECT, payload.fetch("error_kind")

    out, _err, status = with_captured_exit { Hive::CLI.start([ "daemon", "enable", "one", "two", "--json" ]) }
    payload = JSON.parse(out)
    assert_equal Hive::ExitCodes::USAGE, status
    assert_equal Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL, payload.fetch("error_kind")

    out, _err, status = with_captured_exit { Hive::CLI.start([ "daemon", "status", "--force", "--json" ]) }
    payload = JSON.parse(out)
    assert_equal Hive::ExitCodes::USAGE, status
    assert_equal Hive::Schemas::EnrollErrorKind::WRONG_SUBCOMMAND_FLAG, payload.fetch("error_kind")
  end

  def test_bench_submit_dispatches_to_command
    require "hive/commands/bench_submit"
    with_command_new_stub(Hive::Commands::BenchSubmit) do |calls|
      Hive::CLI.start([ "bench", "submit", "my-slug-260601-aa11", "--project", "demo" ])
      ctor = calls.grep(Hash).first
      assert_equal [ "my-slug-260601-aa11" ], ctor.fetch(:args)
      assert_equal "demo", ctor.fetch(:kwargs)[:project]
      assert_equal :call, calls.last
    end
  end

  def test_bench_unknown_subcommand_warns_and_exits_usage
    out = +""
    err = +""
    out, err = capture_io do
      assert_raises(SystemExit) { Hive::CLI.start([ "bench", "frobnicate" ]) }
    end
    assert_match(/unknown subcommand/, "#{out}#{err}")
  end
end
