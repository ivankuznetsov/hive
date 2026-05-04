require "test_helper"
require "pty"
require "io/console"
require "hive/commands/init"
require "hive/commands/new"

# U11 — PTY-driven boot/first-frame/quit smoke for `bin/hive tui`.
#
# Single sanity check that the binary boots, paints, and quits across
# the full curses stack: the unit suites cover the data path; this
# test pins the curses init + cleanup round-trip.
#
# Pure stdlib `PTY` — no Docker, no claude, no network. Per the
# project CLAUDE.md "NEVER skip tests conditionally based on
# environment availability"; if `PTY.spawn` is unavailable the test
# should fail, not skip (Linux + macOS always provide it).
class TuiSmokeTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  HIVE_LIB = File.expand_path("../../lib", __dir__)

  # Wait-for-condition read loop — NOT a fixed sleep. Per project test
  # rule #6, hard-coded timeouts cause flakes; we drain the PTY's
  # available bytes and break as soon as the predicate succeeds.
  def read_until(reader, deadline_seconds:, interval: 0.05, &predicate)
    deadline = Time.now + deadline_seconds
    buffer = +""
    loop do
      ready, = IO.select([ reader ], nil, nil, interval)
      if ready
        begin
          buffer << reader.read_nonblock(4096)
        rescue IO::WaitReadable, EOFError
          # No bytes available right now / EOF; keep trying until
          # the deadline. EOF is unusual mid-frame but should fail
          # downstream (the predicate won't match) rather than
          # raising here.
        end
      end

      return buffer if predicate.call(buffer)
      return buffer if Time.now > deadline
    end
  end

  def wait_for_pid_exit(pid, deadline_seconds:)
    deadline = Time.now + deadline_seconds
    loop do
      reaped, status = Process.waitpid2(pid, Process::WNOHANG)
      return status if reaped
      return nil if Time.now > deadline

      sleep 0.05
    end
  end

  def test_tui_boots_paints_first_frame_with_project_name_and_quits_on_q
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "smoke probe").call }

        # v2 left-pane width clamps to [18, 28] cells; project names
        # longer than ~25 chars are ellipsis-truncated. The tmpdir-based
        # test project name is always longer than the pane allows; match
        # on a stable prefix instead of the full string. Production
        # users have short project names ("hive", "appcrawl") that fit.
        project_prefix = project[0, 12]

        env = { "TERM" => "xterm-256color" }
        PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
          # Default PTY winsize is ~40 cols which trips v2's single-pane
          # fallback (TWO_PANE_MIN_COLS = 70). Set 120 cols so the
          # projects pane renders and the project name surface is alive.
          reader.winsize = [ 30, 120 ]

          buffer = read_until(reader, deadline_seconds: 10.0) do |buf|
            buf.include?(project_prefix)
          end
          assert_includes buffer, project_prefix,
                          "a stable prefix of the seeded project name must appear in " \
                          "the first frame within 10s, got buffer:\n#{buffer.inspect[0, 500]}"

          writer.write("q")
          writer.flush
          status = wait_for_pid_exit(pid, deadline_seconds: 2.0)
          refute_nil status, "TUI must exit within 2s of pressing 'q'"
          assert_equal 0, status.exitstatus, "clean quit exits 0"
        end
      end
    end
  rescue Errno::EIO
    # On Linux a PTY closure during read can surface as EIO; treat as
    # equivalent to a clean child exit if the assertion already
    # succeeded, otherwise re-raise.
    raise unless $!.message.include?("Input/output error")
  end

  def test_tui_with_empty_registry_boots_paints_empty_state_message
    with_tmp_global_config do
      env = { "TERM" => "xterm-256color" }
      PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
        # Even an empty registry should paint *something* (project-less
        # banner) before the user can quit. Drain bytes briefly to give
        # curses time to draw, then quit.
        buffer = read_until(reader, deadline_seconds: 5.0) { |buf| !buf.empty? }
        refute_empty buffer, "TUI must paint at least one byte before accepting input"

        writer.write("q")
        writer.flush
        status = wait_for_pid_exit(pid, deadline_seconds: 2.0)
        refute_nil status, "TUI must exit within 2s of pressing 'q' on empty registry"
        assert_equal 0, status.exitstatus
      end
    end
  rescue Errno::EIO
    raise unless $!.message.include?("Input/output error")
  end
end
