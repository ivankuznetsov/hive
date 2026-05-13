require "test_helper"
require "pty"
require "io/console"
require "hive/commands/init"
require "hive/commands/run"

class TuiNewIdeaAttachmentsSmokeTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)
  HIVE_LIB = File.expand_path("../../lib", __dir__)
  FAKE_CLAUDE = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @old_claude_bin = ENV["HIVE_CLAUDE_BIN"]
    @old_fake_log_dir = ENV["HIVE_FAKE_CLAUDE_LOG_DIR"]
    @old_fake_write_file = ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"]
    @old_fake_write_content = ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"]
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @old_claude_bin
    ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = @old_fake_log_dir
    ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = @old_fake_write_file
    ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = @old_fake_write_content
  end

  def read_until(reader, deadline_seconds:, interval: 0.05, &predicate)
    deadline = Time.now + deadline_seconds
    buffer = +""
    loop do
      ready, = IO.select([ reader ], nil, nil, interval)
      if ready
        begin
          buffer << reader.read_nonblock(4096)
        rescue IO::WaitReadable, EOFError
          nil
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

  # Per project CLAUDE.md "NEVER skip tests conditionally based on
  # environment availability" — PTY is stdlib (Linux + macOS always
  # provide it) and bin/hive is part of the repo. If those break the
  # test should fail loudly, not silently skip.
  def test_paste_three_images_submit_and_brainstorm_sees_asset_refs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        project_prefix = project[0, 12]

        env = {
          "TERM" => "xterm-256color",
          "HIVE_TUI_TEST_CLIPBOARD" => "fixture://screenshot-1.png,screenshot-2.png,screenshot-3.png",
          "HIVE_TUI_TEST_CLIPBOARD_BASE" => File.expand_path("../fixtures/composer", __dir__)
        }
        PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
          reader.winsize = [ 30, 120 ]

          buffer = read_until(reader, deadline_seconds: 10.0) { |buf| buf.include?(project_prefix) }
          assert_includes buffer, project_prefix

          writer.write("n")
          writer.flush
          buffer = read_until(reader, deadline_seconds: 5.0) { |buf| buf.include?("New idea") }
          assert_includes buffer, "New idea"

          writer.write("bug here ")
          writer.write("\e[200~\e[201~")
          writer.write(", on mobile looks like ")
          writer.write("\e[200~\e[201~")
          writer.write(" and desktop ")
          writer.write("\e[200~\e[201~")
          writer.write("\r")
          writer.flush

          begin
            buffer = read_until(reader, deadline_seconds: 10.0) do |buf|
              buf.include?("3 images") || buf.include?("bug-here")
            end
            assert_match(/3 images|bug-here/, buffer)

            writer.write("q")
            writer.flush
            status = wait_for_pid_exit(pid, deadline_seconds: 3.0)
            refute_nil status
            assert_equal 0, status.exitstatus
          rescue Errno::EIO
            # Linux PTY drain after the child exits and closes the slave
            # end raises EIO from `read_nonblock`. Scope the rescue
            # tightly so the post-block idea.md / asset / brainstorm
            # assertions still run — a premature EIO at startup must
            # NOT silently pass the test.
          end
        end

        task = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "bug-here-*")].first
        refute_nil task, "rich TUI submit must create an inbox task"
        idea = File.read(File.join(task, "idea.md"))
        assert_includes idea, "bug here ![](assets/image-1.png), on mobile looks like ![](assets/image-2.png) and desktop ![](assets/image-3.png)"

        (1..3).each do |i|
          expected = File.binread(File.join(__dir__, "..", "fixtures", "composer", "screenshot-#{i}.png"))
          assert_equal expected, File.binread(File.join(task, "assets", "image-#{i}.png"))
        end

        target = File.join(dir, ".hive-state", "stages", "2-brainstorm", File.basename(task))
        FileUtils.mv(task, target)
        brainstorm_md = File.join(target, "brainstorm.md")
        log_dir = Dir.mktmpdir("hive-fake-claude")
        ENV["HIVE_CLAUDE_BIN"] = FAKE_CLAUDE
        ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = brainstorm_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n### Q1. What is visible?\n### A1.\n\n<!-- WAITING -->\n"

        capture_io { Hive::Commands::Run.new(target).call }

        argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
        assert_includes argv_log, "cwd=#{target}"
        assert_includes argv_log, "assets/image-1.png"
        assert_includes argv_log, "assets/image-2.png"
        assert_includes argv_log, "assets/image-3.png"
      ensure
        FileUtils.rm_rf(log_dir) if log_dir
      end
    end
  end
end
