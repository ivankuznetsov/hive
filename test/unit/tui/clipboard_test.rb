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

  def test_probe_result_rejects_impossible_union_shape
    err = assert_raises(ArgumentError) do
      Hive::Tui::Clipboard::ProbeResult.new(
        kind: :image_bytes,
        bytes: nil,
        path: "/tmp/shot.png",
        ext: "png"
      )
    end

    assert_match(/image_bytes/, err.message)
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

  def test_clipboard_image_bytes_take_precedence_over_pasted_text_path
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

      assert_equal :image_bytes, result.kind,
        "OS clipboard image bytes are the primary paste source; pasted text paths are fallback"
      assert_equal PNG_BYTES, result.bytes
      refute_empty kernel.captures
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
  def test_probe_result_rejects_unknown_kind
    error = assert_raises(ArgumentError) do
      Hive::Tui::Clipboard::ProbeResult.new(kind: :surprise, bytes: nil, path: nil, ext: nil)
    end

    assert_match(/unknown probe result kind/, error.message)
  end

  def test_probe_clipboard_image_timeout_exception_returns_timeout_result
    kernel = Object.new
    kernel.define_singleton_method(:command_available?) { |_name, env:| true }
    kernel.define_singleton_method(:capture3) do |_argv, timeout:, max_bytes:|
      raise Timeout::Error, "slow clipboard"
    end

    result = Hive::Tui::Clipboard.probe_clipboard_image(
      env: { "XDG_SESSION_TYPE" => "wayland", "PATH" => "/bin" },
      kernel: kernel
    )

    assert_equal :clipboard_timeout, result.kind
  end

  def test_fixture_clipboard_clamps_to_last_fixture_by_default
    fixture_path = File.expand_path("../../../test/fixtures/composer/screenshot-1.png", __dir__)
    kernel = FakeKernel.new(files: { fixture_path => { size: 1, file: true } })
    Hive::Tui::Clipboard.reset_test_clipboard!
    env = { "HIVE_TUI_TEST_CLIPBOARD" => "fixture://screenshot-1.png", "PATH" => "" }

    first = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)
    second = Hive::Tui::Clipboard.probe(pasted_text: "", env: env, kernel: kernel)

    assert_equal :image_file, first.kind
    assert_equal :image_file, second.kind
    assert_equal first.path, second.path
  ensure
    Hive::Tui::Clipboard.reset_test_clipboard!
  end

  def test_webp_signature_accepts_riff_webp_header
    with_tmp_dir do |dir|
      path = File.join(dir, "shot.webp")
      kernel = FakeKernel.new(files: fake_file(path, head: "RIFFxxxxWEBPmore".b))

      result = Hive::Tui::Clipboard.probe(pasted_text: path, env: { "PATH" => "" }, kernel: kernel)

      assert_equal :image_file, result.kind
      assert_equal "webp", result.ext
      refute Hive::Tui::Clipboard.webp_signature?("RIFFshort".b)
    end
  end

  def test_default_shim_command_available_checks_path_entries
    with_tmp_dir do |dir|
      executable = File.join(dir, "wl-paste")
      File.write(executable, "#!/bin/sh\n")
      File.chmod(0o755, executable)

      assert Hive::Tui::Clipboard::DefaultShim.command_available?("wl-paste", env: { "PATH" => dir })
      refute Hive::Tui::Clipboard::DefaultShim.command_available?("xclip", env: { "PATH" => dir })
    end
  end

  def test_default_shim_capture3_success_and_timeout_paths
    out, err, status = Hive::Tui::Clipboard::DefaultShim.capture3(
      [ RbConfig.ruby, "-e", "STDOUT.write('abc'); STDERR.write('err')" ],
      timeout: 2,
      max_bytes: nil
    )

    assert_equal "abc", out
    assert_equal "err", err
    assert status.success?

    out, err, status = Hive::Tui::Clipboard::DefaultShim.capture3(
      [ RbConfig.ruby, "-e", "sleep 1" ],
      timeout: 0.05,
      max_bytes: 8
    )

    assert_equal "", out
    assert_equal "", err
    assert_same Hive::Tui::Clipboard::TIMEOUT_STATUS, status
  end

  def test_default_shim_read_capped_includes_one_overflow_byte_and_drains
    capped = Hive::Tui::Clipboard::DefaultShim.read_capped(StringIO.new("abcdef"), 2)
    uncapped = Hive::Tui::Clipboard::DefaultShim.read_capped(StringIO.new("xyz"), nil)

    assert_equal "abc", capped
    assert_equal "xyz", uncapped
  end

  def test_default_shim_file_helpers_read_head_and_fixture_base
    with_tmp_dir do |dir|
      path = File.join(dir, "head.bin")
      File.write(path, "abcdef")

      assert_equal File.expand_path(path), Hive::Tui::Clipboard::DefaultShim.expand_path(path)
      assert Hive::Tui::Clipboard::DefaultShim.file_exist?(path)
      assert Hive::Tui::Clipboard::DefaultShim.file_file?(path)
      assert_equal 6, Hive::Tui::Clipboard::DefaultShim.file_size(path)
      assert_equal "abc", Hive::Tui::Clipboard::DefaultShim.read_head(path, max_bytes: 3)
      assert_nil Hive::Tui::Clipboard::DefaultShim.read_head(File.join(dir, "missing"), max_bytes: 3)

      with_env("HIVE_TUI_TEST_CLIPBOARD_BASE" => dir) do
        assert_equal File.join(dir, "shot.png"), Hive::Tui::Clipboard::DefaultShim.test_fixture_path("shot.png")
      end
      with_env("HIVE_TUI_TEST_CLIPBOARD_BASE" => nil) do
        assert_nil Hive::Tui::Clipboard::DefaultShim.test_fixture_path("shot.png")
      end
    end
  end

  def test_default_shim_terminate_ignores_missing_process
    signals = []

    with_process_stubs(
      kill: ->(signal, pid) { signals << [ signal, pid ]; raise Errno::ESRCH },
      wait: ->(_pid) { flunk "wait should not run when TERM finds no process" }
    ) do
      assert_nil Hive::Tui::Clipboard::DefaultShim.send(:terminate, 12_345)
    end

    assert_equal [ [ "TERM", 12_345 ] ], signals
  end

  def test_default_shim_terminate_ignores_missing_process_during_initial_wait
    signals = []

    with_process_stubs(
      kill: ->(signal, pid) { signals << [ signal, pid ] },
      wait: ->(_pid) { raise Errno::ECHILD }
    ) do
      with_timeout_stub(->(_seconds, &block) { block.call }) do
        assert_nil Hive::Tui::Clipboard::DefaultShim.send(:terminate, 22_222)
      end
    end

    assert_equal [ [ "TERM", 22_222 ] ], signals
  end

  def test_default_shim_terminate_ignores_missing_process_after_timeout
    signals = []

    with_process_stubs(
      kill: lambda { |signal, pid|
        signals << [ signal, pid ]
        raise Errno::ECHILD if signal == "KILL"
      },
      wait: ->(_pid) { flunk "wait should be hidden behind timeout stub" }
    ) do
      with_timeout_stub(->(_seconds, &_block) { raise Timeout::Error }) do
        assert_nil Hive::Tui::Clipboard::DefaultShim.send(:terminate, 44_444)
      end
    end

    assert_equal [ [ "TERM", 44_444 ], [ "KILL", 44_444 ] ], signals
  end

  def test_default_shim_terminate_logs_unreaped_process_after_sigkill_timeout
    signals = []
    logs = []

    with_process_stubs(
      kill: ->(signal, pid) { signals << [ signal, pid ] },
      wait: ->(_pid) { flunk "wait should be hidden behind timeout stub" }
    ) do
      with_timeout_stub(->(_seconds, &_block) { raise Timeout::Error }) do
        with_debug_log_stub(->(topic, message = nil) { logs << [ topic, message ] }) do
          assert_nil Hive::Tui::Clipboard::DefaultShim.send(:terminate, 33_333)
        end
      end
    end

    assert_equal [ [ "TERM", 33_333 ], [ "KILL", 33_333 ] ], signals
    assert_equal 1, logs.size
    assert_equal "clipboard", logs.first.first
    assert_includes logs.first.last, "unreaped after SIGKILL+wait"
  end

  def with_process_stubs(kill:, wait:)
    original_kill = Process.method(:kill)
    original_wait = Process.method(:wait)
    Process.define_singleton_method(:kill, &kill)
    Process.define_singleton_method(:wait, &wait)
    yield
  ensure
    Process.define_singleton_method(:kill, &original_kill)
    Process.define_singleton_method(:wait, &original_wait)
  end

  def with_timeout_stub(callable)
    original_timeout = Timeout.method(:timeout)
    Timeout.define_singleton_method(:timeout, &callable)
    yield
  ensure
    Timeout.define_singleton_method(:timeout, &original_timeout)
  end

  def with_debug_log_stub(callable)
    original_log = Hive::Tui::Debug.method(:log)
    Hive::Tui::Debug.define_singleton_method(:log, &callable)
    yield
  ensure
    Hive::Tui::Debug.define_singleton_method(:log, &original_log)
  end

  def with_env(updates)
    old = updates.to_h { |key, _value| [ key, ENV.fetch(key, nil) ] }
    updates.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
