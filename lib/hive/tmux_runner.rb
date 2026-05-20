require "open3"
require "securerandom"
require "shellwords"
require "tempfile"
require "hive"

module Hive
  class TmuxRunner
    # Typed TmuxError subclasses let rescue clauses test by class rather
    # than by message substring. `ExecutableMissing` is the binary-not-found
    # case (rescued during `kill_session` to keep teardown idempotent);
    # `NoServerRunning` is the soft-failure sentinel for "no tmux server
    # left to talk to" (so kill is idempotent across server exits);
    # `CommandFailed` is the fallback for everything else a tmux invocation
    # may report.
    class ExecutableMissing < Hive::TmuxError; end
    class NoServerRunning < Hive::TmuxError; end
    class CommandFailed < Hive::TmuxError; end

    DEFAULT_COLS = 200
    DEFAULT_ROWS = 50
    DEFAULT_PROMPT_SUBMIT_DELAY_SEC = 0.2

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
      begin
        # `paste-buffer -d` deletes the named buffer on success, but a
        # transient server stall or a pane killed mid-call can leave the
        # buffer loaded — accumulating against tmux's default 50-buffer
        # cap on long-lived daemons. Explicitly delete the buffer in
        # `ensure` so a failed paste does not leak it.
        run_tmux("paste-buffer", "-d", "-b", buffer_name, "-t", target_pane)
        sleep prompt_submit_delay_sec
        begin
          send_keys("Enter")
        rescue NoServerRunning
          nil
        end
      ensure
        delete_buffer(buffer_name)
      end
      true
    end

    def send_keys(*keys)
      run_tmux("send-keys", "-t", target_pane, *keys)
      true
    end

    def delete_buffer(buffer_name)
      run_tmux("delete-buffer", "-b", buffer_name)
    rescue Hive::TmuxError
      nil
    end

    def capture_pane_tail(bytes:)
      lines = [ (bytes.to_i / 80.0).ceil, 100 ].max
      out = run_tmux("capture-pane", "-t", target_pane, "-p", "-S", "-#{lines}").scrub.rstrip
      tail = out.bytesize > bytes ? out.byteslice(-bytes, bytes) : out
      tail.scrub
    end

    # Active pane's process PID. The wrapper script execs into claude
    # (`exec "$@"` in interactive_claude_wrapper.sh), preserving the PID
    # across the exec, so this is the claude PID we record into the task
    # lock for `hive status` / signal-routing parity with the headless path.
    def pane_pid
      out = run_tmux("display-message", "-t", target_pane, "-p", '#{pane_pid}').strip
      Integer(out)
    rescue ArgumentError, TypeError
      nil
    end

    def kill_session
      run_tmux("kill-session", "-t", @name)
      true
    rescue ExecutableMissing, NoServerRunning
      true
    end

    private

    def prompt_submit_delay_sec
      Float(ENV.fetch("HIVE_TMUX_PROMPT_SUBMIT_DELAY_SEC", DEFAULT_PROMPT_SUBMIT_DELAY_SEC.to_s))
    end

    def target_pane
      @name
    end

    def run_tmux(*args)
      out, err, status = capture_tmux(*args)
      return out if status.success?

      raise NoServerRunning, "tmux #{args.inspect} unavailable: #{err.strip}" if tmux_server_unavailable?(err)

      raise CommandFailed, "tmux #{args.inspect} failed: #{err.strip}"
    end

    def capture_tmux(*args)
      Open3.capture3(*tmux_argv(args))
    rescue Errno::ENOENT, Errno::EACCES => e
      raise ExecutableMissing, "tmux executable not found: #{@tmux_bin} (#{e.class}: #{e.message})"
    end

    def tmux_argv(args)
      argv = [ @tmux_bin ]
      argv.concat([ "-L", @socket_name ]) if @socket_name
      argv.concat(args)
      argv
    end

    # Widen these substrings deliberately: any "session is gone" / "no
    # server" rephrasing tmux ships in a future release must classify as
    # `NoServerRunning` so `kill_session`'s idempotent teardown keeps
    # working. If you see a new tmux phrasing in the wild, add it here.
    def tmux_server_unavailable?(err)
      err.include?("can't find session") ||
        err.include?("session not found") ||
        err.include?("no server running") ||
        err.include?("no current server") ||
        err.include?("server exited unexpectedly") ||
        err.include?("server not found") ||
        err.include?("lost server")
    end
  end
end
