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
      # on every char (not `||=` first-match), so a partial prefix seen
      # mid-stream is replaced by the full URL as more chars arrive and the
      # value settles once the CLI stops printing — this lets a URL emitted
      # with no trailing space (URL immediately followed by the input prompt)
      # still be surfaced instead of leaving the operator with only the raw
      # `<pre>` output.
      URL_RE = %r{https?://[^\s<>"']+(?=\s|\z)}.freeze
      AGENT_COMMANDS = {
        "claude" => %w[claude setup-token],
        "codex" => %w[codex login]
      }.freeze

      # Hard ceiling on in-flight login attempts. Each holds a PTY (2 fds + a
      # child + a reader thread); a small cap stops a stuck-CLI pile-up from
      # leaking the box's resources.
      MAX_CONCURRENT_LOGINS = 4
      # A CLI that never emits EOF (hung provider handshake) would otherwise
      # block its reader thread forever. The watchdog force-kills the child
      # past this deadline so the reader unblocks and the session is reaped.
      LOGIN_TIMEOUT_SEC = 300
      # How long `start` waits for the authorize URL before rendering, and how
      # long `complete` waits to learn whether a pasted code was accepted.
      URL_WAIT_SEC = 8
      COMPLETE_WAIT_SEC = 8

      Session = Struct.new(:id, :agent, :pid, :io, :reader, :output, :url, :done, :error, keyword_init: true)

      def initialize
        @sessions = {}
        @mutex = Mutex.new
      end

      def statuses
        %w[claude codex pi].to_h do |agent|
          [ agent, { "logged_in" => Hive::AgentProfiles.logged_in?(agent) } ]
        end
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
        @mutex.synchronize { @sessions[session.id] = session }

        Thread.new do
          begin
            reader.each_char do |char|
              @mutex.synchronize do
                session.output << char
                extracted = session.output[URL_RE]
                session.url = extracted if extracted
              end
            end
          rescue Errno::EIO
            nil
          ensure
            _, status = Process.wait2(pid)
            # Close both PTY ends so the master/slave fds are reclaimed —
            # otherwise a long-running box leaks two fds per login attempt.
            close_io(reader)
            close_io(writer)
            @mutex.synchronize { session.done = true; session.error = "exit #{status.exitstatus}" unless status.success? }
          end
        end
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
        @mutex.synchronize { @sessions[id]&.output&.dup }
      end

      def url_for(id)
        @mutex.synchronize { @sessions[id]&.url }
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
          # app's `error Hive::Error` filter renders the 422 page).
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
      def start_watchdog(session)
        Thread.new do
          done = wait_until(LOGIN_TIMEOUT_SEC) { session.done }
          next if done

          begin
            Process.kill("TERM", session.pid)
            sleep 1
            Process.kill("KILL", session.pid) unless session.done
          rescue Errno::ESRCH
            nil
          end
        end
      end

      # After a code is relayed, wait a bounded time to learn the outcome and
      # surface a clear error rather than a silent redirect: a rejected/late
      # code makes the CLI re-prompt (the session never goes `done`), so the
      # operator would otherwise be redirected with the agent still "Not
      # logged in" and no explanation.
      def wait_for_login_outcome(session)
        wait_until(COMPLETE_WAIT_SEC) do
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

      def close_io(io)
        io.close unless io.nil? || io.closed?
      rescue IOError
        nil
      end
    end
  end
end
