require "test_helper"
require "open3"
require_relative "../../script/test_parallel"

class TestParallelTest < Minitest::Test
  include HiveTestHelper

  def run_parallel(**arguments)
    with_env("HIVE_COVERAGE" => nil) { HiveTestParallel.run(**arguments) }
  end
  def test_processes_run_every_file_once_with_isolated_temporary_state_and_propagate_failure
    Dir.mktmpdir("parallel-proof") do |root|
      files = 4.times.map do |i|
        file = "sample_#{i}_test.rb"
        File.write(File.join(root, file), <<~RUBY)
          File.open(#{File.join(root, "receipt-#{i}").inspect}, "a") { |io| io.puts [Process.pid, ENV.fetch("TMPDIR")].join("\n") }
          class Worker#{i} < Minitest::Test
            def test_receipt
              require "socket"
              socket = UNIXServer.new(File.join(ENV.fetch("TMPDIR"), "worker-#{i}.sock"))
              socket.close
              refute system("git", "-C", ENV.fetch("TMPDIR"), "rev-parse", "--is-inside-work-tree",
                            out: File::NULL, err: File::NULL), "worker temp root must be outside Git"
              assert #{i} != 3, "intentional worker failure"
            end
          end
        RUBY
        file
      end
      system("git", "init", "-q", root, exception: true)
      output = StringIO.new
      refute run_parallel(files: files, root: root, workers: 2,
        lock_path: File.join(root, "lock"), output: output)
      receipts = Dir[File.join(root, "receipt-*")].map { |path| File.readlines(path).map(&:strip) }
      assert_equal 4, receipts.length
      assert receipts.all? { |receipt| receipt.length == 2 }, "each file must execute exactly once"
      assert_equal 2, receipts.map(&:first).uniq.length
      assert_equal 2, receipts.map(&:last).uniq.length
      receipts.each { |receipt| assert_operator receipt.last.bytesize, :<, 20 }
      assert_includes output.string, "intentional worker failure"
      assert_equal 2, Dir[File.join(root, "tmp", "test-parallel-*", "worker-*.log")].length
    end
  end

  def test_component_suite_is_a_separate_successful_process
    Dir.mktmpdir("parallel-component") do |root|
      File.write(File.join(root, "root_test.rb"), "COMPONENT_CONFLICT = 'root'\nclass RootTest < Minitest::Test; def test_root = assert true; end\n")
      File.write(File.join(root, "component_test.rb"), "class ComponentTest < Minitest::Test; def test_component = refute defined?(COMPONENT_CONFLICT); end\n")
      assert run_parallel(files: [ "root_test.rb" ], component_files: [ "component_test.rb" ],
        root: root, workers: 1, lock_path: File.join(root, "lock"), output: StringIO.new)
    end
  end

  def test_rejects_invalid_workers_before_launch
    [ "abc", "0", "5", "-1", "2.5" ].each do |workers|
      assert_raises(ArgumentError) { HiveTestParallel.run(files: [], root: Dir.pwd, workers: workers) }
    end
    assert_raises(ArgumentError) { HiveTestParallel.run(files: [], root: Dir.pwd) }
  end

  def test_filtered_runs_allow_empty_workers_but_require_an_aggregate_result
    Dir.mktmpdir("parallel-filter") do |root|
      File.write(File.join(root, "first_test.rb"), "class FirstTest < Minitest::Test; def test_first = assert true; end")
      File.write(File.join(root, "second_test.rb"), "class SecondTest < Minitest::Test; def test_second = assert true; end")
      File.write(File.join(root, "component_test.rb"), "class ComponentTest < Minitest::Test; def test_component = assert true; end")
      arguments = { files: %w[first_test.rb second_test.rb], component_files: [ "component_test.rb" ],
                    root: root, workers: 2, lock_path: File.join(root, "lock"), output: StringIO.new }
      assert run_parallel(**arguments, options: [ "--name", "test_first" ]), arguments[:output].string
      assert run_parallel(**arguments, options: [ "--name", "test_component" ]), arguments[:output].string
      refute run_parallel(**arguments, options: [ "--name", "test_missing" ])
    end
  end

  def test_forked_children_cannot_write_the_worker_receipt
    Dir.mktmpdir("parallel-fork") do |root|
      File.write(File.join(root, "fork_test.rb"), <<~RUBY)
        class ForkTest < Minitest::Test
          def test_receipt_owner
            child = fork do
              HiveParallelResult::Reporter.new(ENV.fetch("HIVE_TEST_RESULT")).report
              exit! 0
            end
            Process.wait(child)
            refute File.exist?(ENV.fetch("HIVE_TEST_RESULT"))
          end
        end
      RUBY
      output = StringIO.new
      assert run_parallel(files: [ "fork_test.rb" ], root: root,
        lock_path: File.join(root, "lock"), output: output), output.string
    end
  end

  def test_early_successful_exit_without_a_worker_receipt_fails
    Dir.mktmpdir("parallel-no-receipt") do |root|
      File.write(File.join(root, "early_test.rb"), "exit! 0")
      output = StringIO.new
      refute run_parallel(files: [ "early_test.rb" ], root: root, lock_path: File.join(root, "lock"), output: output)
      assert_includes output.string, "missing or invalid worker receipt"
    end
  end

  def test_host_lease_waits_until_another_run_releases_it
    Dir.mktmpdir("parallel-lease") do |root|
      lock_path = File.join(root, "lock")
      receipt = File.join(root, "ran")
      File.write(File.join(root, "sample_test.rb"), "File.write(#{receipt.inspect}, 'done')")
      script = <<~RUBY
        require #{File.expand_path('../../script/test_parallel', __dir__).inspect}
        HiveTestParallel.run(files: ['sample_test.rb'], root: #{root.inspect}, lock_path: #{lock_path.inspect})
      RUBY
      File.open(lock_path, "w") do |lock|
        lock.flock(File::LOCK_EX)
        Open3.popen2e({ "HIVE_COVERAGE" => nil }, RbConfig.ruby, "-e", script) do |stdin, stdout, wait|
          stdin.close
          assert_match(/logs:/, stdout.gets)
          assert_match(/waiting for another local test run/, stdout.gets)
          refute File.exist?(receipt)
          lock.flock(File::LOCK_UN)
          stdout.read
          assert wait.value.success?
          assert File.exist?(receipt)
        end
      end
    end
  end

  def test_interrupt_kills_the_worker_process_group
    Dir.mktmpdir("parallel-interrupt") do |root|
      receipt = File.join(root, "receipt")
      File.write(File.join(root, "slow_test.rb"), <<~RUBY)
        ready, signal = IO.pipe
        child = fork do
          ready.close
          trap("TERM") {}
          signal.write("ready")
          signal.close
          sleep 60
        end
        signal.close
        ready.read
        ready.close
        File.write(#{receipt.inspect}, [Process.pid, child].join("\n"))
        sleep 60
      RUBY
      script = <<~RUBY
        require #{File.expand_path('../../script/test_parallel', __dir__).inspect}
        begin
          HiveTestParallel.run(files: ['slow_test.rb'], root: #{root.inspect}, lock_path: #{File.join(root, 'lock').inspect})
        rescue Interrupt
          exit 130
        end
      RUBY
      pid = Process.spawn({ "HIVE_COVERAGE" => nil }, RbConfig.ruby, "-e", script, out: File::NULL, err: File::NULL)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until File.exist?(receipt)
        raise "worker did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
      descendants = File.readlines(receipt).map(&:to_i)
      Process.kill("INT", pid)
      _, status = Process.waitpid2(pid)
      assert_equal 130, status.exitstatus
      descendants.each do |child|
        # Linux can retain an orphaned zombie briefly until init reaps it.
        stat = File.read("/proc/#{child}/stat") if File.exist?("/proc/#{child}/stat")
        assert stat.nil? || stat.split[2] == "Z", "child #{child} still running"
      end
    ensure
      Process.kill("KILL", pid) rescue nil
    end
  end
end
