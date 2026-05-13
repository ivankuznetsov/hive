require "open3"
require "timeout"
require "rbconfig"

require "hive"
require "hive/tui/debug"

module Hive
  module Tui
    module Clipboard
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      MAX_IMAGE_BYTES = 10 * 1024 * 1024
      IMAGE_EXTENSIONS = %w[png jpg jpeg gif webp].freeze
      COMMAND_TIMEOUT_SECONDS = 2.0

      ProbeResult = Data.define(:kind, :bytes, :path, :ext)
      # Minimal stand-in for `Process::Status` that only implements
      # `success?`. Surfaced when the clipboard subprocess hits
      # `Timeout::Error` and the wait_thr never produced a real Status.
      # Callers must NOT rely on `exitstatus`, `signaled?`, or any other
      # Process::Status method against this value — the
      # `method_missing` below raises a typed error that points at this
      # comment so a future caller probing it gets a breadcrumb rather
      # than a bare `NoMethodError`.
      TIMEOUT_STATUS = Object.new.tap do |o|
        o.define_singleton_method(:success?) { false }
        o.define_singleton_method(:respond_to_missing?) { |_name, _priv = false| false }
        o.define_singleton_method(:method_missing) do |name, *_args, &_block|
          raise NoMethodError,
            "Clipboard::TIMEOUT_STATUS only implements #success?; " \
            "callers must not probe ##{name} (see TIMEOUT_STATUS comment in clipboard.rb)"
        end
      end.freeze

      NONE = ProbeResult.new(kind: :none, bytes: nil, path: nil, ext: nil).freeze
      OVERSIZE_IMAGE = ProbeResult.new(kind: :oversize_image, bytes: nil, path: nil, ext: "png").freeze

      module_function

      def probe(pasted_text:, env: ENV, kernel: DefaultShim)
        test_result = probe_test_clipboard(env: env, kernel: kernel)
        return test_result if test_result.kind != :none

        clipboard_result = probe_clipboard_image(env: env, kernel: kernel)
        return clipboard_result if clipboard_result.kind != :none

        probe_image_file(pasted_text: pasted_text, kernel: kernel)
      end

      def probe_image_file(pasted_text:, kernel: DefaultShim)
        path = normalized_path(pasted_text)
        return NONE if path.empty?

        expanded = kernel.expand_path(path)
        return NONE unless kernel.file_exist?(expanded) && kernel.file_file?(expanded)

        ext = File.extname(expanded).delete_prefix(".").downcase
        return NONE unless IMAGE_EXTENSIONS.include?(ext)

        size = kernel.file_size(expanded).to_i
        return NONE unless size.positive?
        return OVERSIZE_IMAGE if size > MAX_IMAGE_BYTES

        ProbeResult.new(kind: :image_file, bytes: nil, path: expanded, ext: ext)
      end

      def non_image_file_path?(pasted_text:, kernel: DefaultShim)
        path = normalized_path(pasted_text)
        return false if path.empty?

        expanded = kernel.expand_path(path)
        return false unless kernel.file_exist?(expanded) && kernel.file_file?(expanded)

        ext = File.extname(expanded).delete_prefix(".").downcase
        !IMAGE_EXTENSIONS.include?(ext)
      end

      def normalized_path(text)
        path = text.to_s.strip
        return "" if path.empty?

        if path.length >= 2 && %w[" '].include?(path[0]) && path[-1] == path[0]
          path = path[1...-1]
        end
        path
      end

      def probe_clipboard_image(env:, kernel:)
        argv = clipboard_command(env: env, kernel: kernel)
        return NONE if argv.nil?

        out, _err, status = kernel.capture3(argv, timeout: COMMAND_TIMEOUT_SECONDS, max_bytes: MAX_IMAGE_BYTES + 1)
        return NONE unless status_success?(status)

        bytes = out.to_s.b
        return NONE if bytes.empty?
        # The streaming read in DefaultShim#capture3 stops at
        # MAX_IMAGE_BYTES + 1 — anything that hit the cap is rejected
        # here so an oversize clipboard payload neither inflates memory
        # nor falls through into text/path probes downstream.
        return OVERSIZE_IMAGE if bytes.bytesize > MAX_IMAGE_BYTES
        return NONE unless bytes.start_with?(PNG_SIGNATURE)

        ProbeResult.new(kind: :image_bytes, bytes: bytes, path: nil, ext: "png")
      rescue Timeout::Error => e
        Hive::Tui::Debug.log("clipboard", "probe timed out: #{e.class}: #{e.message}")
        NONE
      end

      def clipboard_command(env:, kernel:)
        if env.fetch("XDG_SESSION_TYPE", "").downcase == "wayland" &&
           kernel.command_available?("wl-paste", env: env)
          return [ "wl-paste", "--type", "image/png", "--no-newline" ]
        end

        if !env.fetch("DISPLAY", "").empty? && kernel.command_available?("xclip", env: env)
          return [ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" ]
        end

        # macOS-only: `pbpaste` returns clipboard *text*, not PNG bytes,
        # so this branch is currently a no-op for image probing (the
        # caller will fall through to text/path probe). The branch is
        # kept under the Darwin guard so a Linux box that happens to
        # have a polyglot `pbpaste` script in PATH does not get fired.
        # When a real macOS image-paste path lands (e.g. `osascript -e
        # 'the clipboard as «class PNGf»'`), wire it here.
        return [ "pbpaste" ] if darwin?(env) && kernel.command_available?("pbpaste", env: env)

        nil
      end

      # @api private (test-only)
      # When `HIVE_TUI_TEST_CLIPBOARD=fixture://a.png,b.png,c.png` is
      # set, successive calls to `probe` serve fixture files from the
      # caller's directory in order. The advance counter
      # (`@test_clipboard_index`) is process-global module state; it
      # clamps at the last fixture (intentional — a smoke test that
      # configures 2 fixtures and pastes 3 times deliberately re-uses
      # fixture #2 for the third paste) and is reset via
      # `reset_test_clipboard!` between tests. No thread safety:
      # callers using this feature must coordinate externally.
      def probe_test_clipboard(env:, kernel:)
        raw = env.fetch("HIVE_TUI_TEST_CLIPBOARD", nil).to_s
        return NONE unless raw.start_with?("fixture://")

        names = raw.delete_prefix("fixture://").split(",")
        index = @test_clipboard_index.to_i
        @test_clipboard_index = index + 1
        # Clamp at the last fixture so a smoke test that configures 2
        # fixtures and pastes 3 times reuses the last fixture rather
        # than raising. Tests that need a strict sequence should
        # configure enough fixtures up front.
        name = names[[ index, names.size - 1 ].min].to_s
        return NONE if name.empty? || name.include?("/") || name.include?("..")

        fixture = kernel.test_fixture_path(name)
        return NONE if fixture.nil?

        probe_image_file(pasted_text: fixture, kernel: kernel)
      end

      # @api private (test-only)
      # Reset the fixture-clipboard advance counter so a fresh test run
      # serves the first configured fixture. Production code should
      # never call this; it exists so unit tests can avoid leaking the
      # module-level `@test_clipboard_index` across test ordering.
      def reset_test_clipboard!
        @test_clipboard_index = 0
      end

      def status_success?(status)
        status.respond_to?(:success?) ? status.success? : false
      end

      def darwin?(env)
        host = RbConfig::CONFIG["host_os"].to_s.downcase
        return true if host.include?("darwin")

        # In tests the shim runs against a synthetic env; allow callers
        # to opt in via HIVE_TUI_FORCE_DARWIN=1 without touching RbConfig.
        env.fetch("HIVE_TUI_FORCE_DARWIN", "").to_s == "1"
      end

      # The set of kernel-shim methods the Clipboard module reaches for
      # — file probing, subprocess capture, and test fixture lookup —
      # are isolated here so tests can swap in a FakeKernel that
      # records calls and synthesises responses. Production code
      # ALWAYS goes through the shim; do not reintroduce direct
      # `File.exist?` / `Open3.popen3` calls in this module, or the
      # test seam will silently degrade.
      module DefaultShim
        module_function

        def command_available?(name, env:)
          paths = env.fetch("PATH", "").split(File::PATH_SEPARATOR)
          paths.any? do |dir|
            path = File.join(dir, name)
            File.file?(path) && File.executable?(path)
          end
        end

        # Run argv under a wall-clock timeout, streaming stdout into a
        # buffer that stops growing once `max_bytes` is reached so a
        # huge clipboard payload cannot exhaust memory. Returns
        # `[out_bytes, err_bytes, status]`. On `Timeout::Error` returns
        # `["".b, "timeout", TIMEOUT_STATUS]` after killing the child.
        def capture3(argv, timeout:, max_bytes: nil)
          Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
            stdin.close
            begin
              out = +"".b
              err = +"".b
              status = Timeout.timeout(timeout) do
                out = read_capped(stdout, max_bytes)
                err = stderr.read.to_s.b
                wait_thr.value
              end
              [ out, err, status ]
            rescue Timeout::Error
              terminate(wait_thr.pid)
              [ +"".b, "timeout", TIMEOUT_STATUS ]
            end
          end
        end

        def read_capped(io, max_bytes)
          return io.read.to_s.b if max_bytes.nil?

          buf = +"".b
          while buf.bytesize < max_bytes
            chunk = io.read(max_bytes - buf.bytesize)
            break if chunk.nil? || chunk.empty?

            buf << chunk.b
          end
          # One extra byte beyond the cap lets the caller observe
          # "cap exceeded" via `bytesize > max_bytes`.
          extra = io.read(1)
          buf << extra.b unless extra.nil?
          # Drain the rest of stdout into a discard buffer so the
          # child isn't blocked writing to a full pipe — without
          # this, `wait_thr.value` deadlocks on oversize payloads
          # until `Timeout` fires, and the caller mis-classifies an
          # oversize clipboard as `:none` instead of `OVERSIZE_IMAGE`.
          loop do
            more = io.read(4096)
            break if more.nil? || more.empty?
          end
          buf
        end

        def terminate(pid)
          Process.kill("TERM", pid)
          Timeout.timeout(0.2) { Process.wait(pid) }
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        rescue Timeout::Error
          Process.kill("KILL", pid)
          Process.wait(pid)
          # Second clause catches re-raises from the SIGKILL+Process.wait
          # path above — collapsing the two clauses into one would let
          # an ESRCH/ECHILD from the kill path escape and re-surface as
          # a clipboard probe failure. Keep them distinct.
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def expand_path(path)
          File.expand_path(path)
        end

        def file_exist?(path)
          File.exist?(path)
        end

        def file_file?(path)
          File.file?(path)
        end

        def file_size(path)
          File.size(path)
        end

        # Resolve a fixture name against an opt-in base directory.
        # `HIVE_TUI_TEST_CLIPBOARD_BASE` is the operator-controlled
        # path (typically set by the integration test to its
        # `test/fixtures/composer/` directory). Production code
        # without the env var returns nil so `lib/` carries NO
        # hard-coded `test/` path references.
        def test_fixture_path(name)
          base = ENV.fetch("HIVE_TUI_TEST_CLIPBOARD_BASE", "")
          return nil if base.empty?

          File.join(base, name)
        end
      end
    end
  end
end
