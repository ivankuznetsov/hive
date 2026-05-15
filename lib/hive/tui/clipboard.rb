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

      # Magic-byte signatures for accepted on-disk image formats. The
      # extension is a hint, not a guarantee; a file named `.png` with
      # arbitrary contents otherwise slips through `IMAGE_EXTENSIONS`
      # straight into the rich-submit copy path.
      IMAGE_SIGNATURES = {
        "png" => [ PNG_SIGNATURE ].freeze,
        # JPEG: SOI marker `FFD8FF`.
        "jpg" => [ "\xFF\xD8\xFF".b.freeze ].freeze,
        "jpeg" => [ "\xFF\xD8\xFF".b.freeze ].freeze,
        # GIF87a / GIF89a.
        "gif" => [ "GIF87a".b.freeze, "GIF89a".b.freeze ].freeze,
        # RIFF....WEBP — first 4 bytes are "RIFF", bytes 8..11 are "WEBP".
        # The probe uses a custom check (see `webp_signature?`).
        "webp" => [].freeze
      }.freeze

      ProbeResult = Data.define(:kind, :bytes, :path, :ext) do
        def initialize(kind:, bytes:, path:, ext:)
          clean_ext = self.class.clean_ext(ext)
          validate_shape!(kind, bytes, path, clean_ext)
          super(kind: kind, bytes: bytes, path: path, ext: clean_ext)
        end

        def validate_shape!(kind, bytes, path, ext)
          case kind
          when :none, :empty_image, :clipboard_timeout
            raise ArgumentError, "#{kind} probe result must not carry payload" unless bytes.nil? && path.nil? && ext.nil?
          when :oversize_image
            raise ArgumentError, "oversize image probe result must carry only ext" unless bytes.nil? && path.nil? && present?(ext)
          when :image_bytes
            unless bytes.respond_to?(:bytesize) && bytes.bytesize.positive? && path.nil? && present?(ext)
              raise ArgumentError, "image_bytes probe result requires non-empty bytes and ext"
            end
          when :image_file
            raise ArgumentError, "image_file probe result requires path and ext" unless bytes.nil? && present?(path) && present?(ext)
          else
            raise ArgumentError, "unknown probe result kind: #{kind.inspect}"
          end
        end

        def present?(value)
          !value.to_s.empty?
        end

        class << self
          def none
            new(kind: :none, bytes: nil, path: nil, ext: nil)
          end

          def oversize_image(ext: "png")
            new(kind: :oversize_image, bytes: nil, path: nil, ext: ext)
          end

          def empty_image
            new(kind: :empty_image, bytes: nil, path: nil, ext: nil)
          end

          def clipboard_timeout
            new(kind: :clipboard_timeout, bytes: nil, path: nil, ext: nil)
          end

          def image_bytes(bytes:, ext: "png")
            new(kind: :image_bytes, bytes: bytes, path: nil, ext: ext)
          end

          def image_file(path:, ext:)
            new(kind: :image_file, bytes: nil, path: path, ext: ext)
          end

          def clean_ext(ext)
            clean = ext.nil? ? nil : ext.to_s.downcase.delete_prefix(".")
            clean == "" ? nil : clean
          end
        end
      end

      # Minimal stand-in for `Process::Status` that only implements
      # `success?`. Surfaced when the clipboard subprocess hits
      # `Timeout::Error` and the wait_thr never produced a real Status.
      class TimeoutStatus
        def success? = false
      end

      TIMEOUT_STATUS = TimeoutStatus.new.freeze

      NONE = ProbeResult.none
      OVERSIZE_IMAGE = ProbeResult.oversize_image
      EMPTY_IMAGE = ProbeResult.empty_image
      CLIPBOARD_TIMEOUT = ProbeResult.clipboard_timeout

      module_function

      def probe(pasted_text:, env: ENV, kernel: DefaultShim)
        test_result = probe_test_clipboard(env: env, kernel: kernel)
        return test_result if test_result.kind != :none

        clipboard_result = probe_clipboard_image(env: env, kernel: kernel)
        return clipboard_result if clipboard_result.kind != :none

        # Primary image MIME clipboard probes run first. A filesystem path
        # in the pasted text is the drag/drop fallback for environments
        # that expose file paths rather than image bytes.
        if !normalized_path(pasted_text).empty?
          file_result = probe_image_file(pasted_text: pasted_text, kernel: kernel)
          return file_result if file_result.kind != :none
          return NONE if non_image_file_path?(pasted_text: pasted_text, kernel: kernel)
          return EMPTY_IMAGE if empty_image_file?(pasted_text: pasted_text, kernel: kernel)
        end

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
        return NONE unless image_signature_matches?(expanded, ext, kernel: kernel)

        ProbeResult.image_file(path: expanded, ext: ext)
      end

      def non_image_file_path?(pasted_text:, kernel: DefaultShim)
        path = normalized_path(pasted_text)
        return false if path.empty?

        expanded = kernel.expand_path(path)
        return false unless kernel.file_exist?(expanded) && kernel.file_file?(expanded)

        ext = File.extname(expanded).delete_prefix(".").downcase
        return true unless IMAGE_EXTENSIONS.include?(ext)

        # Misnamed image: `.png` with non-image bytes is operationally
        # closer to "not an image" than "image we can't render" — the
        # caller flashes "drag-drop ignored (not an image)" which
        # matches user expectation.
        size = kernel.file_size(expanded).to_i
        size.positive? && !image_signature_matches?(expanded, ext, kernel: kernel)
      end

      # True if `pasted_text` resolves to an existing zero-byte image
      # file. Distinct from `non_image_file_path?` so the caller can
      # flash a more accurate reason ("image file is empty") rather
      # than the generic drag-drop refusal.
      def empty_image_file?(pasted_text:, kernel: DefaultShim)
        path = normalized_path(pasted_text)
        return false if path.empty?

        expanded = kernel.expand_path(path)
        return false unless kernel.file_exist?(expanded) && kernel.file_file?(expanded)

        ext = File.extname(expanded).delete_prefix(".").downcase
        return false unless IMAGE_EXTENSIONS.include?(ext)

        kernel.file_size(expanded).to_i.zero?
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
        return CLIPBOARD_TIMEOUT if status.is_a?(TimeoutStatus)
        return NONE unless status_success?(status)

        bytes = out.to_s.b
        return NONE if bytes.empty?
        # The streaming read in DefaultShim#capture3 stops at
        # MAX_IMAGE_BYTES + 1 — anything that hit the cap is rejected
        # here so an oversize clipboard payload neither inflates memory
        # nor falls through into text/path probes downstream.
        return OVERSIZE_IMAGE if bytes.bytesize > MAX_IMAGE_BYTES
        return NONE unless bytes.start_with?(PNG_SIGNATURE)

        ProbeResult.image_bytes(bytes: bytes, ext: "png")
      rescue Timeout::Error => e
        Hive::Tui::Debug.log("clipboard", "probe timed out: #{e.class}: #{e.message}")
        CLIPBOARD_TIMEOUT
      end

      def clipboard_command(env:, kernel:)
        if env.fetch("XDG_SESSION_TYPE", "").downcase == "wayland" &&
           kernel.command_available?("wl-paste", env: env)
          return [ "wl-paste", "--type", "image/png", "--no-newline" ]
        end

        if !env.fetch("DISPLAY", "").empty? && kernel.command_available?("xclip", env: env)
          return [ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" ]
        end

        # macOS-only: `pbpaste` returns clipboard text, not PNG bytes,
        # so this branch is currently a no-op for image probing. Kept
        # under the Darwin guard so a Linux box with a polyglot
        # `pbpaste` script in PATH does not get fired.
        return [ "pbpaste" ] if darwin?(env) && kernel.command_available?("pbpaste", env: env)

        nil
      end

      # @api private (test-only)
      # `HIVE_TUI_TEST_CLIPBOARD=fixture://a.png,b.png,c.png` makes
      # successive `probe` calls serve fixture files in order. Index
      # advance is process-global module state; no thread safety —
      # callers coordinate externally.
      def probe_test_clipboard(env:, kernel:)
        raw = env.fetch("HIVE_TUI_TEST_CLIPBOARD", nil).to_s
        return NONE unless raw.start_with?("fixture://")

        names = raw.delete_prefix("fixture://").split(",")
        index = @test_clipboard_index.to_i
        @test_clipboard_index = index + 1
        if index >= names.size
          return NONE if env.fetch("HIVE_TUI_TEST_CLIPBOARD_STRICT", "").to_s == "1"
          # Clamp at the last fixture by default so a smoke test that
          # configures 2 fixtures and pastes 3 times reuses the last
          # one. Strict mode (above) flips this to a hard NONE.
          index = names.size - 1
        end
        name = names[index].to_s
        return NONE if name.empty? || name.include?("/") || name.include?("..")

        fixture = kernel.test_fixture_path(name)
        return NONE if fixture.nil?

        probe_image_file(pasted_text: fixture, kernel: kernel)
      end

      # @api private (test-only) — reset the fixture-clipboard advance
      # counter so a fresh test run serves the first configured
      # fixture. Production code never calls this.
      def reset_test_clipboard!
        @test_clipboard_index = 0
      end

      def status_success?(status)
        status.respond_to?(:success?) ? status.success? : false
      end

      def darwin?(env)
        host = RbConfig::CONFIG["host_os"].to_s.downcase
        return true if host.include?("darwin")

        # Namespaced test-only opt-in: explicit `HIVE_TUI_TEST_FORCE_DARWIN=1`
        # forces the Darwin branch on Linux for unit tests against a
        # synthetic env. Older `HIVE_TUI_FORCE_DARWIN=1` is intentionally
        # not honoured — a user shell with that variable exported should
        # not pay a per-paste subprocess on Linux.
        env.fetch("HIVE_TUI_TEST_FORCE_DARWIN", "").to_s == "1"
      end

      def image_signature_matches?(path, ext, kernel: DefaultShim)
        head = kernel.read_head(path, max_bytes: 16)
        return false if head.nil? || head.empty?

        return webp_signature?(head) if ext == "webp"

        signatures = IMAGE_SIGNATURES[ext] || []
        signatures.any? { |sig| head.b.start_with?(sig) }
      end

      def webp_signature?(head)
        bytes = head.b
        bytes.bytesize >= 12 && bytes.byteslice(0, 4) == "RIFF".b && bytes.byteslice(8, 4) == "WEBP".b
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
        # buffer that stops growing once `max_bytes` is reached. On
        # `Timeout::Error` returns `[+"".b, +"".b, TIMEOUT_STATUS]`
        # after killing the child.
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
              [ +"".b, +"".b, TIMEOUT_STATUS ]
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
          # until `Timeout` fires.
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
          begin
            Timeout.timeout(0.2) { Process.wait(pid) }
          rescue Timeout::Error
            # SIGKILL+wait still hung — the PID may be a D-state zombie
            # wedged on an uninterruptible syscall. Surface a breadcrumb
            # so an operator hitting "paste never works" has a debug
            # trail before the kernel finally reaps it.
            Hive::Tui::Debug.log(
              "clipboard",
              "terminate: pid=#{pid} unreaped after SIGKILL+wait — may be a zombie"
            )
            nil
          end
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

        # Read the first `max_bytes` of a file as binary, returning
        # nil on any I/O error so probe code can downgrade to NONE
        # without a typed rescue chain.
        def read_head(path, max_bytes:)
          File.open(path, "rb") { |f| f.read(max_bytes) }
        rescue SystemCallError, IOError
          nil
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
