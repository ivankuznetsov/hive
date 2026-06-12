require "test_helper"
require "hive/web/agents_auth"

# U3 relay: the PTY login state machine must spawn the agent CLI, surface the
# provider authorize URL it prints, relay a pasted code back into the waiting
# CLI, and clean up (mark done, close fds) when the CLI exits. Driven against
# a fake `claude` on PATH so no real provider handshake is needed.
class AgentsAuthLoginTest < Minitest::Test
  include HiveTestHelper

  AUTH_URL = "https://login.example/oauth?challenge=abc123".freeze

  def install_fake_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      # Mimic `claude setup-token`: print an authorize URL, wait for a code,
      # succeed only if a non-empty code is pasted.
      echo "Open #{AUTH_URL} to authenticate"
      read -r code
      if [ -n "$code" ]; then
        echo "token stored"
        exit 0
      fi
      exit 1
    SH
    FileUtils.chmod(0o755, path)
  end

  def install_fake_gh(bin_dir)
    path = File.join(bin_dir, "gh")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      # Mimic `gh auth login --web`: one-time code travels operator-ward,
      # then the CLI blocks on a bare Enter before polling GitHub.
      echo "! First copy your one-time code: ABCD-1234"
      echo "Press Enter to open https://github.com/login/device in your browser..."
      read -r _
      echo "Logged in as tester"
      exit 0
    SH
    FileUtils.chmod(0o755, path)
  end

  def with_fake_gh
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_fake_gh(bin_dir)
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        yield
      end
    end
  end

  # Explicit wait (no fixed sleep): poll until the block is truthy or raise.
  def wait_until(timeout: 5.0)
    deadline = monotonic + timeout
    loop do
      value = yield
      return value if value
      raise "condition not met within #{timeout}s" if monotonic > deadline

      sleep 0.02
    end
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def with_fake_claude
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_fake_claude(bin_dir)
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        yield
      end
    end
  end

  def test_gh_login_auto_answers_the_press_enter_prompt
    with_fake_gh do
      auth = Hive::Web::AgentsAuth.new
      session = auth.start("gh")

      url = wait_until { auth.session(session.id).url }
      assert_match %r{github\.com/login/device}, url,
                   "the device URL must surface so the operator can open it on a phone"

      # NO complete() call: the relay must answer gh's bare-Enter prompt
      # itself — the one-time code travels operator-ward, nothing pastes back.
      wait_until { auth.session(session.id).done }
      assert_nil auth.session(session.id).error
      assert_includes auth.output_for(session.id), "ABCD-1234",
                      "the one-time code must reach the relayed output"
      assert_includes auth.output_for(session.id), "Logged in as tester"
    end
  end

  def test_start_surfaces_authorize_url_then_complete_relays_code
    with_fake_claude do
      auth = Hive::Web::AgentsAuth.new
      session = auth.start("claude")

      found = wait_until { auth.session(session.id).url }
      assert_equal AUTH_URL, found, "the authorize URL the CLI printed must be surfaced"

      auth.complete(session.id, "pasted-code")

      wait_until { auth.session(session.id).done }
      assert_nil auth.session(session.id).error, "a relayed valid code must finish without error"
    end
  end

  def test_complete_rejects_empty_code
    with_fake_claude do
      auth = Hive::Web::AgentsAuth.new
      session = auth.start("claude")
      wait_until { auth.session(session.id).url }

      assert_raises(Hive::Error) { auth.complete(session.id, "   ") }
    ensure
      # Drive the spawned CLI to a clean exit so a child blocked on `read`
      # doesn't wedge VM shutdown.
      auth.complete(session.id, "cleanup") rescue nil
      wait_until { auth.session(session.id).nil? || auth.session(session.id).done } rescue nil
    end
  end

  def test_unknown_agent_raises
    auth = Hive::Web::AgentsAuth.new
    assert_raises(Hive::InvalidTaskPath) { auth.start("nope") }
  end

  # The reader now scans line-by-line (not the O(n²) per-char full-buffer scan).
  # A CLI that prints the URL with NO trailing newline — the URL immediately
  # followed by the input prompt on the same final line — must still surface it
  # (the URL_RE `\z` tail match), and the relayed output must include the
  # prompt that came after.
  def install_no_newline_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      # printf with no trailing newline: "...<URL> Paste code: " then read.
      printf 'Open #{AUTH_URL} Paste code: '
      read -r code
      [ -n "$code" ] && { echo ok; exit 0; }
      exit 1
    SH
    FileUtils.chmod(0o755, path)
  end

  def test_url_detected_when_printed_without_a_trailing_newline
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_no_newline_claude(bin_dir)
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        auth = Hive::Web::AgentsAuth.new
        session = auth.start("claude")

        found = wait_until { auth.session(session.id).url }
        assert_equal AUTH_URL, found,
                     "a URL with no trailing newline (tail buffer) must still be detected"
      ensure
        auth.complete(session.id, "x") rescue nil
        wait_until { auth.session(session.id).nil? || auth.session(session.id).done } rescue nil
      end
    end
  end

  # A `claude` that rejects any code != "good" and exits non-zero — models a
  # wrong/expired callback code.
  def install_strict_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      echo "Open #{AUTH_URL} to authenticate"
      read -r code
      if [ "$code" = "good" ]; then echo "token stored"; exit 0; fi
      echo "invalid code"
      exit 7
    SH
    FileUtils.chmod(0o755, path)
  end

  def test_complete_with_rejected_code_surfaces_error_not_silent_redirect
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_strict_claude(bin_dir)
      # HOME points at an empty dir so logged_in? can't false-positive off the
      # developer's real ~/.claude credential.
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR), "HOME" => dir) do
        auth = Hive::Web::AgentsAuth.new
        session = auth.start("claude")

        error = assert_raises(Hive::Error) { auth.complete(session.id, "wrong") }
        assert_match(/login failed|did not accept/, error.message,
                     "a rejected code must surface a clear error, not a silent redirect")
      end
    end
  end

  # P1-6: if the watchdog already reaped the child, the reader thread's ensure
  # hits Errno::ECHILD on Process.wait2. The rescue must swallow it so close_io
  # + done=true STILL run — otherwise the PTY fds leak and the session is stuck
  # "in flight" forever. Drive relay_reader directly against a real PTY whose
  # child we reap out from under it first.
  def test_reader_ensure_cleans_up_even_when_child_already_reaped
    auth = Hive::Web::AgentsAuth.new
    reader, writer, pid = PTY.spawn("sh", "-c", "exit 0")
    Process.waitpid(pid) # steal the reap, like the watchdog would
    session = Hive::Web::AgentsAuth::Session.new(
      id: "abc", agent: "claude", pid: pid, io: writer, reader: reader, output: +"", done: false
    )

    # Must not raise Errno::ECHILD even though the child is already gone.
    auth.send(:relay_reader, session, reader, writer, pid)

    assert session.done, "session must be marked done despite the ECHILD on wait"
    assert reader.closed?, "the PTY master must be closed so its fd is reclaimed"
    assert writer.closed?, "the PTY slave must be closed so its fd is reclaimed"
  end

  # P2: a session whose child was already reaped (pid cleared / done) must NOT
  # be signalled by the watchdog — a bare pid kill after pid reuse could SIGKILL
  # an unrelated process (e.g. the daemon). The watchdog reads done under the
  # mutex and skips the kill; we prove no signal is sent for a done session.
  def test_watchdog_does_not_kill_a_reaped_session
    auth = Hive::Web::AgentsAuth.new
    # A live process we own, masquerading as a recycled pid. If the watchdog
    # wrongly signalled it, this would die.
    bystander = Process.spawn("sleep", "5", pgroup: true)
    bystander_pgid = Process.getpgid(bystander)
    session = Hive::Web::AgentsAuth::Session.new(
      id: "z", agent: "claude", pid: bystander, pgid: bystander_pgid, output: +"", done: true
    )

    # done == true means the child was already reaped; the watchdog must bail
    # before signalling, leaving the bystander alive.
    auth.send(:start_watchdog, session).join

    assert process_alive?(bystander), "a reaped (done) session must not be signal-killed"
  ensure
    Process.kill("KILL", -bystander_pgid) rescue nil
    Process.waitpid(bystander) rescue nil
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # P2 (watchdog): a session that never reaches `done` past the deadline must be
  # killed by SIGTERM → SIGKILL on its PROCESS GROUP (not a bare pid). Drive a
  # real child that ignores SIGTERM so the KILL-escalation branch runs, with a
  # tiny timeout so the test doesn't wait LOGIN_TIMEOUT_SEC.
  def test_watchdog_force_kills_a_hung_session_via_its_process_group
    auth = Hive::Web::AgentsAuth.new
    # Traps TERM and keeps sleeping → only the group SIGKILL stops it.
    pid = Process.spawn("sh", "-c", "trap '' TERM; sleep 30", pgroup: true)
    pgid = Process.getpgid(pid)
    session = Hive::Web::AgentsAuth::Session.new(
      id: "h", agent: "claude", pid: pid, pgid: pgid, output: +"", done: false
    )

    auth.send(:start_watchdog, session, timeout: 0.05).join
    # The group KILL must have reaped the hung child.
    assert wait_killed?(pid), "the watchdog must SIGKILL a hung child's process group"
  ensure
    Process.kill("KILL", -pgid) rescue nil
    Process.waitpid(pid) rescue nil
  end

  def wait_killed?(pid)
    deadline = monotonic + 5
    loop do
      _, _ = Process.waitpid2(pid, Process::WNOHANG)
      Process.kill(0, pid)
      return false if monotonic > deadline

      sleep 0.02
    end
  rescue Errno::ESRCH, Errno::ECHILD
    true
  end

  # signal_group must swallow ESRCH (group already gone) — calling it on a pgid
  # that no longer exists must NOT raise.
  def test_signal_group_swallows_a_dead_group
    auth = Hive::Web::AgentsAuth.new
    pid = Process.spawn("true")
    Process.waitpid(pid) # now gone

    # Must not raise even though the group is gone.
    assert_nil auth.send(:signal_group, pid, "TERM"),
               "signalling a dead process group must be a benign no-op"
  end

  # process_group_of must fall back to the pid when the child is already gone
  # (Process.getpgid raises Errno::ESRCH).
  def test_process_group_of_falls_back_to_pid_when_child_gone
    auth = Hive::Web::AgentsAuth.new
    pid = Process.spawn("true")
    Process.waitpid(pid)

    assert_equal pid, auth.send(:process_group_of, pid),
                 "a reaped child has no pgid — fall back to the pid"
  end

  # The reader must scan only newly-arrived data and still detect a URL that
  # arrives AFTER a non-URL preamble (exercising the "no match yet, carry the
  # tail" branch before the URL line lands).
  def install_preamble_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      # Emit a non-URL preamble FIRST and flush, pause so the reader consumes it
      # as its own chunk (exercising the "no URL yet, carry the tail" branch),
      # then emit the URL in a later read.
      echo "Initializing provider handshake..."
      echo "Please open the following link:"
      sleep 0.4
      echo "#{AUTH_URL}"
      read -r code
      [ -n "$code" ] && exit 0
      exit 1
    SH
    FileUtils.chmod(0o755, path)
  end

  def test_url_detected_after_a_non_url_preamble
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_preamble_claude(bin_dir)
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)) do
        auth = Hive::Web::AgentsAuth.new
        session = auth.start("claude")

        found = wait_until { auth.session(session.id).url }
        assert_equal AUTH_URL, found, "a URL after preamble lines must still be detected"
      ensure
        auth.complete(session.id, "x") rescue nil
        wait_until { auth.session(session.id).nil? || auth.session(session.id).done } rescue nil
      end
    end
  end

  # A `claude` that NEVER accepts the code: it keeps re-prompting (stays alive,
  # never logs in). `complete` must time out and surface the "did not accept —
  # still waiting" error rather than a silent redirect.
  def install_reprompting_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      echo "Open #{AUTH_URL} to authenticate"
      while read -r code; do
        echo "that code was not accepted, try again:"
      done
    SH
    FileUtils.chmod(0o755, path)
  end

  def test_login_outcome_times_out_into_a_still_waiting_error
    with_tmp_dir do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_reprompting_claude(bin_dir)
      # HOME points at an empty dir so logged_in? can't false-positive.
      with_env("PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR), "HOME" => dir) do
        auth = Hive::Web::AgentsAuth.new
        session = auth.start("claude")
        wait_until { auth.session(session.id).url }
        auth.session(session.id).io.write("wrong\n")

        # Drive the real outcome wait with a short timeout: the CLI keeps
        # re-prompting (never done, never logged in) → the still-waiting error.
        error = assert_raises(Hive::Error) do
          auth.send(:wait_for_login_outcome, auth.session(session.id), timeout: 0.3)
        end
        assert_match(/did not accept/, error.message,
                     "a never-accepted code must surface a clear still-waiting error")
      ensure
        s = auth.session(session.id) if session
        Process.kill("KILL", -Process.getpgid(s.pid)) rescue nil if s&.pid
      end
    end
  end

  def test_complete_on_a_closed_pty_raises_a_friendly_error
    auth = Hive::Web::AgentsAuth.new
    closed_io = Object.new
    def closed_io.write(*) = raise(IOError, "closed stream")
    session = Hive::Web::AgentsAuth::Session.new(
      id: "deadbeef", agent: "claude", io: closed_io, output: +"", done: false
    )
    auth.instance_variable_get(:@sessions)["deadbeef"] = session

    error = assert_raises(Hive::Error) { auth.complete("deadbeef", "code") }
    assert_match(/already closed/, error.message,
                 "a write to a closed PTY must become a friendly 422, not an opaque 500")
  end
end
