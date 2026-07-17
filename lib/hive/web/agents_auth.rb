require "json"
require "pty"
require "securerandom"
require "fileutils"
require "hive/agent_profiles"

module Hive
  module Web
    class AgentsAuth
      # Capture the authorize URL once it is terminated by whitespace OR the
      # end of the captured buffer. The reader re-extracts the *latest* match
      # from newly arrived output (not `||=` first-match), so a partial
      # prefix seen mid-stream is replaced by the full URL as more chars
      # arrive and the value settles once the CLI stops printing — this lets a URL emitted
      # with no trailing space (URL immediately followed by the input prompt)
      # still be surfaced instead of leaving the operator with only the raw
      # `<pre>` output.
      URL_RE = %r{https?://[^\s<>"']+(?=\s|\z)}.freeze
      # A URL definitively terminated by whitespace — used to know the captured
      # value has "settled" so the reader can stop re-scanning. A match that
      # only reaches the end of the buffer (\z, no trailing space yet) may still
      # be a truncated prefix if the URL straddles a read boundary, so we keep
      # scanning until a whitespace-terminated match (or EOF) settles it.
      URL_SETTLED_RE = %r{https?://[^\s<>"']+(?=\s)}.freeze
      # Terminal control runs an agent may wrap a URL in — CSI/SGR color
      # sequences (codex prints the device link as `\e[94m<url>\e[0m`) and any
      # bare C0/DEL byte (a lone ESC left when a sequence straddles a read
      # boundary, or an OSC/DCS introducer). URL_RE only stops at whitespace,
      # so these ride into the captured match; sanitize_url replaces each run
      # with a space (never deletes — see there) before re-extracting the URL.
      TERMINAL_CONTROL_RE = %r{\e\[[0-9;]*[A-Za-z]|[\x00-\x1f\x7f]}.freeze
      AGENT_COMMANDS = {
        "claude" => %w[claude setup-token],
        # `--device-auth` is the headless device-flow: one authorize URL plus
        # a one-time code the operator enters at the provider. Plain `codex
        # login` is a localhost-callback OAuth — it starts a server on the
        # CONTAINER's localhost:1455 and prints THAT as the first URL, which
        # the relay would surface and which the operator's browser can never
        # reach across the container boundary. codex itself recommends
        # `--device-auth` "on a remote or headless machine".
        "codex" => %w[codex login --device-auth],
        "grok" => %w[grok login --device-auth],
        # gh is not a pipeline agent, but its login IS first-run setup: git's
        # https credential helper reads it for every push the daemon makes.
        # The flags pin the prompts away (host, protocol, no ssh key upload)
        # so the relay only has to handle the device-code screen.
        "gh" => %w[gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key]
      }.freeze

      # Agents whose login is OPERATOR-WARD: the one-time code is entered at
      # the provider and the CLI polls in the background — nothing is pasted
      # back into the CLI. The relay must keep refreshing the status page until
      # the child exits (`done`) rather than show a paste-the-code form. codex
      # `--device-auth` and gh's device flow are both poll-type; claude
      # `setup-token` is the only paste-back flow.
      POLL_LOGIN_AGENTS = %w[codex grok gh].freeze

      # Hard ceiling on in-flight login attempts. Each holds a PTY (2 fds + a
      # child + a reader thread); a small cap stops a stuck-CLI pile-up from
      # leaking the box's resources.
      MAX_CONCURRENT_LOGINS = 4
      # A CLI that never emits EOF (hung provider handshake) would otherwise
      # block its reader thread forever. The watchdog force-kills the child
      # past this deadline so the reader unblocks and the session is reaped.
      LOGIN_TIMEOUT_SEC = 300
      # Grace between the watchdog's SIGTERM and its SIGKILL escalation.
      WATCHDOG_ESCALATE_SEC = 1
      # How long `start` waits for the authorize URL before rendering, and how
      # long `complete` waits to learn whether a pasted code was accepted.
      URL_WAIT_SEC = 8
      COMPLETE_WAIT_SEC = 8

      Session = Struct.new(:id, :agent, :pid, :pgid, :io, :reader, :output, :url, :done, :error,
                           :auto_continued,
                           keyword_init: true)

      def initialize
        @sessions = {}
        @mutex = Mutex.new
      end

      def statuses
        agents = %w[claude codex pi grok].to_h do |agent|
          [ agent, { "logged_in" => Hive::AgentProfiles.logged_in?(agent) } ]
        end
        # Not an agent profile, but part of the same first-run checklist:
        # the daemon's pushes authenticate through gh's credential helper.
        agents["gh"] = { "logged_in" => gh_logged_in? }
        agents
      end

      def gh_logged_in?
        system("gh", "auth", "status", out: File::NULL, err: File::NULL) ? true : false
      end

      def start(agent)
        argv = AGENT_COMMANDS.fetch(agent.to_s)
        prune_finished_sessions
        enforce_concurrency_cap!
        session = Session.new(id: SecureRandom.hex(8), agent: agent.to_s, output: +"", done: false)
        reader, writer, pid = PTY.spawn(*argv)
        session.io = writer
        session.reader = reader
        session.pid = pid
        # PTY.spawn runs the child in a fresh session, so it leads its own
        # process group. Capture the pgid up front: the watchdog kills the
        # whole group (not a bare pid) so a child that forked helpers is fully
        # torn down, and so a reaped-then-reused pid can't be signalled.
        session.pgid = process_group_of(pid)
        @mutex.synchronize { @sessions[session.id] = session }

        Thread.new { relay_reader(session, reader, writer, pid) }
        start_watchdog(session)
        await_url(session.id)
        session
      rescue KeyError
        raise Hive::InvalidTaskPath, "unknown agent login flow: #{agent}"
      end

      def session(id)
        @mutex.synchronize { @sessions[id] }
      end

      # Read the relayed-output buffer and the parsed authorize URL under the
      # mutex so callers get a guaranteed-consistent view of values the reader
      # thread mutates concurrently (MRI's GVL prevents torn reads, but this
      # makes the happens-before relationship explicit and survives a future
      # non-GVL runtime).
      def output_for(id)
        raw = @mutex.synchronize { @sessions[id]&.output&.dup }
        return nil unless raw

        # The buffer is raw PTY bytes — `readpartial` returns ASCII-8BIT, and a
        # 4096-byte read can split a UTF-8 multibyte char or carry terminal
        # control sequences. Rendered straight into the UTF-8 `<pre>` it raised
        # Encoding::CompatibilityError (a 500 on the login-status page).
        # Reinterpret as UTF-8 and drop invalid byte sequences so the
        # operator-facing CLI output always renders.
        raw.force_encoding(Encoding::UTF_8).scrub("")
      end

      def url_for(id)
        @mutex.synchronize { @sessions[id]&.url }
      end

      # Whether this agent's login is operator-ward (poll-type) rather than
      # paste-back — the view keeps refreshing until `done` and hides the
      # paste-the-code form for these. See POLL_LOGIN_AGENTS.
      def poll_login?(agent)
        POLL_LOGIN_AGENTS.include?(agent.to_s)
      end

      # Block until the CLI has printed its authorize URL (or the bounded
      # deadline elapses / the CLI exits). Without this, `start` could render
      # before the asynchronously-populated URL exists, leaving the operator
      # with no provider link to open.
      def await_url(id, timeout: URL_WAIT_SEC)
        wait_until(timeout) do
          s = session(id)
          s.nil? || s.done || s.url
        end
        url_for(id)
      end

      def complete(id, code)
        s = session(id)
        raise Hive::InvalidTaskPath, "unknown login session" unless s
        raise Hive::Error, "login session already finished" if s.done
        raise Hive::Error, "missing callback code or URL" if code.to_s.strip.empty?

        begin
          s.io.write("#{code}\n")
        rescue IOError, Errno::EIO
          # The CLI exited between the `done` check and the write, closing the
          # master. Surface a friendly error instead of an opaque 500 (the
          # app's `rescue_from Hive::Error` renders the 422 page).
          raise Hive::Error, "the login session has already closed — start the login again"
        end

        wait_for_login_outcome(s)
        s
      end

      def write_pi_token(raw_json)
        parsed = JSON.parse(raw_json.to_s)
        raise Hive::Error, "pi token JSON must be a non-empty object" unless parsed.is_a?(Hash) && parsed.any?

        path = File.expand_path("~/.pi/agent/auth.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(parsed), mode: "w", perm: 0o600)
        path
      rescue JSON::ParserError => e
        raise Hive::Error, "pi token JSON is invalid: #{e.message}"
      end

      private

      # Reject a new login when too many are already in flight, so a pile-up
      # of stuck CLIs can't leak fds/threads/children without bound.
      def enforce_concurrency_cap!
        in_flight = @mutex.synchronize { @sessions.count { |_, s| !s.done } }
        return if in_flight < MAX_CONCURRENT_LOGINS

        raise Hive::Error, "too many login attempts in progress — finish or wait for one to complete"
      end

      # Kill a CLI that never reaches EOF (e.g. a hung provider handshake) so
      # its reader thread unblocks and the fds/child are reclaimed. A clean
      # exit makes this a no-op (the wait returns once the session is done).
      def start_watchdog(session, timeout: LOGIN_TIMEOUT_SEC)
        Thread.new do
          done = wait_until(timeout) { session_done?(session) }
          next if done

          # Capture the process group under the mutex and skip the kill if the
          # reader thread already reaped the child (cleared pid). Reading
          # `done`/`pid` racily and then signalling a bare pid could SIGKILL an
          # unrelated process after pid reuse (e.g. the daemon). Signalling the
          # process group (-pgid) the CLI leads avoids that and tears down any
          # helpers it spawned.
          pgid = @mutex.synchronize { session.done ? nil : session.pgid }
          next unless pgid

          signal_group(pgid)
          # Give TERM a brief window to land, then escalate if the reader
          # thread hasn't observed the exit (set `done`).
          escalate = wait_until(WATCHDOG_ESCALATE_SEC) { session_done?(session) }
          signal_group(pgid, "KILL") unless escalate
        end
      end

      def session_done?(session)
        @mutex.synchronize { session.done }
      end

      # Best-effort signal to a process group. ESRCH (already gone) and EPERM
      # (pid/group recycled to a process we don't own) are both benign here.
      def signal_group(pgid, signal = "TERM")
        Process.kill(signal, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # After a code is relayed, wait a bounded time to learn the outcome and
      # surface a clear error rather than a silent redirect: a rejected/late
      # code makes the CLI re-prompt (the session never goes `done`), so the
      # operator would otherwise be redirected with the agent still "Not
      # logged in" and no explanation.
      def wait_for_login_outcome(session, timeout: COMPLETE_WAIT_SEC)
        wait_until(timeout) do
          session.done || Hive::AgentProfiles.logged_in?(session.agent)
        end

        if session.done && session.error
          raise Hive::Error, "agent login failed (#{session.error}). Check the output above and try again."
        end
        return if session.done || Hive::AgentProfiles.logged_in?(session.agent)

        raise Hive::Error, "the agent did not accept that code — it is still waiting for input. " \
                           "Check the output above and paste the code again."
      end

      # Poll `block` until it returns truthy or `timeout` seconds elapse.
      # Returns the truthy value, or false on timeout. Uses a monotonic clock
      # so a wall-clock jump can't extend or cut short the wait.
      def wait_until(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          value = yield
          return value if value
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.05
        end
      end

      # Drop sessions whose CLI has already exited so @sessions doesn't grow
      # without bound across the box's lifetime. Finished sessions have had
      # their fds closed in the reader thread's ensure block, so there is
      # nothing left to read or relay a code into.
      def prune_finished_sessions
        @mutex.synchronize { @sessions.delete_if { |_, s| s.done } }
      end

      # Relay the CLI's PTY output into the session buffer, surface the
      # authorize URL, and ALWAYS clean up. The `ensure` must run close_io +
      # mark `done` regardless of how the wait turns out — if the watchdog
      # already reaped the child, Process.wait2 raises Errno::ECHILD; without
      # the rescue that exception would propagate and skip the cleanup, leaking
      # the PTY fds and wedging the session "in flight" forever.
      def relay_reader(session, reader, writer, pid)
        scan_output(session, reader)
      ensure
        status = reap_child(pid)
        # Close both PTY ends so the master/slave fds are reclaimed — otherwise
        # a long-running box leaks two fds per login attempt.
        close_io(reader)
        close_io(writer)
        finalize_session(session, status)
      end

      # Bytes carried between reads so a URL split across a read boundary is
      # still matched. The cap bounds the tail we re-scan so a long URL-free run
      # can't grow the scan window without limit.
      SCAN_TAIL_BYTES = 2048

      # Scan newly-arrived data only, instead of re-running URL_RE against the
      # whole growing buffer on every character (the old O(n²)-under-the-mutex
      # path). readpartial returns whatever is available WITHOUT waiting for a
      # newline, so a URL printed with no trailing newline (immediately followed
      # by the input prompt) is still detected. Once the URL is found we stop
      # scanning and just relay. The mutex is held only for the buffer append
      # and the regex on the small tail — not the whole stream.
      def scan_output(session, reader)
        tail = +""
        settled = false
        loop do
          chunk = read_available(reader)
          break unless chunk

          @mutex.synchronize do
            session.output << chunk
            # gh's --web flow blocks on a bare Enter ("Press Enter to open
            # https://github.com/login/device in your browser") before it
            # starts polling — there is no code to paste BACK (the one-time
            # code travels operator-ward). Answer the prompt for them.
            if session.agent == "gh" && !session.auto_continued &&
               session.output.include?("Press Enter")
              session.auto_continued = true
              begin
                session.io.write("\n")
              rescue IOError, Errno::EIO
                # Child already exiting — the reader loop will surface it.
              end
            end
            next if settled # URL locked in — just relay from here on

            tail << chunk
            # Re-extract the latest match each read (a \z-only match may be a
            # truncated prefix that grows on the next read); lock it in only
            # once a whitespace-terminated match proves it is complete.
            match = tail[URL_RE]
            session.url = sanitize_url(match) if match
            if tail[URL_SETTLED_RE]
              settled = true
              tail = nil
            else
              tail = tail[-SCAN_TAIL_BYTES..] || tail
            end
          end
        end
      end

      # Turn a raw URL_RE capture into a clean, clickable href. Replace each
      # terminal-control run with a SPACE — never delete it — then re-extract
      # the first whitespace-terminated http(s) URL. Deleting would splice two
      # URLs an agent printed back-to-back (separated only by an SGR reset)
      # into one href: `…/device\e[0mhttps://evil` -> `…/devicehttps://evil`.
      # Substituting a space instead lets URL_RE stop at the boundary, so the
      # trailing color reset, any OSC-8 wrapper residue, and a second URL are
      # all dropped, and the authorize URL is surfaced verbatim.
      def sanitize_url(url)
        candidate = url.to_s.gsub(TERMINAL_CONTROL_RE, " ")
        candidate[URL_RE] || candidate.strip
      end

      # Read whatever bytes are available without blocking for a newline.
      # End-of-stream surfaces as EOFError on a pipe or, for a PTY master whose
      # child has exited, as Errno::EIO on Linux — both mean "done", so return
      # nil and let scan_output's loop break.
      def read_available(reader)
        reader.readpartial(4096)
      rescue EOFError, Errno::EIO
        nil
      end

      def reap_child(pid)
        _, status = Process.wait2(pid)
        status
      rescue Errno::ECHILD
        # The watchdog already reaped this child. Cleanup still must run.
        nil
      end

      def finalize_session(session, status)
        @mutex.synchronize do
          session.done = true
          # A signaled child (the watchdog's TERM/KILL after the login
          # timeout) has a nil exitstatus — "exit " with no number told the
          # operator nothing. Mirror the bot supervisor's rendering.
          if status.nil?
            # Reaped by the watchdog race (ECHILD): without attribution the
            # session reads as a clean exit while the agent stays logged out.
            session.error ||= "exited (reaped elsewhere — likely the login timed out)"
          elsif !status.success?
            session.error =
              if status.exitstatus
                "exit #{status.exitstatus}"
              else
                "killed (signal #{status.termsig || "?"} — likely the login timed out)"
              end
          end
        end
      end

      def process_group_of(pid)
        Process.getpgid(pid)
      rescue Errno::ESRCH
        pid
      end

      def close_io(io)
        io.close unless io.nil? || io.closed?
      rescue IOError
        nil
      end
    end
  end
end
