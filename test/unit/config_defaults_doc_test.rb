# frozen_string_literal: true

require "test_helper"
require "hive/config"
require "hive/config_defaults_doc"

class ConfigDefaultsDocTest < Minitest::Test
  BEGIN_MARKER = "<!-- BEGIN GENERATED: Config::DEFAULTS -->"
  END_MARKER = "<!-- END GENERATED: Config::DEFAULTS -->"
  SAMPLE_DEFAULTS = {
    "zeta" => {
      "nested_second" => [ "first", "second" ],
      "nested_first" => { "enabled" => true }
    },
    "alpha" => nil
  }.freeze
  SAMPLE_REFERENCE = <<~'REFERENCE'
    ```ruby
    {"zeta" =>
      {"nested_second" => ["first", "second"],
       "nested_first" => {"enabled" => true}},
     "alpha" => nil}
    ```
  REFERENCE

  def test_generated_reference_has_fixed_readable_bytes_and_preserves_order
    reference = Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS)

    assert_equal SAMPLE_REFERENCE, reference
    assert_operator reference.index('"zeta"'), :<, reference.index('"alpha"')
    assert_operator reference.index('"nested_second"'), :<, reference.index('"nested_first"')
    assert reference.end_with?("\n")
    refute_includes reference, "\r"
  end

  def test_generated_reference_ignores_width_locale_terminal_and_repetition
    expected = Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS)
    renders = []

    %w[20 240].each do |columns|
      renders << with_environment("COLUMNS" => columns) do
        Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS)
      end
    end
    [ [ "C", "C" ], [ "C.UTF-8", "C.UTF-8" ] ].each do |lang, locale|
      renders << with_environment("LANG" => lang, "LC_ALL" => locale) do
        Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS)
      end
    end
    [ true, false ].each do |tty|
      renders << with_stdout_tty(tty) do
        Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS)
      end
    end
    3.times { renders << Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS) }

    renders.each { |rendered| assert_equal expected, rendered }
  end

  def test_render_replaces_only_validated_region_and_is_idempotent
    prefix = "\x00human prose\r\nkept exactly\n".b
    suffix = "trailing prose\r\n\xFF".b
    stale = "```ruby\r\n{\"stale\" => true}\r\n```\r\n"
    page = valid_page(prefix:, region: stale, suffix:)

    rendered = Hive::ConfigDefaultsDoc.render(page, defaults: SAMPLE_DEFAULTS)
    expected_region = "#{BEGIN_MARKER}\n#{SAMPLE_REFERENCE}#{END_MARKER}\n".b

    assert_equal prefix + expected_region + suffix, rendered
    assert_equal prefix, rendered.byteslice(0, prefix.bytesize)
    assert_equal suffix, rendered.byteslice(-suffix.bytesize, suffix.bytesize)
    assert_equal rendered, Hive::ConfigDefaultsDoc.render(rendered, defaults: SAMPLE_DEFAULTS)
  end

  def test_render_publishes_every_supplied_top_level_and_nested_default
    defaults = {
      "first" => { "array" => [ "one", { "deep" => 2 } ] },
      "second" => false
    }

    rendered = Hive::ConfigDefaultsDoc.render(valid_page, defaults:)

    %w[first array one deep second].each { |entry| assert_includes rendered, %Q{"#{entry}"} }
    assert_includes rendered, '"deep" => 2'
    assert_includes rendered, '"second" => false'
  end

  def test_render_rejects_every_malformed_marker_shape
    malformed_pages = {
      missing: "plain page\n",
      begin_only: "#{BEGIN_MARKER}\nbody\n",
      end_only: "#{END_MARKER}\n",
      duplicate_begin: "#{BEGIN_MARKER}\n#{BEGIN_MARKER}\nbody\n#{END_MARKER}\n",
      duplicate_end: "#{BEGIN_MARKER}\nbody\n#{END_MARKER}\n#{END_MARKER}\n",
      two_complete_pairs: "#{BEGIN_MARKER}\na\n#{END_MARKER}\n#{BEGIN_MARKER}\nb\n#{END_MARKER}\n",
      nested: "#{BEGIN_MARKER}\n#{BEGIN_MARKER}\nbody\n#{END_MARKER}\n#{END_MARKER}\n",
      reversed: "#{END_MARKER}\nbody\n#{BEGIN_MARKER}\n",
      reversed_plus_valid: "#{END_MARKER}\n#{BEGIN_MARKER}\nbody\n#{END_MARKER}\n",
      inline: "prefix #{BEGIN_MARKER}\nbody\n#{END_MARKER}\n",
      indented: "  #{BEGIN_MARKER}\nbody\n  #{END_MARKER}\n",
      altered: "<!-- BEGIN GENERATED Config::DEFAULTS -->\nbody\n<!-- END GENERATED Config::DEFAULTS -->\n",
      crlf_marker_lines: "#{BEGIN_MARKER}\r\nbody\r\n#{END_MARKER}\r\n",
      unterminated_end_line: "#{BEGIN_MARKER}\nbody\n#{END_MARKER}"
    }

    malformed_pages.each do |name, page|
      error = assert_raises(Hive::ConfigDefaultsDoc::InvalidRegionError, name.to_s) do
        Hive::ConfigDefaultsDoc.render(page, defaults: SAMPLE_DEFAULTS)
      end

      assert_match "exactly one standalone LF-terminated", error.message, name.to_s
    end
  end

  private

  def valid_page(prefix: "intro\n", region: "stale\n", suffix: "outro\n")
    "#{prefix}#{BEGIN_MARKER}\n#{region}#{END_MARKER}\n#{suffix}".b
  end

  def with_stdout_tty(value)
    original = $stdout
    output = StringIO.new
    output.define_singleton_method(:tty?) { value }
    $stdout = output
    yield
  ensure
    $stdout = original
  end

  def with_environment(overrides)
    original = overrides.to_h { |key, _value| [ key, ENV[key] ] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
