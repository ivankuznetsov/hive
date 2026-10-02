require "test_helper"
require "hive/attempts/stream_log"

class AttemptsStreamLogRecoveryTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  class BlockingWriter
    def initialize(io, held:, release:)
      @io = io
      @held = held
      @release = release
      @blocked = false
    end

    def syswrite(bytes)
      unless @blocked
        @blocked = true
        @held.write("H")
        @held.flush
        raise IOError, "parent closed the append release gate" unless @release.read(1) == "G"
      end

      @io.syswrite(bytes)
    end

    def flush = @io.flush
    def flock(operation) = @io.flock(operation)
    def stat = @io.stat
    def fsync = @io.fsync
    def close = @io.close
    def closed? = @io.closed?
  end

  def test_independently_opened_processes_serialize_torn_tail_recovery
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    with_tmp_dir do |root|
      path = File.join(root, "logs", "attempt.frames")
      seed = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
      seed.append(:stdout, "seed")
      seed.close
      File.open(path, "ab") { |file| file.write("torn") }

      first_ready_r, first_ready_w = IO.pipe
      first_start_r, first_start_w = IO.pipe
      first_held_r, first_held_w = IO.pipe
      first_release_r, first_release_w = IO.pipe
      first_result_r, first_result_w = IO.pipe
      second_ready_r, second_ready_w = IO.pipe
      second_start_r, second_start_w = IO.pipe
      second_attempted_r, second_attempted_w = IO.pipe
      second_result_r, second_result_w = IO.pipe
      all_ios = [
        first_ready_r, first_ready_w, first_start_r, first_start_w,
        first_held_r, first_held_w, first_release_r, first_release_w,
        first_result_r, first_result_w, second_ready_r, second_ready_w,
        second_start_r, second_start_w, second_attempted_r, second_attempted_w,
        second_result_r, second_result_w
      ]
      pids = []
      reaped = []

      first_pid = fork do
        close_unowned_pipe_ends(
          all_ios, [ first_ready_w, first_start_r, first_held_w, first_release_r, first_result_w ]
        )
        run_first_contender(
          path: path, ready: first_ready_w, start: first_start_r,
          held: first_held_w, release: first_release_r, result: first_result_w
        )
      end
      pids << first_pid

      second_pid = fork do
        close_unowned_pipe_ends(
          all_ios, [ second_ready_w, second_start_r, second_attempted_w, second_result_w ]
        )
        run_second_contender(
          path: path, ready: second_ready_w, start: second_start_r,
          attempted: second_attempted_w, result: second_result_w
        )
      end
      pids << second_pid

      [
        first_ready_w, first_start_r, first_held_w, first_release_r, first_result_w,
        second_ready_w, second_start_r, second_attempted_w, second_result_w
      ].each(&:close)

      Timeout.timeout(2) do
        assert_equal "R", first_ready_r.read(1)
        assert_equal "R", second_ready_r.read(1)
      end

      first_start_w.write("S")
      first_start_w.close
      assert_equal "H", Timeout.timeout(2) { first_held_r.read(1) }
      File.open(path, "ab") do |probe|
        refute probe.flock(File::LOCK_EX | File::LOCK_NB),
               "the first child must hold the real advisory lock while publication is gated"
      end

      second_start_w.write("S")
      second_start_w.close
      assert_equal "A", Timeout.timeout(2) { second_attempted_r.read(1) }
      first_release_w.write("G")
      first_release_w.close

      results = [ first_result_r, second_result_r ].map do |reader|
        JSON.parse(Timeout.timeout(3) { reader.gets })
      end
      statuses = pids.map do |pid|
        waited_pid, status = Timeout.timeout(3) { Process.wait2(pid) }
        reaped << waited_pid
        status
      end
      assert statuses.all?(&:success?), results.map { |result| result["error"] }.compact.join("\n")
      assert_equal [ 2, 3 ], results.map { |result| result.fetch("sequence") }.sort

      frames = Hive::Attempts::StreamLog.read(path)
      assert_equal [ 1, 2, 3 ], frames.map(&:sequence)
      assert_equal %w[child-a child-b], frames.drop(1).map(&:bytes).sort
      lower_sequence, higher_sequence = results.map { |result| result.fetch("sequence") }.sort
      incremental = Hive::Attempts::StreamLog.read(path, after_sequence: lower_sequence)
      assert_equal [ higher_sequence ], incremental.map(&:sequence)
      assert_equal 1, incremental.length
    ensure
      all_ios&.each do |io|
        io.close unless io.closed?
      rescue IOError
        nil
      end
      pids&.each do |pid|
        next if reaped&.include?(pid)

        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  private

  def close_unowned_pipe_ends(all_ios, owned)
    all_ios.each { |io| io.close unless owned.include?(io) }
  end

  def run_first_contender(path:, ready:, start:, held:, release:, result:)
    log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
    writer = BlockingWriter.new(log.instance_variable_get(:@io), held: held, release: release)
    log.instance_variable_set(:@io, writer)
    ready.write("R")
    ready.flush
    raise IOError, "parent closed the first start gate" unless start.read(1) == "S"

    sequence = log.append(:stdout, "child-a")
    log.close
    result.write(JSON.generate("sequence" => sequence) + "\n")
    result.close
    exit! 0
  rescue StandardError => error
    result.write(JSON.generate("error" => "#{error.class}: #{error.message}") + "\n") rescue nil
    exit! 1
  end

  def run_second_contender(path:, ready:, start:, attempted:, result:)
    log = Hive::Attempts::StreamLog.new(path, clock: -> { NOW })
    ready.write("R")
    ready.flush
    raise IOError, "parent closed the second start gate" unless start.read(1) == "S"

    attempted.write("A")
    attempted.flush
    sequence = log.append(:stdout, "child-b")
    log.close
    result.write(JSON.generate("sequence" => sequence) + "\n")
    result.close
    exit! 0
  rescue StandardError => error
    result.write(JSON.generate("error" => "#{error.class}: #{error.message}") + "\n") rescue nil
    exit! 1
  end
end
