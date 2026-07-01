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
    prompt, output, summary_io = make_prompt("\n")

    assert_equal %w[claude codex], prompt.collect
    assert_match(/1\) claude \[default\]/, output.string)
    assert_match(/2\) codex \[default\]/, output.string)
    assert_match(/3\) pi/, output.string)
    assert_equal "", summary_io.string,
                 "interactive #collect must not write to summary_io"
  end

  def test_interactive_selection_writes_nothing_to_summary_io
    # The non-TTY path is the only one that emits a summary line; an
    # accidental summary write on the interactive path would otherwise go
    # uncaught (only the non-TTY test asserts summary content).
    prompt, _output, summary_io = make_prompt("claude,3\n")

    assert_equal %w[claude pi], prompt.collect
    assert_equal "", summary_io.string,
                 "interactive #collect must not write to summary_io"
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

  def test_closed_input_stream_degrades_to_non_interactive_defaults
    # A closed real IO answers respond_to?(:tty?) with true but raises
    # IOError on #tty?; #interactive? must treat that as non-interactive
    # and #collect must fall through to the defaults rather than crash.
    input = StringIO.new("")
    input.define_singleton_method(:tty?) { raise IOError, "closed stream" }
    output = StringIO.new
    summary_io = StringIO.new
    prompt = Hive::Commands::Setup::BackendPrompt.new(
      input: input, output: output, summary_io: summary_io, registered_agents: BACKENDS
    )

    refute prompt.interactive?
    assert_equal %w[claude codex], prompt.collect
    assert_equal "", output.string
    assert_match(/using default backends/, summary_io.string)
  end

  def test_registered_backends_filter_non_interactive_defaults
    prompt, output, summary_io = make_prompt("\n", tty: false, registered_agents: %w[claude])

    assert_equal %w[claude], prompt.collect
    assert_equal "", output.string
    assert_match(/claude/, summary_io.string)
    refute_match(/codex/, summary_io.string)
  end

  def test_registered_backends_filter_interactive_menu
    # The interactive (tty:true) path renders the menu; a restricted
    # registry must list only the registered subset, not the full
    # canonical set.
    prompt, output, summary_io = make_prompt("\n", tty: true, registered_agents: %w[claude])

    assert_equal %w[claude], prompt.collect
    assert_match(/1\) claude \[default\]/, output.string)
    refute_match(/codex/, output.string)
    refute_match(/pi/, output.string)
    assert_equal "", summary_io.string
  end

  def test_interactive_index_selects_from_filtered_backends
    # With a restricted registry, indices must address the DISPLAYED list
    # (@backends), not the canonical constant — "2" here is pi, not codex.
    prompt, = make_prompt("2\n", registered_agents: %w[claude pi])

    assert_equal %w[pi], prompt.collect
  end

  def test_accepts_symbol_registry_names
    # The AgentProfiles registry's native names are symbols; injecting them
    # directly must not raise — they are normalized to strings before the
    # canonical-order intersection.
    prompt, = make_prompt("\n", registered_agents: %i[claude codex pi])

    assert_equal %w[claude codex], prompt.collect
  end
end
