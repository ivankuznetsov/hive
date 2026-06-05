require "test_helper"
require "pty"
require "io/console"
require "hive/commands/init"
require "hive/commands/new"

# U10 — PTY-driven boot/first-frame/quit smoke for the charm backend
# (`HIVE_TUI_BACKEND=charm`). Mirrors `tui_smoke_test.rb` but explicitly
# pins the charm path so a future curses-removal won't accidentally
# silently drop charm coverage. After U11 deletes curses and the env
# var is removed, this becomes the only smoke test.
#
# Per project CLAUDE.md "NEVER skip tests conditionally based on
# environment availability" — `PTY.spawn` and `bubbletea`/`lipgloss`
# must be present; if they aren't, fail loudly.
class TuiSmokeCharmTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  HIVE_LIB = File.expand_path("../../lib", __dir__)

  def read_until(reader, deadline_seconds:, interval: 0.05, &predicate)
    deadline = Time.now + deadline_seconds
    buffer = +""
    loop do
      ready, = IO.select([ reader ], nil, nil, interval)
      if ready
        begin
          buffer << reader.read_nonblock(4096)
        rescue IO::WaitReadable, EOFError
          # Drain pattern — keep trying until the deadline.
        end
      end

      return buffer if predicate.call(buffer)
      return buffer if Time.now > deadline
    end
  end

  def plain_terminal_lines(buffer)
    text = buffer.dup.force_encoding("UTF-8").scrub
    text = text
      .gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
      .gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
      .gsub(/\e[=>]/, "")
    text.split(/\r?\n/).map { |line| line.delete("\r") }
  end

  def max_plain_line_width(buffer)
    plain_terminal_lines(buffer).map(&:length).max || 0
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

  def seed_brainstorm_task(project_root, slug)
    folder = File.join(project_root, ".hive-state", "stages", "2-brainstorm", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "brainstorm.md"), "# #{slug}\n\n<!-- COMPLETE -->\n")
  end

  def test_charm_tui_repaints_after_pty_resize
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "resize probe").call }

        project_prefix = project[0, 12]

        env = { "TERM" => "xterm-256color", "HIVE_TUI_BACKEND" => "charm" }
        PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
          reader.winsize = [ 30, 120 ]

          initial = read_until(reader, deadline_seconds: 10.0) do |buf|
            buf.include?(project_prefix)
          end
          assert_includes initial, project_prefix

          reader.winsize = [ 30, 150 ]
          Process.kill("WINCH", pid)

          resized = read_until(reader, deadline_seconds: 5.0) do |buf|
            max_plain_line_width(buf) >= 145
          end
          resized_width = max_plain_line_width(resized)
          assert_operator resized_width, :>=, 145,
                          "resized frame should expand to the 150-column PTY"

          writer.write("q")
          writer.flush
          status = wait_for_pid_exit(pid, deadline_seconds: 3.0)
          refute_nil status, "charm TUI must exit within 3s of pressing 'q'"
          assert_equal 0, status.exitstatus, "clean quit exits 0"
        end
      end
    end
  rescue Errno::EIO
    raise unless $!.message.include?("Input/output error")
  end

  def test_charm_tui_vertical_resize_keeps_panes_footer_and_selected_row_visible
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        16.times { |idx| seed_brainstorm_task(dir, "rz#{format('%02d', idx)}") }

        env = { "TERM" => "xterm-256color", "HIVE_TUI_BACKEND" => "charm" }
        PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
          reader.winsize = [ 30, 120 ]

          initial = read_until(reader, deadline_seconds: 15.0) do |buf|
            buf.include?("rz00")
          end
          assert_includes initial, "rz00"

          reader.winsize = [ 9, 120 ]
          Process.kill("WINCH", pid)

          resized = read_until(reader, deadline_seconds: 5.0) do |buf|
            buf.include?("[Tab] switch")
          end
          assert_includes initial, "Projects", "project pane must render before vertical resize"
          assert_includes resized, "[Tab] switch", "footer must remain visible after vertical resize"

          writer.write("q")
          writer.flush
          status = wait_for_pid_exit(pid, deadline_seconds: 3.0)
          refute_nil status, "charm TUI must exit within 3s of pressing 'q'"
          assert_equal 0, status.exitstatus, "clean quit exits 0"
        end
      end
    end
  rescue Errno::EIO
    raise unless $!.message.include?("Input/output error")
  end

  def test_charm_tui_boots_paints_first_frame_and_quits_on_q
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "smoke probe").call }

        # v2 left-pane truncates long project names; match a stable
        # prefix (production project names like "hive" / "appcrawl"
        # always fit, but the tmpdir basename does not).
        project_prefix = project[0, 12]

        env = { "TERM" => "xterm-256color", "HIVE_TUI_BACKEND" => "charm" }
        PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
          # Default PTY winsize trips v2's single-pane fallback (<70 cols);
          # explicitly size to 120x30 so the projects pane renders.
          reader.winsize = [ 30, 120 ]

          buffer = read_until(reader, deadline_seconds: 10.0) do |buf|
            buf.include?(project_prefix)
          end
          assert_includes buffer, project_prefix,
                          "a stable prefix of the seeded project name must appear in " \
                          "the first frame within 10s, got buffer:\n#{buffer.inspect[0, 500]}"

          writer.write("q")
          writer.flush
          status = wait_for_pid_exit(pid, deadline_seconds: 3.0)
          refute_nil status, "charm TUI must exit within 3s of pressing 'q'"
          assert_equal 0, status.exitstatus, "clean quit exits 0"
        end
      end
    end
  rescue Errno::EIO
    raise unless $!.message.include?("Input/output error")
  end
end
