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

    def capture3(argv, timeout:)
      @captures << [ argv, timeout ]
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
        env: { "PATH" => "/bin" },
        kernel: kernel
      )

      assert_equal :image_file, result.kind
      assert_equal File.expand_path(path), result.path
      assert_equal "png", result.ext
    end
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

  def test_existing_image_over_size_cap_is_none
    with_tmp_dir do |dir|
      path = File.join(dir, "huge.png")
      kernel = FakeKernel.new(
        files: fake_file(path, size: Hive::Tui::Clipboard::MAX_IMAGE_BYTES + 1)
      )

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :none, result.kind
    end
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
end
