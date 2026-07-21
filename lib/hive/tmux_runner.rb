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
    class CommandTimedOut < Hive::TmuxError; end

    DEFAULT_COLS = 200
    DEFAULT_ROWS = 50
    DEFAULT_PROMPT_SUBMIT_DELAY_SEC = 0.2
    # Upper bound on how long to wait for a pasted prompt to finish
    # rendering before submitting; if the pane never stabilizes we submit
    # anyway rather than stranding the prompt.
    DEFAULT_PROMPT_SETTLE_TIMEOUT_SEC = 30.0
    # Consecutive identical pane-tail captures that mean the bracketed
    # paste has finished rendering into the input box.
    PROMPT_SETTLE_STABLE_POLLS = 2
    # Tail bytes compared between polls — enough to include the input box
    # region at the bottom of the pane.
    PROMPT_SETTLE_CAPTURE_BYTES = 4096
    DEFAULT_COMMAND_TIMEOUT_SEC = 10.0

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
        #
        # `-r` disables tmux's default LF→CR translation: each LF in a
        # multi-line prompt would otherwise be delivered as ENTER, which
        # would submit Claude Code's input box on the first line break
        # instead of keeping the prompt multi-line. The explicit
        # send_keys("Enter") below is the single, intended submit.
        run_tmux("paste-buffer", "-d", "-r", "-b", buffer_name, "-t", target_pane)
        # A large bracketed paste renders into the agent's input box over
        # many frames. A fixed sleep here let `Enter` fire mid-ingest on
        # big prompts, so the submit was swallowed and the prompt sat
        # STAGED — the agent never started and the stage burned its whole
        # timeout (observed: review triage with ~30 paste chunks idling
        # 15+ min). Wait until the pane stops changing (paste fully
        # rendered) before the single submit so `Enter` always lands.
        wait_for_paste_to_settle
        # If tmux disappears here, the prompt was pasted but never submitted.
        # Surface the typed failure immediately instead of waiting for stage timeout.
        send_keys("Enter")
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

    def prompt_settle_timeout_sec
      Float(ENV.fetch("HIVE_TMUX_PROMPT_SETTLE_TIMEOUT_SEC", DEFAULT_PROMPT_SETTLE_TIMEOUT_SEC.to_s))
    end

    # Poll the pane until its tail stops changing across
    # PROMPT_SETTLE_STABLE_POLLS consecutive captures — i.e. the bracketed
    # paste has finished rendering into the input box — then return so the
    # caller's single `Enter` submits a settled prompt. The poll interval
    # is `prompt_submit_delay_sec`. Bounded by `prompt_settle_timeout_sec`:
    # if the pane never stabilizes, or a capture fails, submit anyway
    # rather than stranding the prompt (a real server loss then surfaces
    # on the `send_keys("Enter")` that follows).
    def wait_for_paste_to_settle
      deadline = Time.now + prompt_settle_timeout_sec
      previous = nil
      stable = 0
      loop do
        sleep prompt_submit_delay_sec
        begin
          current = capture_pane_tail(bytes: PROMPT_SETTLE_CAPTURE_BYTES)
        rescue Hive::TmuxError
          return
        end
        if current == previous
          stable += 1
          return if stable >= PROMPT_SETTLE_STABLE_POLLS
        else
          stable = 0
        end
        previous = current
        return if Time.now >= deadline
      end
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
      timeout = tmux_command_timeout_sec
      Open3.popen3(*tmux_argv(args)) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        unless wait_thr.join(timeout)
          Process.kill("KILL", wait_thr.pid) rescue nil
          wait_thr.join
          raise CommandTimedOut, "tmux #{args.inspect} timed out after #{timeout}s"
        end

        [ out_reader.value, err_reader.value, wait_thr.value ]
      end
    rescue Errno::ENOENT, Errno::EACCES => e
      raise ExecutableMissing, "tmux executable not found: #{@tmux_bin} (#{e.class}: #{e.message})"
    end

    def tmux_command_timeout_sec
      Float(ENV.fetch("HIVE_TMUX_COMMAND_TIMEOUT_SEC", DEFAULT_COMMAND_TIMEOUT_SEC.to_s))
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
        err.include?("no current target") ||
        err.include?("no server running") ||
        err.include?("no current server") ||
        err.include?("server exited unexpectedly") ||
        err.include?("server not found") ||
        err.include?("lost server")
    end
  end
end
