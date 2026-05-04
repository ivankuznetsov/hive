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
      "development_agent" => "codex",
      "enabled_reviewers" => REVIEWER_NAMES,
      "budgets" => Hive::Commands::Init::Prompts::LIMIT_KEYS.each_with_object({}) do |k, h|
        h[k] = Hive::Config::DEFAULTS["budget_usd"][k]
      end,
      "timeouts" => Hive::Commands::Init::Prompts::LIMIT_KEYS.each_with_object({}) do |k, h|
        h[k] = Hive::Config::DEFAULTS["timeout_sec"][k]
      end
    }
  end

  # Helper to build an interactive input string. The flow asks:
  #   1. planning agent
  #   2. development agent
  #   3. reviewer multi-select
  #   4-11. eight limit prompts (brainstorm, plan, execute_implementation,
  #         pr, review_ci, review_triage, review_fix, review_browser)
  #  12. confirmation Y/n
  # Each line is one answer; blank line = accept default.
  def interactive_input(planning: "", development: "", reviewers: "",
                        limits: ([ "" ] * 8), confirm: "")
    [ planning, development, reviewers, *limits, confirm ].map { |a| "#{a}\n" }.join
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
    assert_match(/dev=codex/, summary)
    assert_match(/reviewers=all3/, summary)
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
    # 13 reads total: planning (invalid + retry) + dev + reviewers
    # + 8 limits + confirm. Each blank line accepts the default.
    raw = "nonexistent\nclaude\n" + ([ "" ] * 11).join("\n") + "\n"
    prompts, output, _summary = make_prompts(raw)
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
    assert_match(/unknown agent "nonexistent"/, output.string)
  end

  def test_interactive_planning_agent_index_out_of_range_reprompts
    raw = "7\nclaude\n" + ([ "" ] * 11).join("\n") + "\n"
    prompts, output, _summary = make_prompts(raw)
    answers = prompts.collect
    assert_equal "claude", answers["planning_agent"]
    assert_match(/unknown agent "7"/, output.string)
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
    raw = ([ "", "" ] + [ "7\n1,2\n" ] + ([ "" ] * 9)).join("\n")
    # Build the input manually since interactive_input doesn't allow
    # multi-line reviewer answers cleanly.
    input = "\n\n7\n1,2\n" + (([ "" ] * 8) + [ "" ]).join("\n") + "\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review codex-ce-code-review], answers["enabled_reviewers"]
    assert_match(/invalid index 7/, output.string)
  end

  def test_interactive_reviewers_unknown_name_reprompts
    input = "\n\nnope\n1\n" + (([ "" ] * 8) + [ "" ]).join("\n") + "\n"
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

  # --- limits: blank, full pair, partial, validation -----------------------

  def test_interactive_limits_one_full_override
    # 8 limit prompts in order: brainstorm, plan, execute_implementation,
    # pr, review_ci, review_triage, review_fix, review_browser. Override
    # only `plan` (slot 2) → 30 budget, 900 timeout.
    limits = [ "", "30,900", "", "", "", "", "", "" ]
    prompts, _output = make_prompts(interactive_input(limits: limits))
    answers = prompts.collect
    assert_equal 30, answers["budgets"]["plan"]
    assert_equal 900, answers["timeouts"]["plan"]
    # Other 7 keys stay at defaults
    assert_equal Hive::Config::DEFAULTS["budget_usd"]["brainstorm"], answers["budgets"]["brainstorm"]
    assert_equal Hive::Config::DEFAULTS["timeout_sec"]["execute_implementation"], answers["timeouts"]["execute_implementation"]
  end

  def test_interactive_limits_partial_pair_uses_default_for_missing_side
    # ",900" → keep budget default, override timeout
    limits = [ ",900" ] + ([ "" ] * 7)
    prompts, _output = make_prompts(interactive_input(limits: limits))
    answers = prompts.collect
    assert_equal Hive::Config::DEFAULTS["budget_usd"]["brainstorm"], answers["budgets"]["brainstorm"]
    assert_equal 900, answers["timeouts"]["brainstorm"]
  end

  def test_interactive_limits_zero_budget_reprompts
    # First answer 0,300 fails validation → re-prompt; second answer 10,600 accepted
    input = "\n\n\n0,300\n10,600\n" + ([ "" ] * 7).join("\n") + "\n\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal 10, answers["budgets"]["brainstorm"]
    assert_equal 600, answers["timeouts"]["brainstorm"]
    assert_match(/budget and timeout must be positive integers/, output.string)
  end

  def test_interactive_limits_malformed_format_reprompts
    # "30" without comma fails the <budget>,<timeout> shape → re-prompt
    input = "\n\n\n30\n30,900\n" + ([ "" ] * 7).join("\n") + "\n\n"
    prompts, output = make_prompts(input)
    answers = prompts.collect
    assert_equal 30, answers["budgets"]["brainstorm"]
    assert_equal 900, answers["timeouts"]["brainstorm"]
    assert_match(/expected <budget>,<timeout>/, output.string)
  end

  def test_interactive_limits_summary_lists_only_changed
    # Only `plan` changes → summary should mention plan but not the
    # 7 unchanged entries.
    limits = [ "", "30,900", "", "", "", "", "", "" ]
    prompts, output = make_prompts(interactive_input(limits: limits))
    prompts.collect
    summary = output.string
    assert_match(/plan=30\/900s/, summary)
    refute_match(/brainstorm=/, summary, "unchanged keys must not appear in changed-list summary")
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
    limits = [ "", "30,900", "", "", "", "", "", "" ]
    prompts, _output = make_prompts(
      interactive_input(planning: "codex", development: "2",
                        reviewers: "1,3", limits: limits, confirm: "y")
    )
    answers = prompts.collect
    assert_equal "codex", answers["planning_agent"]
    assert_equal "codex", answers["development_agent"]
    assert_equal %w[claude-ce-code-review pr-review-toolkit], answers["enabled_reviewers"]
    assert_equal 30,  answers["budgets"]["plan"]
    assert_equal 900, answers["timeouts"]["plan"]
    assert_equal Hive::Config::DEFAULTS["budget_usd"]["execute_implementation"],
                 answers["budgets"]["execute_implementation"]
  end

  # --- testability contract (R9) -------------------------------------------

  def test_uses_injected_registered_agents_not_live_registry
    # Inject a sentinel-only list. Result must reflect it, proving the
    # class never reaches into Hive::AgentProfiles directly.
    fake_agents = %w[fake-a fake-b]
    prompts, _output = make_prompts(
      interactive_input(planning: "fake-b", development: "fake-a"),
      registered_agents: fake_agents
    )
    answers = prompts.collect
    assert_equal "fake-b", answers["planning_agent"]
    assert_equal "fake-a", answers["development_agent"]
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
    inputs = ([ "" ] * 11).join("\n") + "\n"  # 12 blank reads, then EOF
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
    input = "\n\n,\n1\n" + (([ "" ] * 8) + [ "" ]).join("\n") + "\n"
    prompts, output, _summary = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[claude-ce-code-review], answers["enabled_reviewers"]
    assert_match(/no reviewer tokens/, output.string)
  end

  def test_reviewers_whitespace_only_reprompts
    input = "\n\n  ,  ,  \n2\n" + (([ "" ] * 8) + [ "" ]).join("\n") + "\n"
    prompts, output, _summary = make_prompts(input)
    answers = prompts.collect
    assert_equal %w[codex-ce-code-review], answers["enabled_reviewers"]
    assert_match(/no reviewer tokens/, output.string)
  end
end
