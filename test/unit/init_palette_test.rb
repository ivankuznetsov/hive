require "test_helper"
require "hive/commands/init"

class InitPaletteTest < Minitest::Test
  Palette = Hive::Commands::Init::Palette

  def test_color_disabled_returns_plain_text
    p = Palette.new(color: false)
    assert_equal "x", p.green("x")
    assert_equal "x", p.cyan("x")
    assert_equal "x", p.bold("x")
    assert_equal "x", p.dim("x")
    assert_equal "x", p.bold_cyan("x")
  end

  def test_color_enabled_wraps_with_ansi_codes
    p = Palette.new(color: true)
    assert_equal "\e[32mx\e[0m",   p.green("x")
    assert_equal "\e[36mx\e[0m",   p.cyan("x")
    assert_equal "\e[1mx\e[0m",    p.bold("x")
    assert_equal "\e[2mx\e[0m",    p.dim("x")
    assert_equal "\e[1;36mx\e[0m", p.bold_cyan("x")
  end

  def test_for_disables_color_on_non_tty_io
    p = Palette.for(StringIO.new)
    assert_equal "x", p.green("x")
  end

  def test_for_enables_color_on_tty_io_when_no_color_unset
    with_no_color(nil) do
      p = Palette.for(tty_io)
      assert_equal "\e[32mx\e[0m", p.green("x")
    end
  end

  def test_for_treats_empty_no_color_as_unset
    with_no_color("") do
      p = Palette.for(tty_io)
      assert_equal "\e[32mx\e[0m", p.green("x")
    end
  end

  def test_for_disables_color_when_no_color_set
    with_no_color("1") do
      p = Palette.for(tty_io)
      assert_equal "x", p.green("x")
    end
  end

  private

  def tty_io
    Class.new do
      def tty?; true; end
    end.new
  end

  def with_no_color(value)
    prior = ENV["NO_COLOR"]
    ENV["NO_COLOR"] = value
    yield
  ensure
    ENV["NO_COLOR"] = prior
  end
end
