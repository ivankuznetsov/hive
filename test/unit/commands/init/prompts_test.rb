require "test_helper"
require "stringio"
require "hive/commands/init/prompts"

# Direct coverage for Hive::Commands::Init::Prompts. The class is the
# interactive first-run flow that `hive init` opens on TTY (and short-
# circuits to defaults off-TTY). All collaborators are injectable so this
# test never touches real STDIN/STDOUT or AgentProfiles registry.
#
# Plan: docs/plans/2026-05-04-001-feat-hive-init-interactive-prompts-plan.md (U3)
class InitPromptsTest < Minitest::Test
  AGENT_NAMES = %w[claude codex pi].freeze
  REVIEWER_NAMES = Hive::Commands::Init::Prompts::DEFAULT_REVIEWER_NAMES

  # Build prompts instance with a tty-flagged StringIO for interactive
  # tests, or a plain StringIO for non-TTY tests. `output` carries prompt
  # UI (defaults to stderr in production); `summary_io` carries the
  # non-TTY result line (defaults to stdout in production). Both are
  # injected as separate StringIOs so tests can assert against each
  # stream independently.
  def make_prompts(input_text, tty: true, registered_agents: AGENT_NAMES)
    input = StringIO.new(input_text)
    input.define_singleton_method(:tty?) { true } if tty
    output = StringIO.new
    summary_io = StringIO.new
    prompts = Hive::Commands::Init::Prompts.new(
      input: input,
      output: output,
      summary_io: summary_io,
      registered_agents: registered_agents
    )
    [ prompts, output, summary_io ]
  end

  # Build the canonical "all defaults" answer key set so tests can assert
  # against the same shape Init#call will pass to the ERB template.
  def all_defaults
    {
      "planning_agent" => "claude",
      "brainstorm_runtime" => "headless",
      "development_agent" => "codex",
      "enabled_reviewers" => REVIEWER_NAMES,
      "triage_bias" => "courageous",
      "budgets" => Hive::Commands::Init::Prompts::LIMIT_KEYS.each_with_object({}) do |k, h|
        h[k] = Hive::Config::DEFAULTS["budget_usd"][k]
      end,
      "timeouts" => Hive::Commands::Init::Prompts::LIMIT_KEYS.each_with_object({}) do |k, h|
        h[k] = Hive::Config::DEFAULTS["timeout_sec"][k]
      end,
      "daemon_enabled" => true,
      "daemon_autostart" => false
    }
  end

  # Helper to build an interactive input string. The flow asks:
  #   1. planning agent
  #   2. brainstorm runtime, only when planning agent is claude
  #   3. development agent
  #   4. reviewer multi-select
  #   5. triage bias
  #   6-14. nine limit prompts (brainstorm, plan, execute_implementation,
  #         open_pr, finalize, review_ci, review_triage, review_fix,
  #         review_browser)
  #  15. daemon enable Y/n            (added under ADR-024)
  #  16. daemon service autostart y/N
  #  17. confirmation Y/n
  # Each line is one answer; blank line = accept default.
  def interactive_input(planning: "", brainstorm_runtime: "", development: "", reviewers: "",
                        triage_bias: "", limits: ([ "" ] * 9), daemon: "", autostart: "", confirm: "")
    answers = [ planning ]
    answers << brainstorm_runtime if claude_planning_choice_for_helper?(planning)
    answers.concat([ development, reviewers, triage_bias, *limits, daemon, autostart, confirm ])
    answers.map { |a| "#{a}\n" }.join
  end

  def claude_planning_choice_for_helper?(planning)
    answer = planning.to_s.strip
    answer.empty? || answer.casecmp("claude").zero? || answer == "1"
  end

  # --- non-TTY: short-circuit to defaults ----------------------------------

  def test_non_tty_returns_recommended_defaults
    prompts, _output = make_prompts("", tty: false)
    answers = prompts.collect
    assert_equal all_defaults, answers
  end

  def test_non_tty_emits_one_line_summary_to_summary_io
    prompts, output, summary_io = make_prompts("", tty: false)
    prompts.collect

    # The machine-parseable result line goes to summary_io (stdout in
    # production); UI output stays empty in non-TTY mode.
    summary = summary_io.string
    assert_match(/hive: using defaults/, summary)
    assert_match(/planning=claude/, summary)
    assert_match(/brainstorm_runtime=headless/, summary)
    assert_match(/dev=codex/, summary)
    assert_match(/reviewers=all3/, summary)
    assert_match(/triage=courageous/, summary)
    assert_match(/limits=defaults/, summary)
    assert_equal 1, summary.lines.size,
                 "non-TTY mode must write exactly one summary line, no prompt copy"

    # Prompt UI stream must stay silent — non-TTY callers should see only
    # the structured summary, not menu choreography.
    assert_equal "", output.string,
                 "prompt UI stream (output:) must stay empty when non-TTY"
  end

  def test_non_tty_consumes_no_input
    # A scripted heredoc that pipes answers must not be silently misread:
    # off-TTY callers get defaults regardless of stream contents. The
    # contract is documented in the plan's Risks section.
    prompts, _output = make_prompts("codex\ncodex\n1,3\n", tty: false)
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"], "non-TTY must NOT consume the codex line"
    assert_equal "codex",  answers["development_agent"]
  end

  # --- happy path: all defaults ---------------------------------------------

  def test_interactive_all_defaults
    prompts, _output = make_prompts(interactive_input)
    answers = prompts.collect
    assert_equal all_defaults, answers
  end

  def test_interactive_all_defaults_summary_says_so
    prompts, output = make_prompts(interactive_input)
    prompts.collect
    assert_match(/limits\s+= all defaults/, output.string)
  end

  # --- planning / development agent: name, index, override -----------------

  def test_interactive_planning_agent_by_name
    prompts, _output = make_prompts(interactive_input(planning: "codex"))
    answers = prompts.collect
    assert_equal "codex", answers["planning_agent"]
    assert_equal "codex", answers["development_agent"], "dev default unchanged"
  end

  def test_interactive_planning_agent_by_index
    # "2" → second entry of registered_agents = codex
    prompts, _output = make_prompts(interactive_input(planning: "2"))
    answers = prompts.collect
    assert_equal "codex", answers["planning_agent"]
  end

  def test_interactive_planning_agent_unknown_reprompts_then_accepts
    # First answer is invalid → re-prompt; second answer is valid.
    # 18 reads total: planning (invalid + retry) + brainstorm runtime
    # + dev + reviewers + triage bias + 9 limits + daemon + autostart + confirm.
    # Each blank line accepts the default.
    raw = ([ "nonexistent", "claude" ] + ([ "" ] * 16)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(raw)
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
    assert_match(/unknown agent "nonexistent"/, output.string)
  end

  def test_interactive_planning_agent_index_out_of_range_reprompts
    raw = ([ "7", "claude" ] + ([ "" ] * 16)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(raw)
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
    assert_match(/unknown agent "7"/, output.string)
  end

  # --- brainstorm runtime: claude-only, name, index, validation ----------

  def test_interactive_brainstorm_runtime_blank_defaults_to_headless
    prompts, _output = make_prompts(interactive_input(brainstorm_runtime: ""))
    answers = prompts.collect
    assert_equal "headless", answers["brainstorm_runtime"]
  end

  def test_interactive_brainstorm_runtime_by_name
    prompts, _output = make_prompts(interactive_input(brainstorm_runtime: "tmux_interactive"))
    answers = prompts.collect
    assert_equal "tmux_interactive", answers["brainstorm_runtime"]
  end

  def test_interactive_brainstorm_runtime_by_index
    prompts, _output = make_prompts(interactive_input(brainstorm_runtime: "2"))
    answers = prompts.collect
    assert_equal "tmux_interactive", answers["brainstorm_runtime"]
  end

  def test_interactive_brainstorm_runtime_unknown_reprompts
    # Trailing 15: dev + reviewers + triage + 9 limits + daemon + autostart + confirm.
    raw = ([ "", "warm_pool", "2" ] + ([ "" ] * 15)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(raw)
    answers = prompts.collect
    assert_equal "tmux_interactive", answers["brainstorm_runtime"]
    assert_match(/unknown brainstorm runtime "warm_pool"/, output.string)
  end

  def test_interactive_brainstorm_runtime_index_out_of_range_reprompts
    raw = ([ "", "7", "2" ] + ([ "" ] * 15)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(raw)
    answers = prompts.collect
    assert_equal "tmux_interactive", answers["brainstorm_runtime"]
    assert_match(/unknown brainstorm runtime "7"/, output.string)
  end

  def test_interactive_brainstorm_runtime_skipped_for_non_claude_planning_agent
    prompts, output = make_prompts(interactive_input(planning: "codex", brainstorm_runtime: "tmux_interactive"))
    answers = prompts.collect
    assert_equal "codex", answers["planning_agent"]
    assert_equal "headless", answers["brainstorm_runtime"]
    refute_match(/Brainstorm runtime/, output.string)
  end

  def test_interactive_brainstorm_runtime_summary_shows_choice
    prompts, output = make_prompts(interactive_input(brainstorm_runtime: "tmux_interactive"))
    prompts.collect
    assert_match(/brainstorm_runtime\s+= tmux_interactive/, output.string)
  end

  # --- reviewer multi-select: indices, names, mixed ------------------------

  def test_interactive_reviewers_by_indices
    prompts, _output = make_prompts(interactive_input(reviewers: "1,3"))
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
  end

  def test_interactive_reviewers_by_names
    # Name-string contract — the prompt should accept literal reviewer
    # names too, so scripted automation survives template-default
    # reordering.
    prompts, _output = make_prompts(interactive_input(reviewers: "claude-ce-code-review,pr-review-toolkit"))
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
  end

  def test_interactive_reviewers_mixed_index_and_name
    prompts, _output = make_prompts(interactive_input(reviewers: "1,pr-review-toolkit"))
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
  end

  def test_interactive_reviewers_blank_accepts_all
    prompts, _output = make_prompts(interactive_input(reviewers: ""))
    answers = prompts.collect
    assert_equal REVIEWER_NAMES, answers["enabled_reviewers"]
  end

  def test_interactive_reviewers_out_of_range_index_reprompts
    # Build the input manually since interactive_input doesn't allow
    # multi-line reviewer answers cleanly. Leading blanks fill planning,
    # brainstorm_runtime, and dev; trailing values are triage bias, nine
    # limits, daemon, autostart, and confirm.
    input = ([ "", "", "", "7", "1,2" ] + ([ "" ] * 13)).join("\n") + "\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review codex-ce-code-review], answers["enabled_reviewers"]
    assert_match(/invalid index 7/, output.string)
  end

  def test_interactive_reviewers_unknown_name_reprompts
    input = ([ "", "", "", "nope", "1" ] + ([ "" ] * 13)).join("\n") + "\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review], answers["enabled_reviewers"]
    assert_match(/unknown reviewer "nope"/, output.string)
  end

  def test_interactive_reviewers_dedup_on_repeated_token
    prompts, _output = make_prompts(interactive_input(reviewers: "1,1,3"))
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
  end

  # --- triage bias: blank, name, index, validation ------------------------

  def test_interactive_triage_bias_blank_defaults_to_courageous
    prompts, _output = make_prompts(interactive_input(triage_bias: ""))
    answers = prompts.collect
    assert_equal "courageous", answers["triage_bias"]
  end

  def test_interactive_triage_bias_by_name
    prompts, _output = make_prompts(interactive_input(triage_bias: "safetyist"))
    answers = prompts.collect
    assert_equal "safetyist", answers["triage_bias"]
  end

  def test_interactive_triage_bias_by_index
    prompts, _output = make_prompts(interactive_input(triage_bias: "2"))
    answers = prompts.collect
    assert_equal "safetyist", answers["triage_bias"]
  end

  def test_interactive_triage_bias_unknown_reprompts
    input = ([ "", "", "", "", "bad", "2" ] + ([ "" ] * 12)).join("\n") + "\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal "safetyist", answers["triage_bias"]
    assert_match(/unknown triage bias "bad"/, output.string)
  end

  def test_interactive_triage_bias_index_out_of_range_reprompts
    input = ([ "", "", "", "", "7", "2" ] + ([ "" ] * 12)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(input)
    answers = prompts.collect
    assert_equal "safetyist", answers["triage_bias"]
    assert_match(/unknown triage bias "7"/, output.string)
  end

  def test_interactive_triage_bias_accepts_mixed_case_name
    prompts, _output, _summary = make_prompts(interactive_input(triage_bias: "Safetyist"))
    answers = prompts.collect
    assert_equal "safetyist", answers["triage_bias"]
  end

  def test_interactive_triage_bias_summary_shows_choice
    prompts, output = make_prompts(interactive_input(triage_bias: "safetyist"))
    prompts.collect
    assert_match(/triage_bias\s+= safetyist/, output.string)
  end

  # --- limits: blank, full pair, partial, validation -----------------------

  def test_interactive_limits_one_full_override
    # 9 limit prompts in order: brainstorm, plan, execute_implementation,
    # open_pr, finalize, review_ci, review_triage, review_fix, review_browser. Override
    # only `plan` (slot 2) → 30 budget, 900 timeout.
    limits = [ "", "30,900", "", "", "", "", "", "", "" ]
    prompts, _output = make_prompts(interactive_input(limits: limits))
    answers = prompts.collect
    assert_equal 30, answers["budgets"]["plan"]
    assert_equal 900, answers["timeouts"]["plan"]
    # Other keys stay at defaults
    assert_equal Hive::Config::DEFAULTS["budget_usd"]["brainstorm"], answers["budgets"]["brainstorm"]
    assert_equal Hive::Config::DEFAULTS["timeout_sec"]["execute_implementation"], answers["timeouts"]["execute_implementation"]
  end

  def test_interactive_limits_partial_pair_uses_default_for_missing_side
    # ",900" → keep budget default, override timeout
    limits = [ ",900" ] + ([ "" ] * 8)
    prompts, _output = make_prompts(interactive_input(limits: limits))
    answers = prompts.collect
    assert_equal Hive::Config::DEFAULTS["budget_usd"]["brainstorm"], answers["budgets"]["brainstorm"]
    assert_equal 900, answers["timeouts"]["brainstorm"]
  end

  def test_interactive_limits_zero_budget_reprompts
    # First answer 0,300 fails validation → re-prompt; second answer 10,600 accepted.
    # 5 leading blanks fill planning, brainstorm_runtime, dev, reviewers,
    # triage; trailing 11 blanks fill remaining 8 limits + daemon + autostart
    # + confirm.
    input = ([ "", "", "", "", "", "0,300", "10,600" ] + ([ "" ] * 11)).join("\n") + "\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal 10, answers["budgets"]["brainstorm"]
    assert_equal 600, answers["timeouts"]["brainstorm"]
    assert_match(/budget and timeout must be positive integers/, output.string)
  end

  def test_interactive_limits_malformed_format_reprompts
    # "30" without comma fails the <budget>,<timeout> shape → re-prompt
    input = ([ "", "", "", "", "", "30", "30,900" ] + ([ "" ] * 11)).join("\n") + "\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal 30, answers["budgets"]["brainstorm"]
    assert_equal 900, answers["timeouts"]["brainstorm"]
    assert_match(/expected <budget>,<timeout>/, output.string)
  end

  def test_interactive_limits_summary_lists_only_changed
    # Only `plan` changes → summary should mention plan but not the
    # unchanged entries.
    limits = [ "", "30,900", "", "", "", "", "", "", "" ]
    prompts, output = make_prompts(interactive_input(limits: limits))
    prompts.collect
    summary = output.string
    assert_match(/plan=30\/900s/, summary)
    refute_match(/brainstorm=/, summary, "unchanged keys must not appear in changed-list summary")
  end

  # --- daemon enable prompt (ADR-024) -------------------------------------

  def test_interactive_daemon_blank_defaults_to_enabled
    prompts, _output = make_prompts(interactive_input(daemon: ""))
    answers = prompts.collect
    assert_equal true, answers["daemon_enabled"]
  end

  def test_interactive_daemon_y_explicit_enabled
    prompts, _output = make_prompts(interactive_input(daemon: "y"))
    answers = prompts.collect
    assert_equal true, answers["daemon_enabled"]
  end

  def test_interactive_daemon_yes_word_enabled
    prompts, _output = make_prompts(interactive_input(daemon: "yes"))
    answers = prompts.collect
    assert_equal true, answers["daemon_enabled"]
  end

  def test_interactive_daemon_n_disables
    prompts, _output = make_prompts(interactive_input(daemon: "n"))
    answers = prompts.collect
    assert_equal false, answers["daemon_enabled"]
  end

  def test_interactive_daemon_no_word_disables
    prompts, _output = make_prompts(interactive_input(daemon: "no"))
    answers = prompts.collect
    assert_equal false, answers["daemon_enabled"]
  end

  def test_interactive_daemon_unknown_reprompts
    # First answer "maybe" is unrecognised → re-prompt; second answer y → enabled.
    # interactive_input feeds the full merged transcript (planning,
    # brainstorm_runtime, dev, reviewers, triage, 9 limits, daemon, autostart,
    # confirm). The "maybe" rejection consumes one extra read, so append "y"
    # so the daemon prompt accepts and the rest of the transcript advances.
    input = interactive_input(daemon: "maybe", confirm: "") + "y\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal true, answers["daemon_enabled"]
    assert_match(/please answer y or n/, output.string)
  end

  def test_interactive_daemon_summary_shows_choice
    prompts, output = make_prompts(interactive_input(daemon: "n"))
    prompts.collect
    summary = output.string
    assert_match(/daemon\s+= disabled/, summary)
  end

  def test_non_tty_default_includes_daemon_enabled_true
    prompts, _output, _summary = make_prompts("", tty: false)
    answers = prompts.collect
    assert_equal true, answers["daemon_enabled"],
                 "non-TTY callers should land on the same recommended default as TTY (Y)"
  end

  def test_non_tty_summary_includes_daemon_state
    prompts, _output, summary_io = make_prompts("", tty: false)
    prompts.collect
    assert_match(/daemon=enabled/, summary_io.string)
    assert_match(/daemon_autostart=disabled/, summary_io.string)
  end

  def test_interactive_daemon_autostart_blank_defaults_to_disabled
    prompts, _output = make_prompts(interactive_input(autostart: ""))
    answers = prompts.collect
    assert_equal false, answers["daemon_autostart"]
  end

  def test_interactive_daemon_autostart_y_enables
    prompts, _output = make_prompts(interactive_input(autostart: "y"))
    answers = prompts.collect
    assert_equal true, answers["daemon_autostart"]
  end

  def test_interactive_daemon_autostart_unknown_reprompts
    input = ([ "" ] * 15 + [ "maybe", "y", "" ]).join("\n") + "\n"
    prompts, output, _summary = make_prompts(input)
    answers = prompts.collect
    assert_equal true, answers["daemon_autostart"]
    assert_match(/please answer y or n/, output.string)
  end

  def test_non_tty_default_includes_triage_bias_courageous
    prompts, _output, _summary = make_prompts("", tty: false)
    answers = prompts.collect
    assert_equal "courageous", answers["triage_bias"]
  end

  # --- confirmation -------------------------------------------------------

  def test_interactive_confirm_n_raises_aborted
    prompts, _output = make_prompts(interactive_input(confirm: "n"))
    assert_raises(Hive::Commands::Init::Prompts::Aborted) { prompts.collect }
  end

  def test_interactive_confirm_no_word_raises_aborted
    prompts, _output = make_prompts(interactive_input(confirm: "no"))
    assert_raises(Hive::Commands::Init::Prompts::Aborted) { prompts.collect }
  end

  def test_interactive_confirm_blank_proceeds
    prompts, _output = make_prompts(interactive_input(confirm: ""))
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
  end

  def test_interactive_confirm_y_proceeds
    prompts, _output = make_prompts(interactive_input(confirm: "y"))
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
  end

  def test_interactive_confirm_unknown_reprompts
    # First confirm answer is junk → re-prompt; second is y.
    input = interactive_input(confirm: "huh") + "y\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
    assert_match(/please answer y or n/, output.string)
  end

  # --- end-to-end: every slot exercised -----------------------------------

  def test_interactive_end_to_end_all_overrides
    # planning=codex (by name), dev=2 (= codex by index), reviewers=1,3,
    # limits=plan-only override, confirm=y
    limits = [ "", "30,900", "", "", "", "", "", "", "" ]
    prompts, _output = make_prompts(
      interactive_input(planning: "codex", development: "2",
                        reviewers: "1,3", triage_bias: "safetyist",
                        limits: limits, confirm: "y")
    )
    answers = prompts.collect
    assert_equal "codex", answers["planning_agent"]
    assert_equal "codex", answers["development_agent"]
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
    assert_equal "safetyist", answers["triage_bias"]
    assert_equal 30,  answers["budgets"]["plan"]
    assert_equal 900, answers["timeouts"]["plan"]
    assert_equal Hive::Config::DEFAULTS["budget_usd"]["execute_implementation"],
                 answers["budgets"]["execute_implementation"]
  end

  # --- testability contract (R9) -------------------------------------------

  def test_uses_injected_registered_agents_not_live_registry
    # Inject a sentinel-only list that includes the recommended defaults
    # (the construction guard requires them to be members). Picking
    # `fake-bonus` as the planning override proves the class consults
    # the injected list, not Hive::AgentProfiles.registered_names.
    fake_agents = %w[claude codex fake-bonus]
    prompts, _output, _summary = make_prompts(
      interactive_input(planning: "fake-bonus"),
      registered_agents: fake_agents
    )
    answers = prompts.collect
    assert_equal "fake-bonus", answers["planning_agent"]
    assert_equal "codex", answers["development_agent"]
  end

  def test_interactive_predicate_reflects_input_tty
    p_tty, _ = make_prompts("", tty: true)
    p_pipe, _ = make_prompts("", tty: false)
    assert p_tty.interactive?
    refute p_pipe.interactive?
  end

  # --- EOF / Ctrl-D handling (ce-code-review F3) ---------------------------

  def test_eof_at_confirmation_raises_aborted_not_silent_yes
    # Truncate the input transcript right before confirmation. read_line
    # must distinguish nil-from-gets (EOF) from an empty line and bubble
    # Aborted up the stack rather than silently confirming.
    inputs = ([ "" ] * 15).join("\n") + "\n"  # 15 blank reads, then EOF
    prompts, _output, _summary = make_prompts(inputs)
    assert_raises(Hive::Commands::Init::Prompts::Aborted) { prompts.collect }
  end

  def test_eof_mid_planning_prompt_raises_aborted
    prompts, _output, _summary = make_prompts("")  # immediate EOF
    assert_raises(Hive::Commands::Init::Prompts::Aborted) { prompts.collect }
  end

  # --- Case-insensitive matching parity (ce-code-review F9) ----------------

  def test_planning_agent_accepts_mixed_case_name
    prompts, _output, _summary = make_prompts(interactive_input(planning: "CODEX"))
    answers = prompts.collect
    assert_equal "codex", answers["planning_agent"]
  end

  def test_reviewers_accept_mixed_case_names
    prompts, _output, _summary = make_prompts(interactive_input(reviewers: "Claude-CE-Code-Review,PR-Review-Toolkit"))
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
  end

  # Comma-only input must not silently render an empty reviewers: list —
  # that would produce an invalid YAML key (parses to nil) which
  # validate_reviewers! rejects on the next `hive run`. Re-prompt instead.
  def test_reviewers_comma_only_reprompts
    # Leading values default planning/brainstorm-runtime/development agents.
    # Trailing values are triage bias, nine limits, daemon, autostart, and confirm.
    input = ([ "", "", "", ",", "1" ] + ([ "" ] * 13)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review], answers["enabled_reviewers"]
    assert_match(/no reviewer tokens/, output.string)
  end

  def test_reviewers_whitespace_only_reprompts
    input = ([ "", "", "", "  ,  ,  ", "2" ] + ([ "" ] * 13)).join("\n") + "\n"
    prompts, output, _summary = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[codex-ce-code-review], answers["enabled_reviewers"]
    assert_match(/no reviewer tokens/, output.string)
  end

  # --- Construction guards (pr-review-toolkit type-design feedback) -------

  def test_initialize_raises_on_empty_registered_agents
    err = assert_raises(ArgumentError) do
      Hive::Commands::Init::Prompts.new(
        input: StringIO.new, output: StringIO.new, summary_io: StringIO.new,
        registered_agents: []
      )
    end
    assert_match(/registered_agents must be non-empty/, err.message)
  end

  def test_initialize_raises_when_default_agents_not_in_registry
    # Inject a registry that lacks the recommended defaults — the prompt's
    # blank-input fallback would otherwise return 'claude'/'codex' which
    # downstream Config validation would reject as unregistered.
    err = assert_raises(ArgumentError) do
      Hive::Commands::Init::Prompts.new(
        input: StringIO.new, output: StringIO.new, summary_io: StringIO.new,
        registered_agents: %w[other-agent]
      )
    end
    assert_match(/default agents not in registered_agents/, err.message)
    assert_match(/claude/, err.message)
    assert_match(/codex/, err.message)
  end
end
