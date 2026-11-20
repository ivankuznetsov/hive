require "test_helper"
require "json"
require "hive/attempts/context"
require "hive/attempts/repository"
require "hive/implementation_limit_fallback"
require "hive/stages/execute"
require "hive/stages/open_pr"
require "hive/task_projection"

# implementation.limit_fallback: the decision and identity rules, the durable
# substitution record, and the execute / open-PR launch seams. Finalize,
# artifacts, and the status surfaces are covered in
# implementation_limit_fallback_stages_test.rb.
class ImplementationLimitFallbackTest < Minitest::Test
  include HiveTestHelper

  Fallback = Hive::ImplementationLimitFallback

  TaskStub = Struct.new(
    :folder, :state_file, :worktree_yml_path, :project_root, :slug, :reviews_dir,
    :depends_on, :id, :stage_index, :stage_name, keyword_init: true
  )

  FakeGit = Struct.new(:head, :branch, :message, keyword_init: true) do
    def head_sha = head
    def current_branch = branch
    def status_short = ""
    def ancestor?(_base, _head) = true
    def commit_message(_revision) = message.to_s
  end

  # Codex's real wall: "Nov 23rd" has no year/time, so no explicit reset.
  LONG_LIMIT = "You've hit your usage limit. Upgrade to Pro or try again at Nov 23rd.".freeze
  LIMIT_MESSAGE = "limits reached for codex: You've hit your usage limit.".freeze
  LIMITED = { status: :error, error_reason: "limits_reached", limit_text: LONG_LIMIT,
              error_message: LIMIT_MESSAGE }.freeze

  def fallback_cfg(root, enabled: true, agents: { "codex" => "grok" }, min_wait_sec: 3600,
                   execute: { "agent" => "codex", "model" => "gpt-5.6-sol" }, open_pr: {}, extra: {})
    {
      "project_root" => root,
      "execute" => execute,
      "open_pr" => open_pr,
      "implementation" => {
        "limit_fallback" => { "enabled" => enabled, "min_wait_sec" => min_wait_sec, "agents" => agents }
      },
      Hive::Config::IMPLEMENTATION_IDENTITY_PROVENANCE_KEY => {
        "execute" => execute, "open_pr" => open_pr, "review.fix" => {}, "review.ci" => {}
      }
    }.merge(extra)
  end

  def reset_hint(at)
    "You've hit your usage limit. Try again at #{at.utc.strftime('%b %-d, %Y %-I:%M %p')} UTC."
  end

  # Grok's default model comes from the project's .grok/settings.json.
  def write_grok_default(root, model = "grok-4.6")
    FileUtils.mkdir_p(File.join(root, ".grok"))
    File.write(File.join(root, ".grok", "settings.json"), JSON.generate("model" => model))
  end

  def explicit_routing_context
    Struct.new(:adapter) { def explicit_routing? = true }.new("codex")
  end

  # --- decision -------------------------------------------------------------

  def test_plan_is_nil_when_disabled_unmapped_or_not_limited
    with_tmp_dir do |root|
      write_grok_default(root)
      assert_nil Fallback.plan(cfg: fallback_cfg(root, enabled: false), stage: "execute",
                               primary: "codex", limit_text: LONG_LIMIT)
      assert_nil Fallback.plan(cfg: {}, stage: "execute", primary: "codex", limit_text: LONG_LIMIT)
      # A generic failure (no classified limit text) never falls back.
      assert_nil Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "codex",
                               limit_text: nil, error_message: "codex crashed: exit 1")
      _out, err = capture_io do
        assert_nil Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "pi",
                                 limit_text: LONG_LIMIT)
      end
      assert_match(/no fallback agent configured for it in implementation\.limit_fallback\.agents/, err)
      assert_raises(ArgumentError) do
        Fallback.plan(cfg: fallback_cfg(root), stage: "review.fix", primary: "codex", limit_text: LONG_LIMIT)
      end
    end
  end

  def test_plan_waits_when_the_reset_is_sooner_than_min_wait
    with_tmp_dir do |root|
      now = Time.now.utc
      plan = nil
      _out, err = capture_io do
        plan = Fallback.plan(cfg: fallback_cfg(root), stage: "open_pr", primary: "codex",
                             limit_text: reset_hint(now + 600), now: now)
      end

      assert_equal "waiting", plan.state
      refute plan.substitute?
      assert_nil plan.identity
      assert_equal({ primary_agent: "codex", fallback_agent: "grok", fallback_outcome: "waiting" },
                   plan.marker_attrs)
      assert_match(/min_wait_sec=3600/, err)
    end
  end

  def test_plan_substitutes_the_fallback_profile_default_for_a_long_or_absent_reset
    with_tmp_dir do |root|
      write_grok_default(root, "grok-4.6")
      now = Time.now.utc
      long = Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "codex",
                           limit_text: reset_hint(now + 3 * 86_400), now: now)
      absent = Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "codex",
                             limit_text: nil, error_message: LIMIT_MESSAGE)

      assert long.substitute?
      refute_nil long.retry_after
      assert_nil absent.retry_after
      assert_equal LIMIT_MESSAGE, absent.limit_detail
      identity = absent.identity
      assert_equal %w[grok grok-4.6 limit_fallback execute],
                   [ identity.provider, identity.model, identity.source, identity.stage ]
      assert_equal 0, identity.generation
      assert_equal "execute-impl-fallback-grok", absent.log_label("execute-impl")
    end
  end

  def test_plan_runs_the_model_the_stage_config_names_for_the_fallback
    with_tmp_dir do |root|
      cfg = fallback_cfg(
        root, execute: { "agent" => "grok", "model" => "grok-4.7" },
              open_pr: { "agent" => "grok", "model" => "grok-4.7-mini" }
      )
      execute_pin = Hive::ImplementationIdentity::Resolver.new(cfg: fallback_cfg(root))
                                                          .resolve_execute(generation: 3, attempt_id: "a")

      open_pr = Fallback.plan(cfg: cfg, stage: "open_pr", primary: "codex", limit_text: LONG_LIMIT,
                              execute_identity: execute_pin)
      execute = Fallback.plan(cfg: cfg, stage: "execute", primary: "codex", limit_text: LONG_LIMIT)

      assert_equal %w[grok grok-4.7-mini limit_fallback],
                   [ open_pr.identity.provider, open_pr.identity.model, open_pr.identity.source ]
      assert_equal 3, open_pr.identity.generation
      assert_equal %w[grok grok-4.7], [ execute.identity.provider, execute.identity.model ]
    end
  end

  def test_plan_is_unresolved_when_the_fallback_identity_cannot_be_resolved
    with_tmp_dir do |root|
      with_env("HOME" => root) do
        plan = nil
        _out, err = capture_io do
          plan = Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "codex",
                               limit_text: LONG_LIMIT)
        end

        assert_equal "unresolved", plan.state
        assert_equal "unresolved", plan.marker_attrs.fetch(:fallback_outcome)
        assert_match(/fallback grok could not be resolved/, err)
      end
    end
  end

  def test_plan_skips_under_explicit_provider_routing
    with_tmp_dir do |root|
      write_grok_default(root)
      context = explicit_routing_context
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        _out, err = capture_io do
          assert_nil Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "codex",
                                   limit_text: LONG_LIMIT)
        end
        assert_match(/explicit provider routing/, err)
      end
    end
  end

  def test_resolver_rejects_a_stage_without_a_durable_identity
    with_tmp_dir do |root|
      error = assert_raises(Hive::ImplementationIdentity::ResolutionError) do
        Hive::ImplementationIdentity::Resolver.new(cfg: fallback_cfg(root)).resolve_limit_fallback(
          "finalize", provider: "grok", execute_identity: nil, generation: 1, attempt_id: nil
        )
      end
      assert_match(/not an implementation-owning stage/, error.message)
    end
  end

  def test_finish_logs_and_classifies_the_substitute_outcome
    plan = Fallback::Plan.new(
      stage: "execute", role: "execute", primary: "codex", fallback: "grok", state: "substitute",
      retry_after: nil, limit_detail: "usage limit", identity: nil
    )
    _out, err = capture_io do
      assert_equal "used", Fallback.finish(plan, ok: true, limited: true)
      assert_equal "limited", Fallback.finish(plan, ok: false, limited: true)
      assert_equal "failed", Fallback.finish(plan, ok: false, limited: false)
    end
    assert_match(/fallback grok used for this attempt; the codex pin is unchanged/, err)
    assert_equal({ "a" => 1 }, Fallback.fallback_cfg("a" => 1, "models" => {}))
    assert_equal({ "a" => 1 }, Fallback.fallback_cfg("a" => 1))
    assert_nil Fallback.identity_generation(nil)
    assert_equal 4, Fallback.identity_generation("generation" => 4)
  end

  # --- durable substitution record ------------------------------------------

  def test_record_journals_both_identities_without_rewriting_the_pin
    with_execute_attempt do |task, attempt_store, root|
      cfg = fallback_cfg(root)
      write_grok_default(root)
      with_attempt(attempt_store) do
        pin = Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg).capture_execute!
        plan = Fallback.plan(cfg: cfg, stage: "execute", primary: "codex", limit_text: LONG_LIMIT,
                             execute_identity: pin)
        assert Fallback.record!(task: task, cfg: cfg, plan: plan, primary: pin)
        # An identical repeat inside the same attempt is idempotent.
        assert Fallback.record!(task: task, cfg: cfg, plan: plan, primary: pin)
        assert_equal pin.to_h, Fallback.current_execute_identity(task, cfg).to_h
      end

      events = journal(task).select { |event| event["event_type"] == "implementation_identity_substituted" }
      assert_equal 1, events.length
      payload = events.first.fetch("payload")
      assert_equal "provider_limit_fallback", events.first.fetch("reason")
      assert_equal %w[execute execute attempt], payload.values_at("stage", "role", "scope")
      assert_equal %w[codex gpt-5.6-sol], payload.fetch("primary").values_at("provider", "model")
      assert_equal %w[grok grok-4.6 limit_fallback],
                   payload.fetch("substitute").values_at("provider", "model", "source")

      projection = Hive::TaskProjection::Reader.new(task_folder: task.folder).read
      identity = projection["implementation_identity"]
      assert_equal "codex", identity.dig("execute", "provider")
      substitution = identity.fetch("substitutions").first
      assert_equal "execute-attempt", substitution.fetch("attempt_id")
      assert_equal "grok", substitution.dig("substitute", "provider")
      assert_equal "codex", substitution.dig("primary", "provider")
    end
  end

  def test_record_routes_for_config_driven_stages_and_rejects_invalid_routes
    with_execute_attempt do |task, attempt_store, root|
      cfg = fallback_cfg(root)
      with_attempt(attempt_store) do
        store = Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg)
        payload = store.record_limit_fallback!(
          stage: "finalize", role: "finalize",
          primary: { "provider" => "codex", "model" => nil }, substitute: { provider: "grok" },
          retry_after: nil, limit_detail: "usage limit"
        )
        assert_equal({ "provider" => "codex" }, payload.fetch("primary"))
        assert_equal({ "provider" => "grok" }, payload.fetch("substitute"))

        assert_raises(Hive::ImplementationIdentity::ResolutionError) do
          store.record_limit_fallback!(stage: "plan", role: "plan", primary: {}, substitute: {},
                                       retry_after: nil, limit_detail: "")
        end
        assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
          store.record_limit_fallback!(stage: "finalize", role: "finalize", primary: "codex",
                                       substitute: { "provider" => "grok" }, retry_after: nil, limit_detail: "")
        end
        assert_raises(Hive::ImplementationIdentity::InvalidIdentity) do
          store.record_limit_fallback!(stage: "finalize", role: "finalize", primary: { "model" => "x" },
                                       substitute: { "provider" => "grok" }, retry_after: nil, limit_detail: "")
        end
      end
    end
  end

  def test_record_is_a_no_op_outside_an_attempt_and_reports_append_failures
    with_tmp_dir do |root|
      plan = Fallback::Plan.new(
        stage: "execute", role: "execute", primary: "codex", fallback: "grok", state: "substitute",
        retry_after: nil, limit_detail: "usage limit", identity: nil
      )
      task = TaskStub.new(folder: root, slug: "t")
      assert Fallback.record!(task: task, cfg: {}, plan: plan, primary: nil)
      assert_nil Fallback.current_execute_identity(task, {})

      context = Struct.new(:attempt_id) { def explicit_routing? = false }.new("a")
      failing = Object.new
      failing.define_singleton_method(:record_limit_fallback!) { |**| raise Hive::TaskJournal::Error, "disk full" }
      with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
        with_replaced_singleton_method(Hive::ImplementationIdentity::Store, :new, ->(**) { failing }) do
          _out, err = capture_io do
            refute Fallback.record!(task: task, cfg: {}, plan: plan, primary: nil)
          end
          assert_match(/could not journal the grok substitution .*disk full/, err)
        end
      end
    end
  end

  # --- 4-execute ------------------------------------------------------------

  def test_execute_limit_falls_back_when_enabled_and_journals_both_identities
    with_execute_attempt do |task, attempt_store, root|
      cfg = fallback_cfg(root)
      write_grok_default(root)
      calls = []
      # The generation-scoped completion boundary is covered by the execute
      # suite; here only the identity journal matters.
      complete = lambda do |task_arg, _cfg, _path, _base, marker_name:, attrs:, commit:, status:, **|
        Hive::Markers.set(task_arg.state_file, marker_name, attrs)
        { commit: commit, status: status }
      end
      result = with_attempt(attempt_store) do
        with_replaced_singleton_method(Hive::Stages::Execute, :apply_execute_outcome, complete) do
          with_execute_spawns(task, calls, [ LIMITED, success_result ]) do
            capture_io { @run = Hive::Stages::Execute.run_pass(task, cfg, worktree(root)) }
            @run
          end
        end
      end

      assert_equal({ commit: "execute_complete", status: :execute_complete }, result)
      assert_equal 2, calls.length
      assert_nil calls.first[:limit_fallback]
      substitute = calls.last
      assert_equal "grok", substitute.fetch(:limit_fallback).fallback
      assert_equal %w[grok grok-4.6], [ substitute.fetch(:identity).provider, substitute.fetch(:identity).model ]

      projection = Hive::TaskProjection::Reader.new(task_folder: task.folder).read
      identity = projection["implementation_identity"]
      assert_equal "codex", identity.dig("execute", "provider"), "the execute pin is unchanged"
      substitutions = identity.fetch("substitutions")
      assert_equal 1, substitutions.length
      substitution = substitutions.first
      assert_equal %w[execute codex grok],
                   [ substitution["stage"], substitution.dig("primary", "provider"),
                     substitution.dig("substitute", "provider") ]
    end
  end

  def test_execute_limit_is_unchanged_when_the_fallback_is_disabled
    with_execute_task do |task, root|
      calls = []
      result = with_execute_spawns(task, calls, [ LIMITED ]) do
        Hive::Stages::Execute.run_pass(task, fallback_cfg(root, enabled: false), worktree(root))
      end

      assert_equal({ commit: "limits_reached", status: :error }, result)
      assert_equal 1, calls.length
      attrs = Hive::Markers.current(task.state_file).attrs
      assert_equal %w[limits_reached codex], attrs.values_at("reason", "provider")
      assert_nil attrs["fallback_agent"]
    end
  end

  def test_execute_short_reset_waits_instead_of_falling_back
    with_execute_task do |task, root|
      write_grok_default(root)
      calls = []
      wall = LIMITED.merge(limit_text: reset_hint(Time.now.utc + 600))
      result = nil
      capture_io do
        result = with_execute_spawns(task, calls, [ wall ]) do
          Hive::Stages::Execute.run_pass(task, fallback_cfg(root), worktree(root))
        end
      end

      assert_equal({ commit: "limits_reached", status: :error }, result)
      assert_equal 1, calls.length
      attrs = Hive::Markers.current(task.state_file).attrs
      assert_equal %w[limits_reached codex grok waiting],
                   attrs.values_at("reason", "primary_agent", "fallback_agent", "fallback_outcome")
    end
  end

  def test_execute_generic_failure_never_falls_back
    with_execute_task do |task, root|
      write_grok_default(root)
      calls = []
      failure = { status: :error, error_message: "codex crashed: exit 1" }
      result = with_execute_spawns(task, calls, [ failure ]) do
        Hive::Stages::Execute.run_pass(task, fallback_cfg(root), worktree(root))
      end

      assert_equal({ commit: "implementer_failed", status: :error }, result)
      assert_equal 1, calls.length
      assert_nil Hive::Markers.current(task.state_file).attrs["fallback_agent"]
    end
  end

  def test_execute_keeps_the_primary_limit_when_the_substitute_fails
    { LIMITED.merge(limit_text: "rate limit reached for grok") => "limited",
      { status: :error, error_message: "grok crashed" } => "failed" }.each do |substitute, outcome|
      with_execute_task do |task, root|
        write_grok_default(root)
        calls = []
        result = nil
        capture_io do
          result = with_execute_spawns(task, calls, [ LIMITED, substitute ]) do
            Hive::Stages::Execute.run_pass(task, fallback_cfg(root), worktree(root))
          end
        end

        assert_equal({ commit: "limits_reached", status: :error }, result)
        assert_equal 2, calls.length
        attrs = Hive::Markers.current(task.state_file).attrs
        assert_equal [ "limits_reached", "codex", "codex", "grok", outcome ],
                     attrs.values_at("reason", "provider", "primary_agent", "fallback_agent", "fallback_outcome")
      end
    end
  end

  def test_execute_unresolved_or_unrecorded_substitutes_never_launch
    with_execute_task do |task, root|
      calls = []
      with_env("HOME" => root) do
        capture_io do
          with_execute_spawns(task, calls, [ LIMITED ]) do
            Hive::Stages::Execute.run_pass(task, fallback_cfg(root), worktree(root))
          end
        end
      end
      assert_equal 1, calls.length
      assert_equal "unresolved", Hive::Markers.current(task.state_file).attrs["fallback_outcome"]
    end

    with_execute_task do |task, root|
      write_grok_default(root)
      calls = []
      with_replaced_singleton_method(Fallback, :record!, ->(**) { false }) do
        with_execute_spawns(task, calls, [ LIMITED ]) do
          Hive::Stages::Execute.run_pass(task, fallback_cfg(root), worktree(root))
        end
      end
      assert_equal 1, calls.length
      assert_equal "failed", Hive::Markers.current(task.state_file).attrs["fallback_outcome"]
    end
  end

  def test_execute_substitute_tampering_is_terminal
    with_execute_task do |task, root|
      write_grok_default(root)
      calls = []
      tamper = lambda do |custody|
        custody.call do
          File.write(File.join(task.folder, "plan.md"), "# rewritten\n")
          { status: :ok }
        end
      end
      result = nil
      capture_io do
        result = with_execute_spawns(task, calls, [ LIMITED, tamper ]) do
          Hive::Stages::Execute.run_pass(task, fallback_cfg(root), worktree(root))
        end
      end

      assert_equal({ commit: "implementer_tampered", status: :error }, result)
      assert_equal 2, calls.length
      assert_equal "implementer_tampered", Hive::Markers.current(task.state_file).attrs["reason"]
    end
  end

  def test_execute_substitute_launch_uses_the_substitute_identity_without_observing_the_pin
    with_execute_task do |task, root|
      write_grok_default(root, "grok-4.6")
      plan = Fallback.plan(cfg: fallback_cfg(root), stage: "execute", primary: "codex",
                           limit_text: LONG_LIMIT)
      spawned = nil
      scope = {
        add_dirs: [ task.folder ], permission_mode: nil, allowed_tools: nil, disallowed_tools: nil,
        runtime_policy: nil, additional_read_roots: [], additional_write_roots: []
      }
      captured = lambda { |*, **| raise "the substitute must not capture the execute pin" }
      with_replaced_singleton_method(Hive::Stages::Execute, :capture_implementation_identity, captured) do
        with_replaced_singleton_method(Hive::Stages::Base, :stage_permission_scope_or_mark!, ->(*, **) { scope }) do
          with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*, **kwargs) { spawned = kwargs; { status: :ok } }) do
            result = Hive::Stages::Execute.spawn_implementation(
              task, fallback_cfg(root), worktree(root), identity: plan.identity, limit_fallback: plan
            )
            assert_equal "grok", result.fetch(:implementation_provider)
          end
        end
      end

      assert_equal "grok", spawned.fetch(:profile).name.to_s
      assert_equal "execute-impl-fallback-grok", spawned.fetch(:log_label)
      assert_nil spawned.fetch(:implementation_stage)
      assert_equal plan.identity.native_arguments, spawned.fetch(:identity_arguments)
    end
  end

  # --- 5-open-pr ------------------------------------------------------------

  def test_open_pr_limit_falls_back_and_reads_the_substitute_draft
    with_open_pr_task do |task, root, pointer|
      write_grok_default(root)
      calls = []
      draft = lambda do |path|
        File.write(path, JSON.generate("title" => "Add feature", "body" => "Body\n"))
        { status: :ok }
      end
      authoring = nil
      _out, err = capture_io do
        authoring = with_open_pr_spawns(calls, [ LIMITED, draft ]) do
          Hive::Stages::OpenPr.authoring_for(task, fallback_cfg(root), pointer, nil, codex_profile, {})
        end
      end

      assert_equal "Add feature", authoring.title
      assert_equal 2, calls.length
      assert_equal %w[codex grok], calls.map { |call| call.fetch(:profile).name.to_s }
      assert_equal "grok", calls.last.fetch(:identity).provider
      assert_equal "grok", calls.last.fetch(:limit_fallback).fallback
      assert_match(/open_pr: codex hit a usage\/credit limit .*fallback grok used/, err)
    end
  end

  def test_open_pr_substitute_launch_is_labelled_and_never_observes_the_pin
    with_open_pr_task do |task, root, _pointer|
      write_grok_default(root, "grok-4.6")
      plan = Fallback.plan(cfg: fallback_cfg(root), stage: "open_pr", primary: "codex", limit_text: LONG_LIMIT)
      spawned = nil
      scope = {
        add_dirs: [ task.folder ], permission_mode: nil, allowed_tools: nil, disallowed_tools: nil,
        runtime_policy: nil, additional_read_roots: [], additional_write_roots: []
      }
      with_replaced_singleton_method(Hive::Stages::Base, :stage_permission_scope_or_mark!, ->(*, **) { scope }) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_agent, ->(*, **kwargs) { spawned = kwargs; { status: :ok } }) do
          Hive::Stages::OpenPr.spawn_open_pr_agent(
            task, fallback_cfg(root), "prompt", Hive::AgentProfiles.lookup("grok"), task.folder,
            identity: plan.identity, limit_fallback: plan
          )
        end
      end

      assert_equal "open-pr-author-fallback-grok", spawned.fetch(:log_label)
      assert_nil spawned.fetch(:implementation_stage)
      assert_equal plan.identity.native_arguments, spawned.fetch(:identity_arguments)
      assert_equal "medium", plan.identity.requested_effort
    end
  end

  def test_open_pr_limit_is_unchanged_when_disabled_and_annotated_when_the_substitute_fails
    with_open_pr_task do |task, root, pointer|
      calls = []
      result = with_open_pr_spawns(calls, [ LIMITED ]) do
        Hive::Stages::OpenPr.authoring_for(task, fallback_cfg(root, enabled: false), pointer, nil,
                                           codex_profile, {})
      end
      assert_equal({ commit: "limits_reached", status: :error }, result)
      assert_equal 1, calls.length
      assert_nil Hive::Markers.current(task.state_file).attrs["fallback_agent"]
    end

    with_open_pr_task do |task, root, pointer|
      write_grok_default(root)
      calls = []
      result = nil
      capture_io do
        result = with_open_pr_spawns(calls, [ LIMITED, LIMITED ]) do
          Hive::Stages::OpenPr.authoring_for(task, fallback_cfg(root), pointer, nil, codex_profile, {})
        end
      end
      assert_equal({ commit: "limits_reached", status: :error }, result)
      attrs = Hive::Markers.current(task.state_file).attrs
      assert_equal %w[codex grok limited], attrs.values_at("provider", "fallback_agent", "fallback_outcome")
    end
  end

  def test_open_pr_waiting_unrecorded_and_tampered_substitutes
    with_open_pr_task do |task, root, pointer|
      wall = LIMITED.merge(limit_text: reset_hint(Time.now.utc + 600))
      calls = []
      capture_io do
        with_open_pr_spawns(calls, [ wall ]) do
          Hive::Stages::OpenPr.authoring_for(task, fallback_cfg(root), pointer, nil, codex_profile, {})
        end
      end
      assert_equal 1, calls.length
      assert_equal "waiting", Hive::Markers.current(task.state_file).attrs["fallback_outcome"]
    end

    with_open_pr_task do |task, root, pointer|
      write_grok_default(root)
      calls = []
      with_replaced_singleton_method(Fallback, :record!, ->(**) { false }) do
        with_open_pr_spawns(calls, [ LIMITED ]) do
          Hive::Stages::OpenPr.authoring_for(task, fallback_cfg(root), pointer, nil, codex_profile, {})
        end
      end
      assert_equal 1, calls.length
      assert_equal "failed", Hive::Markers.current(task.state_file).attrs["fallback_outcome"]
    end

    with_open_pr_task do |task, root, pointer|
      write_grok_default(root)
      calls = []
      tamper = lambda do |_path|
        File.write(File.join(task.folder, "task.md"), "forged\n")
        { status: :ok }
      end
      result = with_open_pr_spawns(calls, [ LIMITED, tamper ], custody: :real) do
        Hive::Stages::OpenPr.authoring_for(task, fallback_cfg(root), pointer, nil, codex_profile, {})
      end
      assert_equal({ commit: "open_pr_tampered", status: :error }, result)
    end
  end

  private

  def success_result
    { status: :ok, final_message: "implemented", final_message_source: :structured }
  end

  def worktree(root) = File.join(root, "worktree")

  def codex_profile = Hive::AgentProfiles.lookup("codex")

  def journal(task)
    Hive::TaskProjection.read_journal(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
  end

  def with_execute_task
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "4-execute", "fallback-task")
      FileUtils.mkdir_p(folder)
      task = TaskStub.new(
        folder: folder, state_file: File.join(folder, "task.md"),
        worktree_yml_path: File.join(folder, "worktree.yml"), project_root: root,
        slug: "fallback-task", reviews_dir: File.join(folder, "reviews"), id: 42,
        stage_index: 4, stage_name: "execute"
      )
      File.write(task.state_file, "# Task\n")
      File.write(File.join(folder, "plan.md"), "# plan\n")
      File.write(task.worktree_yml_path, {
        "path" => worktree(root), "branch" => task.slug, "execute_base_head" => "base"
      }.to_yaml)
      yield task, root
    end
  end

  def with_execute_attempt
    with_execute_task do |task, root|
      attempt_store = Hive::Attempts::Repository.new(root: File.join(root, "attempts"), migrate: true)
      attempt_store.create_launching(
        attempt_id: "execute-attempt", request_id: "request",
        task_id: "42", project: "demo", task_slug: task.slug, intended_stage: "4-execute",
        task_generation: "owner-1", ownership_generation: "owner-1", task_input_epoch: 1,
        progress_token: "progress", provider: "codex", starting_revision: nil,
        worker_argv: [ "hive", "run", task.slug ],
        claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
      )
      yield task, attempt_store, root
    end
  end

  def with_attempt(attempt_store, &block)
    with_replaced_singleton_method(Hive::Attempts::Repository, :open_default, ->(**) { attempt_store }) do
      with_attempt_context(
        attempt_id: "execute-attempt", task_generation: 1, ownership_generation: "owner-1", &block
      )
    end
  end

  # Each queued response is a result Hash or a lambda receiving the custody.
  def with_execute_spawns(task, calls, responses)
    trailer = Hive::Stages::Execute.completion_trailer(File.binread(File.join(task.folder, "plan.md")))
    git = FakeGit.new(head: "new-head", branch: task.slug, message: "done\n\n#{trailer}\n")
    queue = responses.dup
    spawn = lambda do |_task, _cfg, _path, agent_custody:, **kwargs|
      calls << kwargs
      response = queue.shift
      next response.call(agent_custody) if response.respond_to?(:call)

      agent_custody.call { response.merge(implementation_provider: kwargs[:limit_fallback]&.fallback || "codex") }
    end
    with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { git }) do
      with_replaced_singleton_method(Hive::Stages::Execute, :spawn_implementation, spawn) { yield }
    end
  end

  def with_open_pr_task
    with_tmp_dir do |root|
      folder = File.join(root, "task")
      FileUtils.mkdir_p(folder)
      task = Struct.new(:folder, :state_file, :project_root, :slug, :depends_on, :id, keyword_init: true)
                   .new(folder: folder, state_file: File.join(folder, "pr.md"), project_root: root,
                        slug: "open-pr-task", id: 2)
      File.write(task.state_file, "# PR\n")
      File.write(File.join(folder, "task.md"), "# Task\n")
      pointer = { "path" => root, "branch" => task.slug, "base_oid" => "base" }
      with_replaced_singleton_method(Hive::Stages::OpenPr, :publication_base_branch, ->(*) { "main" }) do
        yield task, root, pointer
      end
    end
  end

  # Each queued response is a result Hash or a lambda receiving the output
  # path. `custody: :real` runs the stage's own artifact custody.
  def with_open_pr_spawns(calls, responses, custody: :clean)
    queue = responses.dup
    spawn = lambda do |_task, _cfg, _prompt, profile, _cwd, agent_custody:, expected_output:, **kwargs|
      calls << kwargs.merge(profile: profile)
      response = queue.shift
      agent_custody.call { response.respond_to?(:call) ? response.call(expected_output) : response.dup }
    end
    with_replaced_singleton_method(Hive::Stages::OpenPr, :spawn_open_pr_agent, spawn) do
      next yield if custody == :real

      clean = Struct.new(:tampered?, :restored?, :restore_diagnostic, :tampered_labels)
                    .new(false, false, nil, [])
      fake = lambda do |_manifest|
        Object.new.tap do |object|
          object.define_singleton_method(:call) { |&block| block.call }
          object.define_singleton_method(:report) { clean }
        end
      end
      with_replaced_singleton_method(Hive::ArtifactFirewall::AgentCustody, :new, fake) { yield }
    end
  end
end
