require "test_helper"
require "stringio"
require "hive/tui/io_capture"

# IoCapture replaces the per-caller `orig = $stdout; $stdout = StringIO.new;
# ... $stdout = orig` pattern after Patrol traced a real corruption: the
# archive refresher thread's `capture_status_io` and the TUI update thread's
# `capture_command_io` both swapped the process-global `$stdout`, and their
# `ensure` blocks could restore each other's throwaway buffers as the
# "original" binding — permanently black-holing all later output. These tests
# pin the coordinated-registry contract, including the exact interleaving
# from the finding.
class TuiIoCaptureTest < Minitest::Test
  # Deterministic two-thread replay of the reported race: A installs its
  # buffer, B enters while A is active (under the old pattern B would capture
  # A's buffer as its "original"), then A exits BEFORE B. The final restore
  # must land on the true original bindings, never on any capture's buffer.
  def test_overlapping_captures_restore_original_stdout_when_inner_exits_last
    original_out = $stdout
    original_err = $stderr

    a_installed = SizedQueue.new(1)
    b_entered = SizedQueue.new(1)

    inner = Thread.new do
      a_installed.pop
      Hive::Tui::IoCapture.capture do
        b_entered.push(true)
        $stdout.puts "inner output discarded"
      end
    end

    Hive::Tui::IoCapture.capture do
      a_installed.push(true)
      b_entered.pop
      $stdout.puts "outer output discarded"
    end
    # Outer (A) has now fully exited while inner (B) may still be finishing;
    # join guarantees B's ensure has run too.
    inner.join

    assert_same original_out, $stdout,
      "$stdout must be restored to the pre-capture binding"
    assert_same original_err, $stderr,
      "$stderr must be restored to the pre-capture binding"
  end

  # Mirror of the above with the exit order swapped: B (which entered second,
  # so never installed) exits first while A is still inside its block; A's
  # own exit must then restore the originals.
  def test_overlapping_captures_restore_original_stdout_when_inner_exits_first
    original_out = $stdout
    original_err = $stderr

    a_installed = SizedQueue.new(1)

    inner = Thread.new do
      a_installed.pop
      Hive::Tui::IoCapture.capture do
        $stdout.puts "inner output discarded"
      end
    end

    Hive::Tui::IoCapture.capture do
      a_installed.push(true)
      join_within(inner, seconds: 2.0)
      $stdout.puts "outer output discarded"
    end
    inner.join

    assert_same original_out, $stdout
    assert_same original_err, $stderr
  end

  def test_sequential_capture_discards_output_and_restores_bindings
    original_out = $stdout
    original_err = $stderr

    Hive::Tui::IoCapture.capture do
      $stdout.puts "discarded out"
      $stderr.puts "discarded err"
    end

    assert_same original_out, $stdout
    assert_same original_err, $stderr
  end

  def test_capture_requires_block
    assert_raises(ArgumentError) { Hive::Tui::IoCapture.capture }
  end

  def test_concurrent_captures_never_leak_a_buffer_into_global_bindings
    original_out = $stdout
    original_err = $stderr

    threads = Array.new(8) do
      Thread.new do
        25.times do
          Hive::Tui::IoCapture.capture do
            $stdout.puts "noise"
            $stderr.puts "noise"
          end
        end
      end
    end
    threads.each(&:join)

    assert_same original_out, $stdout
    assert_same original_err, $stderr
  end

  private

  # Project rules forbid unbounded bare sleeps in tests; this bounds a join
  # so a regression that deadlocks the handoff fails instead of hanging the
  # suite. The ordering itself comes from the SizedQueue handoff above.
  def join_within(thread, seconds:)
    deadline = Time.now + seconds
    thread.join(deadline - Time.now)
    flunk("capture thread did not finish within #{seconds}s") if thread.alive?
  end
end
