require "test_helper"
require "hive/commands/setup/backend_prompt"

class SetupBackendPromptTest < Minitest::Test
  BACKENDS = %w[claude codex pi].freeze

  def make_prompt(input_text, tty: true, registered_agents: BACKENDS)
    input = StringIO.new(input_text)
    input.define_singleton_method(:tty?) { true } if tty
    output = StringIO.new
    summary_io = StringIO.new
    prompt = Hive::Commands::Setup::BackendPrompt.new(
      input: input,
      output: output,
      summary_io: summary_io,
      registered_agents: registered_agents
    )
    [ prompt, output, summary_io ]
  end

  def test_non_tty_uses_claude_codex_defaults
    prompt, output, summary_io = make_prompt("", tty: false)

    assert_equal %w[claude codex], prompt.collect
    assert_equal "", output.string
    assert_match(/using default backends/, summary_io.string)
    assert_match(/claude, codex/, summary_io.string)
    refute_match(/pi/, summary_io.string)
  end

  def test_interactive_blank_uses_default_selection
    prompt, output = make_prompt("\n")

    assert_equal %w[claude codex], prompt.collect
    assert_match(/1\) claude \[default\]/, output.string)
    assert_match(/2\) codex \[default\]/, output.string)
    assert_match(/3\) pi/, output.string)
  end

  def test_interactive_accepts_numbers_and_returns_backend_order
    prompt, = make_prompt("3,1\n")

    assert_equal %w[claude pi], prompt.collect
  end

  def test_interactive_accepts_names_case_insensitively_and_dedupes
    prompt, = make_prompt("PI,claude,pi\n")

    assert_equal %w[claude pi], prompt.collect
  end

  def test_interactive_accepts_mixed_names_and_numbers
    prompt, = make_prompt("claude,3\n")

    assert_equal %w[claude pi], prompt.collect
  end

  def test_zero_index_reprompts
    # `index >= 1` stops "0" from selecting @backends[-1] (= pi); exercise
    # the false branch of that guard so dropping it would fail here.
    prompt, output = make_prompt("0\nclaude\n")

    assert_equal %w[claude], prompt.collect
    assert_match(/unknown backend selection "0"/, output.string)
  end

  def test_out_of_range_index_reprompts
    # `index <= @backends.size` rejects a number past the listing.
    prompt, output = make_prompt("9\nclaude\n")

    assert_equal %w[claude], prompt.collect
    assert_match(/unknown backend selection "9"/, output.string)
  end

  def test_whitespace_only_answer_uses_default_selection
    # read_line's .strip turns a spaces-only line into "", so #collect takes
    # the blank-Enter default path instead of reprompting.
    prompt, = make_prompt("   \n")

    assert_equal %w[claude codex], prompt.collect
  end

  def test_collect_returns_frozen_selection
    prompt, = make_prompt("claude,3\n")

    assert prompt.collect.frozen?, "BackendPrompt#collect must return a frozen array"
  end

  def test_unknown_token_reprompts
    prompt, output = make_prompt("ghost\n1,3\n")

    assert_equal %w[claude pi], prompt.collect
    assert_match(/unknown backend selection "ghost"/, output.string)
  end

  def test_token_stripping_to_empty_reprompts
    # "," is non-blank (so it bypasses the blank-default path) but every
    # token strips away, so resolve_selection returns nil and re-prompts.
    prompt, output = make_prompt(",\nclaude\n")

    assert_equal %w[claude], prompt.collect
    assert_match(/unknown backend selection ","/, output.string)
  end

  def test_empty_registered_agents_raises
    err = assert_raises(ArgumentError) { make_prompt("", registered_agents: []) }
    assert_match(/at least one setup backend/, err.message)
  end

  def test_non_intersecting_registered_agents_raises
    err = assert_raises(ArgumentError) { make_prompt("", registered_agents: %w[ghost]) }
    assert_match(/at least one setup backend/, err.message)
  end

  def test_no_default_backend_registered_raises
    err = assert_raises(ArgumentError) { make_prompt("", registered_agents: %w[pi]) }
    assert_match(/at least one default backend/, err.message)
  end

  def test_eof_raises_aborted
    prompt, = make_prompt("", tty: true)

    err = assert_raises(Hive::Commands::Setup::BackendPrompt::Aborted) { prompt.collect }
    assert_match(/EOF/, err.message)
  end

  def test_registered_backends_filter_prompt_choices
    prompt, output, summary_io = make_prompt("\n", tty: false, registered_agents: %w[claude])

    assert_equal %w[claude], prompt.collect
    assert_equal "", output.string
    assert_match(/claude/, summary_io.string)
    refute_match(/codex/, summary_io.string)
  end
end
