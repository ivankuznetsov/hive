require "test_helper"
require "pty"
require "io/console"
require "timeout"
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
    # Block on `waitpid2` under Timeout instead of a poll+sleep loop.
    # The project's E2E rule (CLAUDE.md) forbids hard-coded sleeps in
    # integration tests; a blocking wait under Timeout is the
    # canonical alternative — the child either exits before the
    # deadline (Process.wait2 returns) or `Timeout::Error` fires and
    # we return nil so the caller can decide.
    Timeout.timeout(deadline_seconds) do
      _pid, status = Process.waitpid2(pid)
      status
    end
  rescue Timeout::Error
    nil
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
          buffer = read_until(reader, deadline_seconds: 5.0) { |buf| buf.include?("Choose project for new idea") }
          assert_includes buffer, "Choose project for new idea"

          writer.write("\r")
          writer.flush
          buffer = read_until(reader, deadline_seconds: 5.0) { |buf| buf.include?("New idea") }
          assert_includes buffer, "New idea"

          writer.write("bug here ")
          writer.write("\e[200~\e[201~")
          writer.write(", on mobile looks like ")
          writer.write("\e[200~\e[201~")
          writer.write(" and desktop ")
          writer.write("\e[200~\e[201~")
          writer.flush

          # Pre-submit assertion: the composer's prompt badge must
          # show "3 images" before Enter is pressed. Splitting from
          # the post-submit grid check ensures both are observed —
          # the previous "OR bug-here" form let a fast CI runner skip
          # the badge entirely once the post-submit slug landed.
          begin
            badge_buffer = read_until(reader, deadline_seconds: 10.0) { |buf| buf.include?("3 images") }
            assert_includes badge_buffer, "3 images",
              "composer prompt badge must show `[3 images]` before submit"

            writer.write("\r")
            writer.flush
            grid_buffer = read_until(reader, deadline_seconds: 10.0) { |buf| buf.include?("bug-here") }
            assert_includes grid_buffer, "bug-here",
              "post-submit grid must show the bug-here slug row"

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
        assert_includes idea, "bug here ![](assets/bug-1.png), on mobile looks like ![](assets/bug-2.png) and desktop ![](assets/bug-3.png)"

        (1..3).each do |i|
          expected = File.binread(File.join(__dir__, "..", "fixtures", "composer", "screenshot-#{i}.png"))
          assert_equal expected, File.binread(File.join(task, "assets", "bug-#{i}.png"))
        end

        # Plan / smoke-test contract pin: `git commit` must capture
        # `idea.md` plus every `assets/bug-N.png`, not just the
        # markdown. The commit lands in the `.hive-state` git repo
        # (separate worktree), so query that one, not the project
        # root. A regression where the TUI rich-submit `git add`s
        # only idea.md would silently break the multimodal handoff —
        # the brainstorm subprocess gets the asset arguments but the
        # commit history has nothing to back them up.
        hive_state_dir = File.join(dir, ".hive-state")
        git_files = `git -C #{hive_state_dir} log -1 --name-only --pretty=format: HEAD`
          .lines.map(&:chomp).reject(&:empty?)
        assert(
          git_files.any? { |f| f.end_with?("idea.md") },
          "TUI rich-submit commit must include idea.md (got: #{git_files.inspect})"
        )
        (1..3).each do |i|
          assert(
            git_files.any? { |f| f.end_with?("assets/bug-#{i}.png") },
            "TUI rich-submit commit must include assets/bug-#{i}.png " \
            "(got: #{git_files.inspect})"
          )
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
        # R10 multimodal handoff: assets must land somewhere inside
        # an argv element, not just appear as a fake-claude header
        # field (cwd=, date). Reject anything that surfaces only in
        # the per-invocation header by splitting the log at the first
        # `arg=` line and grepping only that tail.
        argv_tail = argv_log.split(/^arg=/m, 2)[1].to_s
        (1..3).each do |i|
          assert_includes argv_tail, "assets/bug-#{i}.png",
            "fake-claude argv (after first `arg=` marker) must contain " \
            "assets/bug-#{i}.png; a regression that smuggles the path into " \
            "the per-invocation header rather than an argv element would " \
            "otherwise pass the bare substring check"
        end
      ensure
        FileUtils.rm_rf(log_dir) if log_dir
      end
    end
  end

  def test_ctrl_v_stages_clipboard_image_and_submit_persists_asset
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        project_prefix = project[0, 12]

        env = {
          "TERM" => "xterm-256color",
          "HIVE_TUI_TEST_CLIPBOARD" => "fixture://screenshot-1.png",
          "HIVE_TUI_TEST_CLIPBOARD_BASE" => File.expand_path("../fixtures/composer", __dir__),
          "HIVE_TUI_TEST_CLIPBOARD_STRICT" => "1"
        }
        PTY.spawn(env, "ruby", "-I", HIVE_LIB, HIVE_BIN, "tui") do |reader, writer, pid|
          reader.winsize = [ 30, 120 ]

          buffer = read_until(reader, deadline_seconds: 10.0) { |buf| buf.include?(project_prefix) }
          assert_includes buffer, project_prefix

          writer.write("n")
          writer.flush
          buffer = read_until(reader, deadline_seconds: 5.0) { |buf| buf.include?("Choose project for new idea") }
          assert_includes buffer, "Choose project for new idea"

          writer.write("\r")
          writer.flush
          buffer = read_until(reader, deadline_seconds: 5.0) { |buf| buf.include?("New idea") }
          assert_includes buffer, "New idea"

          writer.write("ctrl v image ")
          writer.write("\x16")
          writer.flush

          badge_buffer = read_until(reader, deadline_seconds: 10.0) { |buf| buf.include?("1 image") }
          assert_includes badge_buffer, "1 image",
            "composer prompt badge must show `[1 image]` after Ctrl-V"

          writer.write("\r")
          writer.flush
          grid_buffer = read_until(reader, deadline_seconds: 10.0) { |buf| buf.include?("ctrl-v-image") }
          assert_includes grid_buffer, "ctrl-v-image",
            "post-submit grid must show the ctrl-v-image slug row"

          writer.write("q")
          writer.flush
          status = wait_for_pid_exit(pid, deadline_seconds: 3.0)
          refute_nil status
          assert_equal 0, status.exitstatus
        rescue Errno::EIO
          # Linux PTY drain after the child exits can raise once the
          # slave end closes. The post-block filesystem assertions
          # below still prove the submit path completed.
        end

        task = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "ctrl-v-image-*")].first
        refute_nil task, "Ctrl-V image submit must create an inbox task"
        idea = File.read(File.join(task, "idea.md"))
        assert_includes idea, "ctrl v image ![](assets/bug-1.png)"

        expected = File.binread(File.join(__dir__, "..", "fixtures", "composer", "screenshot-1.png"))
        asset = File.join(task, "assets", "bug-1.png")
        assert File.size?(asset), "Ctrl-V image submit must persist a non-empty PNG asset"
        assert_equal expected, File.binread(asset)
      end
    end
  end
end
