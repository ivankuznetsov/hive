require "test_helper"
require "json"
require "hive/stages/review"
require "hive/stages/review/ci_fix"
require "hive/reviewers"

# Coverage for the opt-in review.limit_fallback substitution: the decision
# module itself, the reviewers phase, triage, and the fix / CI-fix spawn
# seams. The orchestrator-level fix and marker wiring is exercised in
# test/integration/run_review_test.rb.
class ReviewLimitFallbackTest < Minitest::Test
  include HiveTestHelper

  LimitFallback = Hive::Stages::Review::LimitFallback
  Task = Struct.new(:folder, :state_file, :slug)

  # No reset hint: the incident's "try again at Nov 11th" has no year/time,
  # so the provider gave no parseable reset estimate.
  LONG_LIMIT = "You've hit your usage limit. Upgrade to Pro or try again at Nov 11th.".freeze
  LIMIT_MESSAGE = "limits reached for codex: You've hit your usage limit.".freeze

  def setup
    LimitFallback.reset_run!
  end

  def teardown
    LimitFallback.reset_run!
  end

  def enabled_cfg(agents: { "codex" => "claude" }, min_wait_sec: 3600, extra: {})
    {
      "review" => {
        "limit_fallback" => { "enabled" => true, "min_wait_sec" => min_wait_sec, "agents" => agents }
      }
    }.merge(extra) { |_key, left, right| left.merge(right) }
  end

  def reset_hint(at)
    "You've hit your usage limit. Try again at #{at.utc.strftime('%b %-d, %Y %-I:%M %p')} UTC."
  end

  def make_ctx(dir, pass: 1)
    Hive::Reviewers::Context.new(worktree_path: dir, task_folder: dir, default_branch: "main", pass: pass)
  end

  def receipt_entries(dir, pass: 1)
    File.readlines(LimitFallback.receipt_path(dir, pass)).map { |line| JSON.parse(line) }
  end

  def explicit_routing_context
    Struct.new(:adapter) { def explicit_routing? = true }.new("codex")
  end

  def with_stage_dir
    with_tmp_dir do |root|
      dir = File.join(root, ".hive-state", "stages", "6-review", "fallback-task")
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      prepare_test_task_run(dir)
      yield dir
    end
  end

  # --- decision ------------------------------------------------------------

  def test_settings_require_explicit_enable
    assert_nil LimitFallback.settings(nil)
    assert_nil LimitFallback.settings({})
    assert_nil LimitFallback.settings("review" => { "limit_fallback" => { "enabled" => false } })
    assert LimitFallback.settings(enabled_cfg)
  end

  def test_configured_fallback_never_returns_the_same_provider
    assert_equal "claude", LimitFallback.configured_fallback(enabled_cfg, "codex")
    assert_nil LimitFallback.configured_fallback(enabled_cfg, nil)
    assert_nil LimitFallback.configured_fallback(enabled_cfg, "pi")
    assert_nil LimitFallback.configured_fallback(enabled_cfg(agents: { "codex" => "codex" }), "codex")
    assert_nil LimitFallback.configured_fallback(enabled_cfg(agents: "codex"), "codex")
    assert_nil LimitFallback.configured_fallback({}, "codex")
  end

  def test_decide_returns_nil_when_disabled_or_not_limited
    assert_nil LimitFallback.decide({}, phase: "fix", primary: "codex", limit_text: LONG_LIMIT, error_message: nil)
    assert_nil LimitFallback.decide(enabled_cfg, phase: "fix", primary: "codex",
                                                 limit_text: nil, error_message: "codex crashed: exit 1")
    assert_nil LimitFallback.decide(enabled_cfg, phase: "fix", primary: "codex",
                                                 limit_text: nil, error_message: "auth failed: please run codex login")
  end

  def test_decide_logs_missing_mapping
    _out, err = capture_io do
      assert_nil LimitFallback.decide(enabled_cfg, phase: "fix", primary: "pi", limit_text: LONG_LIMIT, error_message: nil)
    end
    assert_match(/no fallback agent configured/, err)
  end

  def test_decide_skips_under_explicit_provider_routing
    context = explicit_routing_context
    with_replaced_singleton_method(Hive::Attempts::Context, :current, -> { context }) do
      _out, err = capture_io do
        assert_nil LimitFallback.decide(enabled_cfg, phase: "fix", primary: "codex", limit_text: LONG_LIMIT, error_message: nil)
      end
      assert_match(/explicit provider routing/, err)
    end
  end

  def test_decide_skips_when_reset_is_sooner_than_min_wait
    now = Time.now.utc
    _out, err = capture_io do
      assert_nil LimitFallback.decide(enabled_cfg, phase: "triage", primary: "codex",
                                                   limit_text: reset_hint(now + 600), error_message: nil, now: now)
    end
    assert_match(/min_wait_sec=3600/, err)
  end

  def test_decide_uses_fallback_for_long_or_absent_reset
    now = Time.now.utc
    long = LimitFallback.decide(enabled_cfg, phase: "triage", primary: "codex",
                                             limit_text: reset_hint(now + 2 * 86_400), error_message: nil, now: now)
    assert_equal %w[triage triage codex claude], [ long.phase, long.role, long.primary, long.fallback ]
    refute_nil long.retry_after

    absent = LimitFallback.decide(enabled_cfg, phase: "fix", primary: "codex",
                                               limit_text: nil, error_message: LIMIT_MESSAGE, role: "fix agent")
    assert_equal "fix agent", absent.role
    assert_nil absent.retry_after
    assert_equal LIMIT_MESSAGE, absent.limit_detail
  end

  def test_outcome_classifies_substitute_result
    assert_equal "used", LimitFallback.outcome(ok: true, limit_text: LONG_LIMIT, error_message: nil)
    assert_equal "limited", LimitFallback.outcome(ok: false, limit_text: LONG_LIMIT, error_message: nil)
    assert_equal "limited", LimitFallback.outcome(ok: false, limit_text: nil, error_message: LIMIT_MESSAGE)
    assert_equal "failed", LimitFallback.outcome(ok: false, limit_text: nil, error_message: "boom")
  end

  def test_min_wait_sec_falls_back_to_default_for_invalid_values
    assert_equal 3600, LimitFallback.min_wait_sec("min_wait_sec" => "soon")
    assert_equal 0, LimitFallback.min_wait_sec("min_wait_sec" => 0)
  end

  def test_record_writes_receipt_and_remembers_only_failures
    with_tmp_dir do |dir|
      decision = LimitFallback::Decision.new(phase: "fix", role: "fix", primary: "codex", fallback: "claude",
                                             retry_after: nil, limit_detail: "usage limit")
      _out, err = capture_io do
        LimitFallback.record!(task_folder: dir, pass: 2, decision: decision, outcome: "used")
        assert_empty LimitFallback.marker_attrs("fix")
        LimitFallback.record!(task_folder: dir, pass: 2, decision: decision, outcome: "limited", error: "again")
      end
      assert_match(/fix: codex hit a usage\/credit limit .* fallback claude used/, err)
      entries = receipt_entries(dir, pass: 2)
      assert_equal %w[used limited], entries.map { |entry| entry["outcome"] }
      assert_equal %w[codex claude fix], entries.first.values_at("primary", "fallback", "phase")
      assert_equal "again", entries.last["error"]
      assert_equal({ primary_agent: "codex", fallback_agent: "claude", fallback_outcome: "limited" },
                   LimitFallback.marker_attrs(:fix))
      LimitFallback.reset_run!
      assert_empty LimitFallback.marker_attrs("fix")
    end
  end

  def test_record_survives_receipt_write_failure
    with_tmp_dir do |dir|
      File.write(File.join(dir, "reviews"), "not a directory")
      decision = LimitFallback::Decision.new(phase: "ci", role: "ci", primary: "codex", fallback: "claude",
                                             retry_after: nil, limit_detail: "usage limit")
      entry = nil
      _out, err = capture_io do
        entry = LimitFallback.record!(task_folder: dir, pass: 1, decision: decision, outcome: "failed")
      end
      assert_equal "failed", entry["outcome"]
      assert_match(/could not record limit fallback receipt/, err)
    end
  end

  def test_reviewer_spec_is_a_distinct_agent_reviewer_on_the_fallback
    templates = Hive::Reviewers::ROUTED_REVIEW_TEMPLATES
    decision = LimitFallback::Decision.new(phase: "reviewers", role: "r", primary: "codex", fallback: "claude",
                                           retry_after: nil, limit_detail: "x")
    native = LimitFallback.reviewer_spec(
      { "name" => "codex-native", "kind" => "codex_review", "output_basename" => "codex-native",
        "model" => "gpt-5.5", "effort" => "high", "timeout_sec" => 60 },
      decision, templates: templates
    )
    assert_equal({ "name" => "codex-native-fallback-claude", "kind" => "agent", "agent" => "claude",
                   "output_basename" => "codex-native-fallback-claude", "skill" => "ce-code-review",
                   "prompt_template" => "reviewer_claude_ce_code_review.md.erb", "timeout_sec" => 60 },
                 native)

    routed = LimitFallback.reviewer_spec(
      { "name" => "c", "kind" => "agent", "agent" => "codex", "output_basename" => "c", "skill" => "ce-code-review",
        "prompt_template" => "reviewer_codex_ce_code_review.md.erb" },
      decision, templates: templates
    )
    assert_equal "reviewer_claude_ce_code_review.md.erb", routed["prompt_template"]

    custom = LimitFallback.reviewer_spec(
      { "name" => "c", "agent" => "codex", "output_basename" => "c", "skill" => "x", "prompt_template" => "mine.md.erb" },
      decision, templates: templates
    )
    assert_equal "mine.md.erb", custom["prompt_template"]
    assert_equal "x", custom["skill"]

    unmapped = LimitFallback.reviewer_spec(
      { "name" => "c", "agent" => "codex", "output_basename" => "c" },
      decision.with(fallback: "opencode"), templates: templates
    )
    assert_equal "reviewer_codex_ce_code_review.md.erb", unmapped["prompt_template"]
  end

  def test_reviewer_primary_and_fallback_cfg
    assert_equal "codex", LimitFallback.reviewer_primary("kind" => "codex_review")
    assert_equal "pi", LimitFallback.reviewer_primary("agent" => :pi)
    assert_nil LimitFallback.reviewer_primary({})
    cfg = { "models" => { "review_reviewers" => {} }, "review" => {} }
    assert_equal({ "review" => {} }, LimitFallback.fallback_cfg(cfg))
    plain = { "review" => {} }
    assert_same plain, LimitFallback.fallback_cfg(plain)
  end

  # --- reviewers phase -----------------------------------------------------

  class LimitedReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      Hive::Reviewers::Result.new(name: name, output_path: output_path, status: :error,
                                  error_message: LIMIT_MESSAGE, limit_text: spec["limit_text"] || LONG_LIMIT)
    end
  end

  class CrashingReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      Hive::Reviewers::Result.new(name: name, output_path: output_path, status: :error,
                                  error_message: "codex exited 1: segmentation fault")
    end
  end

  class OkReviewer < Hive::Reviewers::Base
    def run!(deadline: nil)
      ensure_reviews_dir!
      File.write(output_path, "## Low\n\n- [ ] #{name}\n")
      Hive::Reviewers::Result.new(name: name, output_path: output_path, status: :ok, error_message: nil)
    end
  end

  CODEX_SPEC = { "name" => "codex-ce-code-review", "kind" => "agent", "agent" => "codex",
                 "skill" => "ce-code-review", "output_basename" => "codex-ce-code-review",
                 "prompt_template" => "reviewer_codex_ce_code_review.md.erb" }.freeze
  CLAUDE_SPEC = { "name" => "claude-ce-code-review", "kind" => "agent", "agent" => "claude",
                  "skill" => "ce-code-review", "output_basename" => "claude-ce-code-review",
                  "prompt_template" => "reviewer_claude_ce_code_review.md.erb" }.freeze

  # Dispatch by spec name: name => adapter class. Records every dispatched
  # spec and the cfg it was dispatched with.
  def run_reviewers_with(cfg, dir, classes, specs: [ CODEX_SPEC, CLAUDE_SPEC ], **kwargs)
    cfg = cfg.merge("review" => cfg.fetch("review", {}).merge("reviewers" => specs))
    dispatched = []
    dispatch = lambda do |spec, ctx, cfg: nil|
      dispatched << [ spec, cfg ]
      classes.fetch(spec["name"]).new(spec, ctx)
    end
    result = nil
    published = []
    publish = ->(_task, _cfg, _pass, name, path) { published << [ name, File.basename(path) ] }
    err = nil
    with_replaced_singleton_method(Hive::Reviewers, :dispatch, dispatch) do
      with_replaced_singleton_method(Hive::Stages::Review, :publish_review_file, publish) do
        _out, err = capture_io do
          result = Hive::Stages::Review.run_reviewers(cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")),
                                                      **kwargs)
        end
      end
    end
    { result: result, dispatched: dispatched, published: published, err: err }
  end

  def test_reviewer_limit_uses_fallback_and_records_it
    with_tmp_dir do |dir|
      succeeded = []
      cfg = enabled_cfg(extra: { "models" => {} })
      run = run_reviewers_with(
        cfg, dir,
        { "codex-ce-code-review" => LimitedReviewer, "codex-ce-code-review-fallback-claude" => OkReviewer,
          "claude-ce-code-review" => OkReviewer },
        succeeded: succeeded
      )

      assert_equal :ok, run[:result]
      fallback_spec, fallback_cfg = run[:dispatched][1]
      assert_equal "claude", fallback_spec["agent"]
      refute fallback_cfg.key?("models"), "primary-provider model routes must not reach the substitute"
      assert File.exist?(File.join(dir, "reviews", "codex-ce-code-review-fallback-claude-01.md"))
      refute File.exist?(File.join(dir, "reviews", "errors-01.md")),
             "a successful substitute must not leave a reviewer_partial_failure record"
      assert_equal %w[codex-ce-code-review-fallback-claude claude-ce-code-review], succeeded
      assert_equal [ "codex-ce-code-review-fallback-claude", "codex-ce-code-review-fallback-claude-01.md" ],
                   run[:published].first
      entry = receipt_entries(dir).first
      assert_equal [ "reviewers", "reviewer codex-ce-code-review", "codex", "claude", "used",
                     "codex-ce-code-review-fallback-claude-01.md" ],
                   entry.values_at("phase", "role", "primary", "fallback", "outcome", "output")
      assert_match(/limit fallback: reviewer codex-ce-code-review: codex hit a usage\/credit limit/, run[:err])
    end
  end

  def test_reviewer_limit_without_option_is_unchanged
    with_tmp_dir do |dir|
      limit_texts = []
      run = run_reviewers_with({}, dir, { "codex-ce-code-review" => LimitedReviewer }, specs: [ CODEX_SPEC ],
                                                                                         limit_texts: limit_texts)

      assert_equal :all_failed_limit, run[:result]
      assert_equal 1, run[:dispatched].length
      assert_equal [ LONG_LIMIT ], limit_texts
      refute File.exist?(LimitFallback.receipt_path(dir, 1))
    end
  end

  def test_non_limit_reviewer_failure_does_not_fall_back
    with_tmp_dir do |dir|
      run = run_reviewers_with(enabled_cfg, dir,
                               { "codex-ce-code-review" => CrashingReviewer, "claude-ce-code-review" => OkReviewer })

      assert_equal :ok, run[:result]
      assert_equal %w[codex-ce-code-review claude-ce-code-review], run[:dispatched].map { |spec, _| spec["name"] }
      assert_match(/segmentation fault/, File.read(File.join(dir, "reviews", "errors-01.md")))
      refute File.exist?(LimitFallback.receipt_path(dir, 1))
    end
  end

  def test_fallback_reviewer_also_limited_keeps_limits_reached
    with_tmp_dir do |dir|
      limit_texts = []
      run = run_reviewers_with(
        enabled_cfg, dir,
        { "codex-ce-code-review" => LimitedReviewer, "codex-ce-code-review-fallback-claude" => LimitedReviewer },
        specs: [ CODEX_SPEC ], limit_texts: limit_texts
      )

      assert_equal :all_failed_limit, run[:result]
      assert_equal [ LONG_LIMIT, LONG_LIMIT ], limit_texts
      errors = File.read(File.join(dir, "reviews", "errors-01.md"))
      assert_includes errors, "[codex-ce-code-review] reviewer"
      assert_includes errors, "[codex-ce-code-review-fallback-claude] reviewer"
      assert_equal "limited", receipt_entries(dir).first["outcome"]
      assert_equal({ primary_agent: "codex", fallback_agent: "claude", fallback_outcome: "limited" },
                   LimitFallback.marker_attrs("reviewers"))
    end
  end

  def test_fallback_reviewer_generic_failure_is_recorded_as_failed
    with_tmp_dir do |dir|
      run = run_reviewers_with(
        enabled_cfg, dir,
        { "codex-ce-code-review" => LimitedReviewer, "codex-ce-code-review-fallback-claude" => CrashingReviewer },
        specs: [ CODEX_SPEC ]
      )

      assert_equal :all_failed_limit, run[:result]
      assert_equal "failed", receipt_entries(dir).first["outcome"]
    end
  end

  def test_short_reviewer_reset_waits_instead_of_falling_back
    with_tmp_dir do |dir|
      spec = CODEX_SPEC.merge("limit_text" => reset_hint(Time.now.utc + 600))
      run = run_reviewers_with(enabled_cfg, dir, { "codex-ce-code-review" => LimitedReviewer }, specs: [ spec ])

      assert_equal :all_failed_limit, run[:result]
      assert_equal 1, run[:dispatched].length
      assert_match(/waiting for reset instead of falling back to claude/, run[:err])
    end
  end

  def test_cooled_retry_reuses_fallback_output_and_removes_stale_ones
    with_tmp_dir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      reused = File.join(reviews, "codex-ce-code-review-fallback-claude-01.md")
      File.write(reused, "## Low\n\n- [ ] kept\n")
      stale = File.join(reviews, "claude-ce-code-review-fallback-codex-01.md")
      File.write(stale, "stale\n")
      reuse = { "codex-ce-code-review-fallback-claude" => Digest::SHA256.file(reused).hexdigest }
      succeeded = []
      cfg = enabled_cfg(agents: { "codex" => "claude", "claude" => "codex" })
      run = run_reviewers_with(cfg, dir, { "claude-ce-code-review" => OkReviewer },
                               reuse: reuse, succeeded: succeeded)

      assert_equal :ok, run[:result]
      assert_equal %w[claude-ce-code-review], run[:dispatched].map { |spec, _| spec["name"] }
      assert_equal %w[codex-ce-code-review-fallback-claude claude-ce-code-review], succeeded
      refute File.exist?(stale), "a stale substitute output must not reach triage beside a fresh primary review"
      assert_match(/reusing limit-fallback reviewer output/, run[:err])
    end
  end

  def test_wall_clock_exhausted_before_fallback_returns_wall_clock_exceeded
    with_tmp_dir do |dir|
      now = Time.now
      calls = 0
      exceeded = lambda do |_started, _max|
        calls += 1
        calls > 2
      end
      with_replaced_singleton_method(Hive::Stages::Review, :wall_clock_exceeded?, exceeded) do
        run = run_reviewers_with(
          enabled_cfg, dir, { "codex-ce-code-review" => LimitedReviewer }, specs: [ CODEX_SPEC ],
                                                                           started_at: now, max_wall_clock_sec: 60
        )
        assert_equal :wall_clock_exceeded, run[:result]
      end
    end
  end

  def test_reviewer_without_output_basename_never_falls_back
    with_tmp_dir do |dir|
      result = Hive::Reviewers::Result.new(name: "x", output_path: nil, status: :error,
                                           error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT)
      assert_nil Hive::Stages::Review.run_reviewer_limit_fallback(
        enabled_cfg, make_ctx(dir), { "name" => "x", "agent" => "codex" }, result,
        started_at: nil, max_wall_clock_sec: nil, specs_remaining: 1
      )
      assert_nil Hive::Stages::Review.reusable_limit_fallback_output(enabled_cfg, make_ctx(dir),
                                                                     { "agent" => "codex" }, {})
    end
  end

  # --- triage --------------------------------------------------------------

  def triage_result(status, limit_text: nil, error_message: nil, tampered: [])
    Hive::Stages::Review::Triage::Result.new(status: status, escalations_path: nil, error_message: error_message,
                                             tampered_files: tampered, limit_text: limit_text)
  end

  def run_triage(cfg, dir, results)
    seen = []
    triage = lambda do |cfg:, ctx:, limit_fallback: nil|
      seen << limit_fallback
      results.shift
    end
    result = nil
    with_replaced_singleton_method(Hive::Stages::Review::Triage, :run!, triage) do
      with_replaced_singleton_method(Hive::Stages::Review, :mark_working, ->(*_args, **_kwargs) { }) do
        capture_io do
          result = Hive::Stages::Review.run_triage_with_retries(
            cfg, make_ctx(dir), Task.new(dir, File.join(dir, "task.md")),
            pass: 1, started_at: Time.now, max_wall_clock_sec: 3600
          )
        end
      end
    end
    [ result, seen ]
  end

  def test_triage_limit_uses_fallback
    with_tmp_dir do |dir|
      ok = triage_result(:ok)
      limited = triage_result(:error, limit_text: LONG_LIMIT, error_message: LIMIT_MESSAGE)
      cfg = enabled_cfg.merge("review" => enabled_cfg["review"].merge("triage" => { "agent" => "codex" }))
      result, seen = run_triage(cfg, dir, [ limited, ok ])

      assert_same ok, result
      assert_nil seen.first
      assert_equal "claude", seen.last.fallback
      assert_equal "used", receipt_entries(dir).first["outcome"]
    end
  end

  def test_triage_fallback_limited_returns_primary_limit
    with_tmp_dir do |dir|
      limited = triage_result(:error, limit_text: LONG_LIMIT, error_message: LIMIT_MESSAGE)
      again = triage_result(:error, limit_text: LONG_LIMIT, error_message: LIMIT_MESSAGE)
      cfg = enabled_cfg.merge("review" => enabled_cfg["review"].merge("triage" => { "agent" => "codex" }))
      result, = run_triage(cfg, dir, [ limited, again ])

      assert_same limited, result
      assert_equal "limited", LimitFallback.marker_attrs("triage")[:fallback_outcome]
    end
  end

  def test_triage_fallback_tamper_is_surfaced
    with_tmp_dir do |dir|
      limited = triage_result(:error, limit_text: LONG_LIMIT, error_message: LIMIT_MESSAGE)
      tampered = triage_result(:tampered, error_message: "modified plan.md", tampered: [ "plan.md" ])
      cfg = enabled_cfg.merge("review" => enabled_cfg["review"].merge("triage" => { "agent" => "codex" }))
      result, = run_triage(cfg, dir, [ limited, tampered ])

      assert_same tampered, result
      assert_equal "failed", receipt_entries(dir).first["outcome"]
    end
  end

  def test_triage_limit_without_option_is_unchanged
    with_tmp_dir do |dir|
      limited = triage_result(:error, limit_text: LONG_LIMIT, error_message: LIMIT_MESSAGE)
      result, seen = run_triage({}, dir, [ limited ])

      assert_same limited, result
      assert_equal [ nil ], seen
    end
  end

  def test_triage_run_launches_fallback_profile_without_primary_model
    with_stage_dir do |dir|
      File.write(File.join(dir, "reviews", "codex-ce-code-review-01.md"), "## Nit\n- [ ] x: y\n")
      cfg = { "review" => { "triage" => { "agent" => "codex", "model" => "gpt-5.5", "bias" => "courageous" } } }
      decision = LimitFallback::Decision.new(phase: "triage", role: "triage", primary: "codex", fallback: "claude",
                                             retry_after: nil, limit_detail: "x")
      spawned = nil
      spawn = lambda do |_task, _cfg, **kwargs|
        spawned = kwargs
        kwargs.fetch(:agent_custody).call { { status: :error, error_message: "stop" } }
      end
      with_replaced_singleton_method(Hive::Stages::Base, :spawn_claude!, spawn) do
        Hive::Stages::Review::Triage.run!(cfg: cfg, ctx: make_ctx(dir), limit_fallback: decision)
      end

      assert_equal :claude, spawned.fetch(:profile).name
      assert_equal "review-triage-pass01-fallback-claude", spawned.fetch(:log_label)
      refute spawned.key?(:model), "the primary's model pin must not reach the substitute"
      refute spawned.key?(:routing_arguments)
    end
  end

  # --- fix / CI-fix spawn seams -------------------------------------------

  def fix_decision(phase)
    LimitFallback::Decision.new(phase: phase, role: phase, primary: "codex", fallback: "claude",
                                retry_after: nil, limit_detail: "x")
  end

  def test_review_fix_spawn_bypasses_pinned_identity_for_fallback
    with_stage_dir do |dir|
      task = Task.new(dir, File.join(dir, "task.md"), "t")
      def task.project_root = folder
      spawned = nil
      spawn = lambda do |_task, _cfg, **kwargs|
        spawned = kwargs
        { status: :ok }
      end
      identity_lookup = ->(*_args) { flunk "a fallback launch must not resolve the pinned identity" }
      with_replaced_singleton_method(Hive::Stages::Base, :implementation_stage_identity, identity_lookup) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_claude!, spawn) do
          Hive::Stages::Review.spawn_fix_agent(task, { "review" => { "fix" => { "agent" => "codex" } } }, make_ctx(dir),
                                               accepted: "- [x] fix", limit_fallback: fix_decision("fix"))
        end
      end

      assert_equal :claude, spawned.fetch(:profile).name
      assert_nil spawned.fetch(:implementation_stage)
      assert_nil spawned.fetch(:identity_arguments)
      assert_equal "review-fix-pass01-fallback-claude", spawned.fetch(:log_label)
    end
  end

  def test_fix_limit_fallback_decision_announces_pin_bypass
    with_tmp_dir do |dir|
      identity = Struct.new(:provider).new("codex")
      task = Task.new(dir, File.join(dir, "task.md"), "slug-x")
      result = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
      decision = nil
      _out, err = capture_io do
        decision = Hive::Stages::Review.fix_limit_fallback_decision(task, enabled_cfg, identity, result)
      end
      assert_equal "claude", decision.fallback
      assert_match(/bypassing codex pinned for slug-x's current input generation/, err)
      assert_nil Hive::Stages::Review.fix_limit_fallback_decision(task, {}, identity, result)
    end
  end

  def test_ci_fix_spawn_bypasses_pinned_identity_for_fallback
    with_stage_dir do |dir|
      spawned = nil
      spawn = lambda do |_task, _cfg, **kwargs|
        spawned = kwargs
        { status: :ok }
      end
      identity_lookup = ->(*_args) { flunk "a fallback launch must not resolve the pinned identity" }
      with_replaced_singleton_method(Hive::Stages::Base, :implementation_stage_identity, identity_lookup) do
        with_replaced_singleton_method(Hive::Stages::Base, :spawn_claude!, spawn) do
          Hive::Stages::Review::CiFix.spawn_fix_agent(
            cfg: { "review" => { "ci" => { "agent" => "codex" } } }, ctx: make_ctx(dir), command: "bin/ci",
            attempt: 1, max_attempts: 3, captured_output: "red", limit_fallback: fix_decision("ci")
          )
        end
      end

      assert_equal :claude, spawned.fetch(:profile).name
      assert_nil spawned.fetch(:implementation_stage)
      assert_equal "review-ci-fix-attempt01-fallback-claude", spawned.fetch(:log_label)
    end
  end

  def test_ci_limit_fallback_decision_announces_pin_bypass
    identity = Struct.new(:provider).new("codex")
    result = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
    decision = nil
    _out, err = capture_io do
      decision = Hive::Stages::Review::CiFix.limit_fallback_decision(enabled_cfg, identity, result)
    end
    assert_equal "claude", decision.fallback
    assert_match(/ci: bypassing codex pinned/, err)
    assert_nil Hive::Stages::Review::CiFix.limit_fallback_decision({}, identity, result)
  end

  def ci_cfg(dir, body, fallback: true)
    ci = File.join(dir, "fake-ci")
    File.write(ci, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, ci)
    cfg = { "review" => { "ci" => { "command" => ci, "max_attempts" => 2, "agent" => "codex" } },
            "timeout_sec" => { "review_ci" => 10 } }
    cfg["review"]["limit_fallback"] = enabled_cfg["review"]["limit_fallback"] if fallback
    cfg
  end

  def run_ci(cfg, dir, responses)
    seen = []
    spawn = lambda do |cfg:, ctx:, command:, attempt:, max_attempts:, captured_output:,
                      identity: nil, agent_custody:, limit_fallback: nil|
      seen << limit_fallback
      response = responses.shift
      agent_custody.call do
        response.call if response.respond_to?(:call)
        response.is_a?(Hash) ? response : { status: :ok }
      end
    end
    result = nil
    with_replaced_singleton_method(Hive::Stages::Base, :implementation_stage_identity, ->(*_args) { }) do
      with_replaced_singleton_method(Hive::Stages::Review::CiFix, :spawn_fix_agent, spawn) do
        capture_io { result = Hive::Stages::Review::CiFix.run!(cfg: cfg, ctx: make_ctx(dir)) }
      end
    end
    [ result, seen ]
  end

  def test_ci_fix_limit_uses_fallback
    with_stage_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, "reviews"))
      marker = File.join(dir, "fixed")
      cfg = ci_cfg(dir, %([ -f "#{marker}" ] && exit 0; echo red; exit 1))
      limited = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
      result, seen = run_ci(cfg, dir, [ limited, -> { File.write(marker, "ok") } ])

      assert_equal :green, result.status
      assert_equal [ nil, "claude" ], seen.map { |decision| decision&.fallback }
      assert_equal "used", receipt_entries(dir).first["outcome"]
    end
  end

  def test_ci_fix_fallback_also_limited_keeps_primary_limit
    with_stage_dir do |dir|
      cfg = ci_cfg(dir, "echo red; exit 1")
      limited = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
      again = { status: :error, error_message: "fallback crashed" }
      result, = run_ci(cfg, dir, [ limited, again ])

      assert_equal :error, result.status
      assert_equal LONG_LIMIT, result.limit_text
      assert_equal LIMIT_MESSAGE, result.error_message
      assert_equal "failed", receipt_entries(dir).first["outcome"]
      assert_equal "failed", LimitFallback.marker_attrs("ci")[:fallback_outcome]
    end
  end

  def test_ci_fix_fallback_limited_outcome
    with_stage_dir do |dir|
      cfg = ci_cfg(dir, "echo red; exit 1")
      limited = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
      result, = run_ci(cfg, dir, [ limited, limited.dup ])

      assert_equal :error, result.status
      assert_equal "limited", receipt_entries(dir).first["outcome"]
    end
  end

  def test_ci_fix_fallback_tamper_is_terminal
    with_stage_dir do |dir|
      plan = File.join(dir, "plan.md")
      File.write(plan, "plan\n")
      cfg = ci_cfg(dir, "echo red; exit 1")
      limited = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
      result, = run_ci(cfg, dir, [ limited, -> { File.write(plan, "tampered\n") } ])

      assert_equal :error, result.status
      assert_match(/modified protected files/, result.error_message)
    end
  end

  def test_ci_fix_limit_without_option_is_unchanged
    with_stage_dir do |dir|
      cfg = ci_cfg(dir, "echo red; exit 1", fallback: false)
      limited = { status: :error, error_message: LIMIT_MESSAGE, limit_text: LONG_LIMIT }
      result, seen = run_ci(cfg, dir, [ limited ])

      assert_equal :error, result.status
      assert_equal [ nil ], seen
      refute File.exist?(LimitFallback.receipt_path(dir, 1))
    end
  end
end
