require "open3"
require "securerandom"
require "shellwords"
require "tempfile"
require "hive"

module Hive
  class TmuxRunner
    DEFAULT_COLS = 200
    DEFAULT_ROWS = 50

    attr_reader :name, :cwd, :env

    def initialize(name:, cwd:, env: {}, tmux_bin: "tmux", socket_name: nil)
      @name = name
      @cwd = cwd
      @env = env
      @tmux_bin = tmux_bin
      @socket_name = socket_name
    end

    def start_detached(command:)
      command_string = command.is_a?(Array) ? Shellwords.join(command) : command.to_s
      args = [
        "new-session", "-d",
        "-s", @name,
        "-x", DEFAULT_COLS.to_s,
        "-y", DEFAULT_ROWS.to_s,
        "-c", @cwd
      ]
      @env.each { |key, value| args.concat([ "-e", "#{key}=#{value}" ]) }
      args << command_string
      run_tmux(*args)
      true
    end

    def session_exists?
      _out, _err, status = capture_tmux("has-session", "-t", @name)
      status.success?
    rescue Hive::TmuxError
      false
    end

    def send_prompt(text)
      buffer_name = "hive-#{Process.pid}-#{SecureRandom.hex(4)}"
      Tempfile.create("hive-tmux-prompt") do |f|
        f.binmode
        f.write(text)
        f.flush
        run_tmux("load-buffer", "-b", buffer_name, f.path)
      end
      run_tmux("paste-buffer", "-d", "-b", buffer_name, "-t", target_pane)
      run_tmux("send-keys", "-t", target_pane, "Enter")
      true
    end

    def capture_pane_tail(bytes:)
      lines = [ (bytes.to_i / 80.0).ceil, 100 ].max
      out = run_tmux("capture-pane", "-t", target_pane, "-p", "-S", "-#{lines}").rstrip
      out.bytesize > bytes ? out.byteslice(-bytes, bytes) : out
    end

    def kill_session
      _out, err, status = capture_tmux("kill-session", "-t", @name)
      return true if status.success?
      return true if err.include?("can't find session") ||
                     err.include?("no server running") ||
                     err.include?("server exited unexpectedly")

      raise Hive::TmuxError, "tmux kill-session failed for #{@name}: #{err.strip}"
    rescue Hive::TmuxError => e
      return true if e.message.include?("tmux executable not found")

      raise
    end

    private

    def target_pane
      @name
    end

    def run_tmux(*args)
      out, err, status = capture_tmux(*args)
      return out if status.success?

      raise Hive::TmuxError, "tmux #{args.inspect} failed: #{err.strip}"
    end

    def capture_tmux(*args)
      Open3.capture3(*tmux_argv(args))
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Hive::TmuxError, "tmux executable not found: #{@tmux_bin} (#{e.class}: #{e.message})"
    end

    def tmux_argv(args)
      argv = [ @tmux_bin ]
      argv.concat([ "-L", @socket_name ]) if @socket_name
      argv.concat(args)
      argv
    end
  end
end
