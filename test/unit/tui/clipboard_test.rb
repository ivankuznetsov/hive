require "test_helper"
require "hive/tui/clipboard"

class HiveTuiClipboardTest < Minitest::Test
  include HiveTestHelper

  PNG_BYTES = Hive::Tui::Clipboard::PNG_SIGNATURE + "payload".b

  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  class FakeKernel
    attr_reader :captures

    def initialize(commands: {}, captures: {}, files: {})
      @commands = commands
      @capture_responses = captures
      @files = files
      @captures = []
    end

    def command_available?(name, env:)
      @commands.fetch(name, false)
    end

    def capture3(argv, timeout:, max_bytes: nil)
      @captures << [ argv, timeout, max_bytes ]
      @capture_responses.fetch(argv.first) { [ +"".b, "", FakeStatus.new(false) ] }
    end

    def expand_path(path)
      File.expand_path(path)
    end

    def file_exist?(path)
      @files.key?(File.expand_path(path))
    end

    def file_file?(path)
      file = @files[File.expand_path(path)]
      file && file.fetch(:file, true)
    end

    def file_size(path)
      @files.fetch(File.expand_path(path)).fetch(:size)
    end

    def test_fixture_path(name)
      File.expand_path("../../../test/fixtures/composer/#{name}", __dir__)
    end
  end

  def fake_file(path, size: 12, file: true)
    { File.expand_path(path) => { size: size, file: file } }
  end

  def test_wayland_wl_paste_png_returns_image_bytes
    kernel = FakeKernel.new(
      commands: { "wl-paste" => true },
      captures: { "wl-paste" => [ PNG_BYTES, "", FakeStatus.new(true) ] }
    )

    result = Hive::Tui::Clipboard.probe(
      pasted_text: "",
      env: { "XDG_SESSION_TYPE" => "wayland", "PATH" => "/bin" },
      kernel: kernel
    )

    assert_equal :image_bytes, result.kind
    assert_equal PNG_BYTES, result.bytes
    assert_equal "png", result.ext
    assert_equal [ "wl-paste", "--type", "image/png", "--no-newline" ], kernel.captures.first.first
  end

  def test_wayland_wl_paste_failure_falls_through_to_none
    kernel = FakeKernel.new(
      commands: { "wl-paste" => true },
      captures: { "wl-paste" => [ +"".b, "no image", FakeStatus.new(false) ] }
    )

    result = Hive::Tui::Clipboard.probe(
      pasted_text: "/missing/screenshot.png",
      env: { "XDG_SESSION_TYPE" => "wayland", "PATH" => "/bin" },
      kernel: kernel
    )

    assert_equal :none, result.kind
  end

  def test_x11_xclip_png_returns_image_bytes
    kernel = FakeKernel.new(
      commands: { "xclip" => true },
      captures: { "xclip" => [ PNG_BYTES, "", FakeStatus.new(true) ] }
    )

    result = Hive::Tui::Clipboard.probe(
      pasted_text: "",
      env: { "XDG_SESSION_TYPE" => "", "DISPLAY" => ":0", "PATH" => "/bin" },
      kernel: kernel
    )

    assert_equal :image_bytes, result.kind
    assert_equal PNG_BYTES, result.bytes
    assert_equal [ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" ], kernel.captures.first.first
  end

  def test_pbpaste_text_falls_through_to_path_probe
    with_tmp_dir do |dir|
      path = File.join(dir, "shot.png")
      kernel = FakeKernel.new(
        commands: { "pbpaste" => true },
        captures: { "pbpaste" => [ "not image bytes", "", FakeStatus.new(true) ] },
        files: fake_file(path)
      )

      result = Hive::Tui::Clipboard.probe(
        pasted_text: path,
        env: { "PATH" => "/bin", "HIVE_TUI_FORCE_DARWIN" => "1" },
        kernel: kernel
      )

      assert_equal :image_file, result.kind
      assert_equal File.expand_path(path), result.path
      assert_equal "png", result.ext
    end
  end

  def test_pbpaste_is_guarded_to_darwin_only
    # On a non-Darwin host that happens to ship a `pbpaste` polyglot
    # script in PATH, the probe must NOT fire it. Without the darwin?
    # guard, `clipboard_command` would return `["pbpaste"]` and the
    # fake kernel would record a capture3 call — wasteful at best,
    # source of confused fallbacks at worst.
    kernel = FakeKernel.new(commands: { "pbpaste" => true })

    Hive::Tui::Clipboard.probe(
      pasted_text: "",
      env: { "PATH" => "/bin" },
      kernel: kernel
    )

    assert_empty kernel.captures,
      "non-Darwin probe must skip pbpaste even when the binary is on PATH"
  end

  def test_existing_png_path_returns_image_file
    with_tmp_dir do |dir|
      path = File.join(dir, "screenshot.png")
      kernel = FakeKernel.new(files: fake_file(path))

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :image_file, result.kind
      assert_equal File.expand_path(path), result.path
      assert_equal "png", result.ext
    end
  end

  def test_quoted_path_with_trailing_newline_is_detected
    with_tmp_dir do |dir|
      path = File.join(dir, "Screenshot.JPG")
      kernel = FakeKernel.new(files: fake_file(path))

      result = Hive::Tui::Clipboard.probe(
        pasted_text: "\"#{path}\"\n",
        env: { "PATH" => "" },
        kernel: kernel
      )

      assert_equal :image_file, result.kind
      assert_equal "jpg", result.ext
    end
  end

  def test_existing_txt_path_is_none
    with_tmp_dir do |dir|
      path = File.join(dir, "notes.txt")
      kernel = FakeKernel.new(files: fake_file(path))

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :none, result.kind
      assert Hive::Tui::Clipboard.non_image_file_path?(pasted_text: path, kernel: kernel)
    end
  end

  def test_existing_image_over_size_cap_surfaces_oversize_kind
    with_tmp_dir do |dir|
      path = File.join(dir, "huge.png")
      kernel = FakeKernel.new(
        files: fake_file(path, size: Hive::Tui::Clipboard::MAX_IMAGE_BYTES + 1)
      )

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :oversize_image, result.kind,
        "oversize image must surface as :oversize_image so callers can flash, " \
        "instead of falling through to :none and dropping into text/path probe"
    end
  end

  def test_clipboard_image_over_size_cap_surfaces_oversize_kind
    oversize = Hive::Tui::Clipboard::PNG_SIGNATURE + ("x".b * Hive::Tui::Clipboard::MAX_IMAGE_BYTES)
    kernel = FakeKernel.new(
      commands: { "wl-paste" => true },
      captures: { "wl-paste" => [ oversize, "", FakeStatus.new(true) ] }
    )

    result = Hive::Tui::Clipboard.probe(
      pasted_text: "",
      env: { "XDG_SESSION_TYPE" => "wayland", "PATH" => "/bin" },
      kernel: kernel
    )

    assert_equal :oversize_image, result.kind
  end

  def test_missing_clipboard_tools_and_missing_path_is_none
    kernel = FakeKernel.new(commands: {})

    result = Hive::Tui::Clipboard.probe(
      pasted_text: "/missing/nope.png",
      env: { "PATH" => "" },
      kernel: kernel
    )

    assert_equal :none, result.kind
    assert_empty kernel.captures
  end

  def test_non_png_clipboard_bytes_are_none
    kernel = FakeKernel.new(
      commands: { "wl-paste" => true },
      captures: { "wl-paste" => [ "text/html", "", FakeStatus.new(true) ] }
    )

    result = Hive::Tui::Clipboard.probe(
      pasted_text: "",
      env: { "XDG_SESSION_TYPE" => "wayland", "PATH" => "/bin" },
      kernel: kernel
    )

    assert_equal :none, result.kind
  end

  def test_fixture_clipboard_env_can_serve_sequence_for_e2e
    kernel = FakeKernel.new(
      files: {
        File.expand_path("../../../test/fixtures/composer/screenshot-1.png", __dir__) => { size: 1, file: true },
        File.expand_path("../../../test/fixtures/composer/screenshot-2.png", __dir__) => { size: 1, file: true }
      }
    )
    Hive::Tui::Clipboard.reset_test_clipboard!
    env = { "HIVE_TUI_TEST_CLIPBOARD" => "fixture://screenshot-1.png,screenshot-2.png", "PATH" => "" }

    first = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)
    second = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)

    assert_equal :image_file, first.kind
    assert_match(/screenshot-1\.png\z/, first.path)
    assert_equal :image_file, second.kind
    assert_match(/screenshot-2\.png\z/, second.path)
  ensure
    Hive::Tui::Clipboard.reset_test_clipboard!
  end

  # Path-traversal guard on the fixture-name parser must reject "/" and
  # ".." so a malicious HIVE_TUI_TEST_CLIPBOARD value can't escape the
  # test fixtures directory. The guard is defense-in-depth — the env
  # var is test-only — but it must not regress.
  def test_fixture_clipboard_rejects_path_traversal_names
    kernel = FakeKernel.new(files: {})
    Hive::Tui::Clipboard.reset_test_clipboard!
    env = { "HIVE_TUI_TEST_CLIPBOARD" => "fixture://../escape.png", "PATH" => "" }

    result = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)

    assert_equal :none, result.kind
  ensure
    Hive::Tui::Clipboard.reset_test_clipboard!
  end

  def test_fixture_clipboard_rejects_slash_in_names
    kernel = FakeKernel.new(files: {})
    Hive::Tui::Clipboard.reset_test_clipboard!
    env = { "HIVE_TUI_TEST_CLIPBOARD" => "fixture://nested/dir.png", "PATH" => "" }

    result = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)

    assert_equal :none, result.kind
  ensure
    Hive::Tui::Clipboard.reset_test_clipboard!
  end
end
