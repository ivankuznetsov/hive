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

  # Per-extension head bytes used when a fake_file does not supply
  # explicit `:head` content. Keeps existing tests passing with the
  # new signature-check probe gate without forcing every call site to
  # spell out magic bytes.
  DEFAULT_FAKE_HEADS = {
    "png" => "\x89PNG\r\n\x1a\n".b + "\x00".b * 8,
    "jpg" => "\xFF\xD8\xFF".b + "\x00".b * 13,
    "jpeg" => "\xFF\xD8\xFF".b + "\x00".b * 13,
    "gif" => "GIF89a".b + "\x00".b * 10,
    "webp" => "RIFF\x00\x00\x00\x00WEBP".b + "\x00".b * 4
  }.freeze

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

    def read_head(path, max_bytes:)
      file = @files[File.expand_path(path)]
      return nil if file.nil?

      explicit = file[:head]
      return explicit.b[0, max_bytes] if explicit

      ext = File.extname(path).delete_prefix(".").downcase
      default = DEFAULT_FAKE_HEADS[ext]
      default ? default[0, max_bytes] : nil
    end

    def test_fixture_path(name)
      File.expand_path("../../../test/fixtures/composer/#{name}", __dir__)
    end
  end

  def fake_file(path, size: 12, file: true, head: nil)
    entry = { size: size, file: file }
    entry[:head] = head if head
    { File.expand_path(path) => entry }
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
        env: { "PATH" => "/bin", "HIVE_TUI_TEST_FORCE_DARWIN" => "1" },
        kernel: kernel
      )

      assert_equal :image_file, result.kind
      assert_equal File.expand_path(path), result.path
      assert_equal "png", result.ext
    end
  end

  def test_legacy_force_darwin_env_is_ignored
    # The pre-pass-4 env var `HIVE_TUI_FORCE_DARWIN` was reachable
    # from a user shell and would force a wasted `pbpaste` subprocess
    # on Linux. Only the namespaced `HIVE_TUI_TEST_FORCE_DARWIN`
    # opt-in is honoured.
    kernel = FakeKernel.new(commands: { "pbpaste" => true })

    Hive::Tui::Clipboard.probe(
      pasted_text: "",
      env: { "PATH" => "/bin", "HIVE_TUI_FORCE_DARWIN" => "1" },
      kernel: kernel
    )

    assert_empty kernel.captures,
      "legacy HIVE_TUI_FORCE_DARWIN must not force the pbpaste branch on Linux"
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

  def test_fixture_clipboard_strict_mode_fails_on_overflow_instead_of_clamping
    fixture_path = File.expand_path("../../../test/fixtures/composer/screenshot-1.png", __dir__)
    kernel = FakeKernel.new(files: { fixture_path => { size: 1, file: true } })
    Hive::Tui::Clipboard.reset_test_clipboard!
    env = {
      "HIVE_TUI_TEST_CLIPBOARD" => "fixture://screenshot-1.png",
      "HIVE_TUI_TEST_CLIPBOARD_STRICT" => "1",
      "PATH" => ""
    }

    first = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)
    second = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)

    assert_equal :image_file, first.kind
    assert_equal :none, second.kind,
      "strict mode must NOT clamp at the last fixture on overflow"
  ensure
    Hive::Tui::Clipboard.reset_test_clipboard!
  end

  def test_timeout_status_dual_branch_pin
    status = Hive::Tui::Clipboard::TIMEOUT_STATUS

    # `success?` is the only method TIMEOUT_STATUS implements; callers
    # check it directly without `respond_to?`-probing.
    refute status.success?
    # `respond_to?` returns false for everything else so cautious
    # callers can short-circuit cleanly.
    refute status.respond_to?(:exitstatus),
      "TIMEOUT_STATUS must report it does NOT implement Process::Status methods"
    refute status.respond_to?(:signaled?)
    # And direct calls raise NoMethodError (typed sentinel — a future
    # refactor of the timeout shape should not silently flip these
    # branches).
    assert_raises(NoMethodError) { status.exitstatus }
    assert_raises(NoMethodError) { status.signaled? }
  end

  def test_drag_drop_non_image_short_circuits_clipboard_probe
    # R13: pasted_text resolves to a non-image file; the OS clipboard
    # branch must not stage a stale image bytes payload behind it.
    with_tmp_dir do |dir|
      path = File.join(dir, "notes.txt")
      kernel = FakeKernel.new(
        commands: { "wl-paste" => true },
        captures: { "wl-paste" => [ PNG_BYTES, "", FakeStatus.new(true) ] },
        files: fake_file(path)
      )

      result = Hive::Tui::Clipboard.probe(
        pasted_text: path,
        env: { "XDG_SESSION_TYPE" => "wayland", "PATH" => "/bin" },
        kernel: kernel
      )

      assert_equal :none, result.kind,
        "non-image drag-drop path must NOT fall through to OS clipboard"
      assert_empty kernel.captures,
        "non-image drag-drop path must NOT spawn wl-paste"
    end
  end

  def test_empty_image_file_surfaces_empty_image_kind
    with_tmp_dir do |dir|
      path = File.join(dir, "blank.png")
      kernel = FakeKernel.new(files: fake_file(path, size: 0))

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :empty_image, result.kind,
        "0-byte image file must surface so caller can flash 'image file is empty'"
    end
  end

  def test_misnamed_image_with_bogus_bytes_is_treated_as_non_image
    # `.png` extension but the file head is "POOP" — neither PNG nor
    # any other accepted signature. probe must return :none so the
    # caller's `non_image_file_path?` branch flashes drag-drop refusal.
    with_tmp_dir do |dir|
      path = File.join(dir, "lying.png")
      kernel = FakeKernel.new(
        files: { File.expand_path(path) => { size: 4, file: true, head: "POOP".b } }
      )

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :none, result.kind
      assert Hive::Tui::Clipboard.non_image_file_path?(pasted_text: path, kernel: kernel),
        "misnamed image must report as non-image so the caller flashes drag-drop refusal"
    end
  end

  def test_jpeg_signature_check_accepts_real_jpeg_head
    with_tmp_dir do |dir|
      path = File.join(dir, "shot.jpg")
      kernel = FakeKernel.new(files: fake_file(path))

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :image_file, result.kind
      assert_equal "jpg", result.ext
    end
  end
end
