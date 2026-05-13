require "open3"
require "timeout"

require "hive"

module Hive
  module Tui
    module Clipboard
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      MAX_IMAGE_BYTES = 10 * 1024 * 1024
      IMAGE_EXTENSIONS = %w[png jpg jpeg gif webp].freeze
      COMMAND_TIMEOUT_SECONDS = 2.0

      ProbeResult = Data.define(:kind, :bytes, :path, :ext, :reason)
      TimeoutStatus = Struct.new(:ok) do
        def success?
          ok
        end
      end

      NONE = ProbeResult.new(kind: :none, bytes: nil, path: nil, ext: nil, reason: nil).freeze

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
        return NONE unless size.positive? && size <= MAX_IMAGE_BYTES

        ProbeResult.new(kind: :image_file, bytes: nil, path: expanded, ext: ext, reason: nil)
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

        out, _err, status = kernel.capture3(argv, timeout: COMMAND_TIMEOUT_SECONDS)
        return NONE unless status_success?(status)

        bytes = out.to_s.b
        return NONE if bytes.empty?
        return NONE if bytes.bytesize > MAX_IMAGE_BYTES
        return NONE unless bytes.start_with?(PNG_SIGNATURE)

        ProbeResult.new(kind: :image_bytes, bytes: bytes, path: nil, ext: "png", reason: nil)
      rescue Timeout::Error
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

        return [ "pbpaste" ] if kernel.command_available?("pbpaste", env: env)

        nil
      end

      def probe_test_clipboard(env:, kernel:)
        raw = env.fetch("HIVE_TUI_TEST_CLIPBOARD", nil).to_s
        return NONE unless raw.start_with?("fixture://")

        name = raw.delete_prefix("fixture://")
        return NONE if name.empty? || name.include?("/") || name.include?("..")

        fixture = File.expand_path("../../../test/fixtures/composer/#{name}", __dir__)
        probe_image_file(pasted_text: fixture, kernel: kernel)
      end

      def status_success?(status)
        status.respond_to?(:success?) ? status.success? : false
      end

      module DefaultShim
        module_function

        def command_available?(name, env:)
          paths = env.fetch("PATH", "").split(File::PATH_SEPARATOR)
          paths.any? do |dir|
            path = File.join(dir, name)
            File.file?(path) && File.executable?(path)
          end
        end

        def capture3(argv, timeout:)
          Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
            stdin.close
            begin
              out = +"".b
              err = +"".b
              status = Timeout.timeout(timeout) do
                out = stdout.read
                err = stderr.read
                wait_thr.value
              end
              [ out, err, status ]
            rescue Timeout::Error
              terminate(wait_thr.pid)
              [ +"".b, "timeout", TimeoutStatus.new(false) ]
            end
          end
        end

        def terminate(pid)
          Process.kill("TERM", pid)
          Timeout.timeout(0.2) { Process.wait(pid) }
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        rescue Timeout::Error
          Process.kill("KILL", pid)
          Process.wait(pid)
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
      end
    end
  end
end
