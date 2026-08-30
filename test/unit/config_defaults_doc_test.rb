# frozen_string_literal: true

require "test_helper"
require "hive/config"
require "hive/config_defaults_doc"

class ConfigDefaultsDocTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
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
  MALFORMED_PAGES = {
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
  }.freeze

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
      renders << with_env("COLUMNS" => columns) do
        Hive::ConfigDefaultsDoc.generated_reference(SAMPLE_DEFAULTS)
      end
    end
    [ [ "C", "C" ], [ "C.UTF-8", "C.UTF-8" ] ].each do |lang, locale|
      renders << with_env("LANG" => lang, "LC_ALL" => locale) do
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
    MALFORMED_PAGES.each do |name, page|
      error = assert_raises(Hive::ConfigDefaultsDoc::InvalidRegionError, name.to_s) do
        Hive::ConfigDefaultsDoc.render(page, defaults: SAMPLE_DEFAULTS)
      end

      assert_match "exactly one standalone LF-terminated", error.message, name.to_s
    end
  end

  def test_regenerate_writes_exact_rendered_bytes_and_reports_change
    with_tmp_dir do |root|
      original = valid_page(region: "stale\n")
      path = write_wiki_page(root, original)
      expected = Hive::ConfigDefaultsDoc.render(original, defaults: SAMPLE_DEFAULTS)

      assert_equal true, Hive::ConfigDefaultsDoc.regenerate(project_root: root, defaults: SAMPLE_DEFAULTS)
      assert_equal expected, File.binread(path)
    end
  end

  def test_regenerate_reports_no_change_without_writing_or_touching_metadata
    with_tmp_dir do |root|
      current = Hive::ConfigDefaultsDoc.render(valid_page, defaults: SAMPLE_DEFAULTS)
      path = write_wiki_page(root, current)
      before = File.stat(path)
      forbid_write = ->(*) { flunk "no-op regeneration must not call File.binwrite" }

      changed = with_replaced_singleton_method(File, :binwrite, forbid_write) do
        Hive::ConfigDefaultsDoc.regenerate(project_root: root, defaults: SAMPLE_DEFAULTS)
      end

      after = File.stat(path)
      assert_equal false, changed
      assert_equal current, File.binread(path)
      assert_equal [ before.mtime, before.ctime, before.size ], [ after.mtime, after.ctime, after.size ]
    end
  end

  def test_regenerate_rejects_malformed_pages_before_any_write
    with_tmp_dir do |root|
      MALFORMED_PAGES.each do |name, malformed|
        path = write_wiki_page(root, malformed)
        before = File.binread(path)
        forbid_write = ->(*) { flunk "#{name}: invalid page must not call File.binwrite" }

        with_replaced_singleton_method(File, :binwrite, forbid_write) do
          assert_raises(Hive::ConfigDefaultsDoc::InvalidRegionError, name.to_s) do
            Hive::ConfigDefaultsDoc.regenerate(project_root: root, defaults: SAMPLE_DEFAULTS)
          end
        end

        assert_equal before, File.binread(path), name.to_s
      end
    end
  end

  def test_read_only_full_page_check_detects_stale_and_malformed_content
    stale = valid_page(region: "stale\n")
    current = Hive::ConfigDefaultsDoc.render(stale, defaults: SAMPLE_DEFAULTS)
    forbid_write = ->(*) { flunk "drift verification must not write" }

    with_replaced_singleton_method(File, :binwrite, forbid_write) do
      assert_equal current, Hive::ConfigDefaultsDoc.render(current, defaults: SAMPLE_DEFAULTS)
      refute_equal stale, Hive::ConfigDefaultsDoc.render(stale, defaults: SAMPLE_DEFAULTS)
      assert_raises(Hive::ConfigDefaultsDoc::InvalidRegionError) do
        Hive::ConfigDefaultsDoc.render(MALFORMED_PAGES.fetch(:two_complete_pairs), defaults: SAMPLE_DEFAULTS)
      end
    end
  end

  def test_maintainer_script_delegates_without_rendering_or_writing_policy
    script_path = File.join(ROOT, "script", "generate-config-defaults-doc")
    script = File.binread(script_path)

    assert_equal 1, script.scan("Hive::ConfigDefaultsDoc.regenerate").length
    refute_match(/PP|BEGIN_MARKER|END_MARKER|binwrite|generated_reference/, script)
    assert File.executable?(script_path)
  end

  private

  def valid_page(prefix: "intro\n", region: "stale\n", suffix: "outro\n")
    "#{prefix}#{BEGIN_MARKER}\n#{region}#{END_MARKER}\n#{suffix}".b
  end

  def write_wiki_page(root, content)
    path = File.join(root, Hive::ConfigDefaultsDoc::WIKI_PAGE)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
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

end
