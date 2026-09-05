require "fileutils"
require "tmpdir"
require "rbconfig"
require "shellwords"
require "json"
require "securerandom"
require_relative "../test/support/test_partition"

module HiveTestParallel
  # One host-wide lease bounds aggregate work across simultaneous agent checkouts.
  # The lock lives outside HOME/TMPDIR, which the test helper intentionally changes.
  LOCK_PATH = "/tmp/hive-test-parallel-#{Process.uid}.lock"

  def self.run(files:, root:, workers: ENV.fetch("HIVE_TEST_WORKERS", "2"), component_files: [],
               options: Shellwords.split(ENV.fetch("TESTOPTS", "")), lock_path: LOCK_PATH, output: $stdout)
    count = Integer(workers.to_s, exception: false)
    raise ArgumentError, "HIVE_TEST_WORKERS must be an integer from 1 to 4" unless count&.between?(1, 4)
    raise ArgumentError, "parallel runner does not support coverage; use rake coverage" if ENV["HIVE_COVERAGE"]
    raise ArgumentError, "duplicate test files" unless (files + component_files).uniq == files + component_files

    jobs = HiveTestPartition.partition(files, count: count, root: root).reject(&:empty?).map { |group| [ group, %w[test lib] ] }
    jobs << [ component_files, %w[components/agent-cli-runtime/test components/agent-cli-runtime/lib] ] unless component_files.empty?
    raise ArgumentError, "no test files selected" if jobs.empty?

    FileUtils.mkdir_p(File.join(root, "tmp"))
    logs = Dir.mktmpdir("test-parallel-", File.join(root, "tmp"))
    output.puts "test:parallel: #{files.length + component_files.length} files, #{count} workers; logs: #{logs}"
    File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        output.puts "test:parallel: waiting for another local test run (#{lock_path})"
        output.flush
        lock.flock(File::LOCK_EX)
      end
      execute(jobs, root, count, options, logs, output)
    end
  end

  def self.execute(jobs, root, count, options, logs, output)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    heartbeat = started
    active = {}
    groups = []
    temporary_roots = []
    success = true
    runs = 0
    assertions = 0
    previous = %w[INT TERM].to_h { |signal| [ signal, Signal.trap(signal) { raise Interrupt } ] }
    begin
      until jobs.empty? && active.empty?
        while active.length < count && !jobs.empty?
          files, includes = jobs.shift
          number = groups.length + 1
          log = File.join(logs, "worker-#{number}.log")
          receipt = File.join(logs, "worker-#{number}.json")
          # Keep sockets below Unix path limits and outside any Git checkout:
          # otherwise Git discovery in a disposable non-repository sees Hive.
          begin
            temporary = File.join("/tmp", "ht#{SecureRandom.hex(3)}")
            Dir.mkdir(temporary, 0o700)
          rescue Errno::EEXIST
            retry
          end
          temporary_roots << temporary
          command = [ RbConfig.ruby, "-r", File.expand_path("../test/support/parallel_result", __dir__), *includes.flat_map { |path| [ "-I", File.join(root, path) ] },
            "-e", "ARGV.shift(Integer(ARGV.shift)).each { |file| require File.expand_path(file) }", files.length.to_s, *files, *options ]
          pid = Process.spawn({ "TMPDIR" => temporary, "HIVE_TEST_WORKER" => number.to_s,
            "HIVE_TEST_RESULT" => receipt, "HIVE_REQUIRE_TEST_RUNS" => nil },
            *command, chdir: root, out: log, err: [ :child, :out ], pgroup: true)
          groups << pid
          active[pid] = [ log, files.length, receipt ]
        end
        # Poll only our children: Process.wait2(-1) could reap the caller's children.
        active.keys.each do |pid|
          result = Process.waitpid2(pid, Process::WNOHANG)
          next unless result

          log, file_count, receipt = active.delete(pid)
          status = result.last
          worker_success = status.success?
          begin
            counts = JSON.parse(File.read(receipt))
            valid = %w[runs assertions].all? { |key| counts.is_a?(Hash) && counts[key].is_a?(Integer) && counts[key] >= 0 }
            raise ArgumentError, "invalid worker counts" unless valid
            runs += counts.fetch("runs")
            assertions += counts.fetch("assertions")
          rescue SystemCallError, JSON::ParserError, ArgumentError => error
            output.puts "test:parallel: missing or invalid worker receipt: #{error.message}"
            worker_success = false
          end
          output.puts "test:parallel: #{File.basename(log)} #{worker_success ? 'PASS' : 'FAIL'} (#{file_count} files)"
          summary = nil
          tail = []
          File.foreach(log) do |line|
            summary = line if line.match?(/\d+ runs, \d+ assertions/)
            tail << line
            tail.shift if tail.length > 100
          end
          output.puts summary if summary
          unless worker_success
            success = false
            output.puts tail.join
          end
          output.flush
        end
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now - heartbeat >= 30
          output.puts format("test:parallel: running %.0fs; %d active workers, %d queued jobs", now - started, active.length, jobs.length)
          output.flush
          heartbeat = now
        end
        sleep 0.05 unless active.empty?
      end
      output.puts format("test:parallel: finished in %.2fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      unless runs.positive? && assertions.positive?
        output.puts "test:parallel: selected zero non-skipped tests with assertions"
        success = false
      end
      success
    ensure
      # Group cleanup includes grandchildren, even if their direct parent exited.
      groups.each { |pid| signal_group("TERM", pid) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until active.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        active.delete_if { |pid, _| Process.waitpid(pid, Process::WNOHANG) }
        sleep 0.05 unless active.empty?
      end
      groups.each { |pid| signal_group("KILL", pid) }
      active.each_key { |pid| Process.waitpid(pid) }
      temporary_roots.each { |path| FileUtils.remove_entry(path) if File.exist?(path) }
      previous.each { |signal, handler| Signal.trap(signal, handler) }
    end
  end

  def self.signal_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  files = ARGV.take_while { |argument| !argument.start_with?("-") }
  abort "test_parallel: provide test files" if files.empty?
  ARGV.shift(files.length)
  ARGV.shift if ARGV.first == "--"
  exit(HiveTestParallel.run(files: files, root: Dir.pwd, options: ARGV) ? 0 : 1)
end
