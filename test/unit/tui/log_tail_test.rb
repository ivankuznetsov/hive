require "test_helper"
require "tmpdir"
require "fileutils"
require "hive/tui/log_tail"

# `Hive::Tui::LogTail::FileResolver` and `Hive::Tui::LogTail::Tail` are
# the headless filesystem layer behind the TUI's log-viewer mode. These
# tests exercise them against real files (no mocks) so the rotation /
# truncation / non-blocking-read paths are pinned the same way they
# behave under live `hive run` agents writing into `<state>/logs/<slug>/`.
class TuiLogTailTest < Minitest::Test
  include HiveTestHelper

  def with_log_dir
    Dir.mktmpdir("hive-tui-logs") do |dir|
      yield(dir)
    end
  end

  # ---------- FileResolver ----------

  def test_latest_returns_file_with_newest_mtime
    with_log_dir do |dir|
      a = File.join(dir, "execute-20260101T000000Z.log")
      b = File.join(dir, "execute-20260102T000000Z.log")
      c = File.join(dir, "execute-20260103T000000Z.log")
      [ a, b, c ].each { |path| File.write(path, "content for #{File.basename(path)}\n") }
      now = Time.now
      File.utime(now - 300, now - 300, a)
      File.utime(now - 200, now - 200, b)
      File.utime(now - 100, now - 100, c)

      assert_equal c, Hive::Tui::LogTail::FileResolver.latest(dir),
                   "newest mtime wins regardless of filename ordering"
    end
  end

  def test_latest_raises_no_log_files_on_empty_directory
    with_log_dir do |dir|
      err = assert_raises(Hive::NoLogFiles) { Hive::Tui::LogTail::FileResolver.latest(dir) }
      assert_match(/no log files in/, err.message)
    end
  end

  def test_latest_ignores_non_log_files
    with_log_dir do |dir|
      File.write(File.join(dir, "stray.txt"), "not a log\n")
      assert_raises(Hive::NoLogFiles) { Hive::Tui::LogTail::FileResolver.latest(dir) }
    end
  end

  # The TOCTOU race between Dir[] glob and File.mtime on a rotating
  # log directory used to surface as Errno::ENOENT crashing the TUI.
  # Reproduce the race by overriding Dir.[] to return a path that no
  # longer exists alongside a real one; `latest` must skip the missing
  # entry rather than raise.
  def with_dir_glob_returning(paths)
    original = Dir.method(:[])
    Dir.singleton_class.define_method(:[]) { |*_args| paths }
    yield
  ensure
    Dir.singleton_class.define_method(:[], original)
  end

  def test_latest_skips_path_that_vanishes_between_glob_and_stat
    with_log_dir do |dir|
      survivor = File.join(dir, "execute-keep.log")
      File.write(survivor, "still here\n")
      doomed_path = File.join(dir, "execute-doomed.log")

      with_dir_glob_returning([ doomed_path, survivor ]) do
        assert_equal survivor, Hive::Tui::LogTail::FileResolver.latest(dir),
                     "latest must skip vanished candidates rather than raise Errno::ENOENT"
      end
    end
  end

  # If every candidate has vanished, the helper falls back to the same
  # NoLogFiles raise an empty glob produces — matching the existing
  # render-mode boundary that flashes "no log files yet".
  def test_latest_raises_no_log_files_when_every_candidate_vanished
    with_log_dir do |dir|
      with_dir_glob_returning([ File.join(dir, "ghost.log") ]) do
        assert_raises(Hive::NoLogFiles) { Hive::Tui::LogTail::FileResolver.latest(dir) }
      end
    end
  end

  def test_latest_handles_concurrent_log_rotation
    with_log_dir do |dir|
      original = File.join(dir, "execute.log")
      File.write(original, "phase one\n")
      now = Time.now
      File.utime(now - 60, now - 60, original)

      rotated = File.join(dir, "execute.log.1")
      FileUtils.mv(original, rotated)
      File.write(original, "phase two\n")
      File.utime(now, now, original)

      # `*.log` glob does NOT match `execute.log.1` so the rotated copy
      # is invisible to the resolver — that's the desired behavior.
      assert_equal original, Hive::Tui::LogTail::FileResolver.latest(dir)
    end
  end

  # ---------- Tail ----------

  def test_tail_open_primes_buffer_with_existing_lines
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "alpha\nbravo\ncharlie\n")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      assert_equal %w[alpha bravo charlie], tail.lines(10)
    ensure
      tail&.close!
    end
  end

  def test_tail_poll_picks_up_appended_lines
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "first\n")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      assert_equal [ "first" ], tail.lines(10)

      File.open(path, "a") { |f| f.puts "second"; f.puts "third" }
      tail.poll!

      assert_equal %w[first second third], tail.lines(10)
    ensure
      tail&.close!
    end
  end

  def test_tail_poll_handles_truncation_without_crash
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "before\ntruncate\n")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      assert_equal %w[before truncate], tail.lines(10)

      # Truncate to 0 then write a new line — same inode, smaller size.
      File.truncate(path, 0)
      File.open(path, "a") { |f| f.puts "after-truncate" }

      tail.poll!
      lines = tail.lines(10)
      assert_includes lines, "after-truncate", "post-truncate appends must surface"
      # Pre-truncate lines must still be in the buffer — we deliberately
      # preserve the last good frame across truncation so the user
      # doesn't see a blank screen flash.
      assert_includes lines, "before", "pre-truncate buffer must be preserved"
      assert_includes lines, "truncate", "pre-truncate buffer must be preserved"
    ensure
      tail&.close!
    end
  end

  def test_tail_poll_detects_inode_rotation_and_reopens
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "old-content\n")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      assert_equal [ "old-content" ], tail.lines(10)

      # Atomically replace the file with a new inode.
      FileUtils.mv(path, File.join(dir, "x.log.1"))
      File.write(path, "new-content\n")

      tail.poll!
      lines = tail.lines(10)
      assert_includes lines, "new-content",
                      "rotation must surface bytes from the new inode"
    ensure
      tail&.close!
    end
  end

  def test_tail_lines_with_count_zero_returns_empty
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "anything\n")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      assert_equal [], tail.lines(0)
    ensure
      tail&.close!
    end
  end

  def test_tail_buffer_is_capped_at_ring_capacity
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      contents = (1..50).map { |i| "line-#{i}" }.join("\n") + "\n"
      File.write(path, contents)

      tail = Hive::Tui::LogTail::Tail.new(path, ring_capacity: 10, backbuffer_bytes: 1024 * 1024)
      tail.open!
      lines = tail.lines(20)
      assert_equal 10, lines.size, "ring capacity bounds the buffer"
      assert_equal "line-50", lines.last, "newest line retained when trimming"
    ensure
      tail&.close!
    end
  end

  # A still-running agent often flushes byte-by-byte and the final
  # in-flight line lacks a trailing newline. Surfacing the partial
  # makes live writes visible in the tail viewer before the writer
  # commits the line terminator.
  def test_tail_lines_surfaces_trailing_partial_line
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "first\nsecond\nno-newline-here")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      assert_equal %w[first second no-newline-here], tail.lines(10)
    ensure
      tail&.close!
    end
  end

  def test_tail_close_is_safe_to_call_twice
    with_log_dir do |dir|
      path = File.join(dir, "x.log")
      File.write(path, "x\n")
      tail = Hive::Tui::LogTail::Tail.new(path)
      tail.open!
      tail.close!
      tail.close! # must not raise
    end
  end
end
