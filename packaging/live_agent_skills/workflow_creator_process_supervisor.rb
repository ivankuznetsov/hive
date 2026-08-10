# frozen_string_literal: true

require "digest"
require "fiddle"
require "fileutils"
require "json"
require "timeout"
require_relative "workflow_creator_capture"

module HiveLiveAgentProof
  module WorkflowCreator
    class ProcessSupervisor
      class Error < StandardError; end

      COMMAND_LABELS = Vocabulary.fetch("command_labels")
      LABELS = (COMMAND_LABELS + %w[outer-workflow-creator outer-authorized-work]).freeze
      LABEL = /\A[a-z][a-z0-9_-]{0,127}\z/
      MAX_IPC_BYTES = 64 * 1024
      MAX_STDIN_BYTES = 16 * 1024
      MAX_DRAIN_READS = 8
      POLL_SECONDS = 0.01
      PR_SET_CHILD_SUBREAPER = 36
      def initialize(correlation_id:, output_limit: 64 * 1024, tail_limit: 4_096, exact_secrets: [],
                     timeout: 120, term_grace: 0.2, kill_grace: 0.2, platform: RUBY_PLATFORM)
        raise Error, "workflow-creator process custody requires Linux" unless platform.include?("linux")
        raise Error, "workflow-creator correlation identity is invalid" unless LABEL.match?(correlation_id.to_s)
        @correlation_id = correlation_id.to_s
        @capture_options = { limit_bytes: positive_integer(output_limit, "output limit"),
                             tail_bytes: positive_integer(tail_limit, "tail limit"),
                             exact_secrets: Values.capture(exact_secrets).value }
        @timeout = positive_float(timeout, "timeout")
        @term_grace = positive_float(term_grace, "TERM grace")
        @kill_grace = positive_float(kill_grace, "KILL grace")
        @launched, @receipts = {}, []
        @state_mutex = Mutex.new
        @workspace = @cleanup = nil
      rescue Values::Error
        raise Error, "workflow-creator exact secrets are invalid"
      end
      def run_command(position:, **options)
        index = Integer(position) - 1
        raise IndexError unless index.between?(0, COMMAND_LABELS.length - 1)
        launch(COMMAND_LABELS.fetch(index), **options)
      rescue ArgumentError, IndexError, TypeError
        raise Error, "workflow-creator command position is invalid"
      end
      def run_outer_workflow_creator(**options) = launch("outer-workflow-creator", **options)
      def run_outer_authorized_work(**options) = launch("outer-authorized-work", **options)
      def receipts = @state_mutex.synchronize { copy(@receipts) }
      def teardown
        launched, receipts = @state_mutex.synchronize { [ @launched.dup, copy(@receipts) ] }
        labels = receipts.map { |row| row.fetch("label") }
        started = launched.any?
        all_received = started && receipts.length == launched.length
        complete = all_received && launched.keys.sort == LABELS.sort && labels.sort == LABELS.sort &&
                   labels.uniq.length == LABELS.length &&
                   receipts.all? { |row| row.dig("teardown", "status") == "passed" }
        copy("status" => started ? (complete ? "passed" : "failed") : "not_started",
             "expected_labels" => LABELS, "receipt_labels" => complete ? LABELS : labels,
             "outer_root_reaped" => all_received,
             "remaining_descendants" => started ? remaining_receipts(receipts) : nil)
      end
      def create_proof_workspace(path)
        raise Error, "proof workspace is already owned" if @workspace
        absolute = File.expand_path(path)
        raise Error, "proof workspace must not pre-exist" if path_exists?(absolute)
        Dir.mkdir(absolute, 0o700)
        stat = File.lstat(absolute)
        raise Error, "proof workspace could not be owned" unless stat.directory? && stat.uid == Process.uid
        @workspace = { "label" => "proof-workspace", "path" => absolute,
                       "path_sha256" => Digest::SHA256.hexdigest(absolute), "device" => stat.dev,
                       "inode" => stat.ino, "created_by_run" => true }
        copy(@workspace)
      rescue SystemCallError
        raise Error, "proof workspace could not be created"
      end
      def cleanup_proof_workspace
        raise Error, "proof workspace was not created" unless @workspace
        stat = File.lstat(@workspace.fetch("path"))
        matched = stat.dev == @workspace.fetch("device") && stat.ino == @workspace.fetch("inode")
        FileUtils.remove_entry_secure(@workspace.fetch("path")) if matched
        finish_cleanup(matched, matched && !path_exists?(@workspace.fetch("path")))
      rescue SystemCallError
        finish_cleanup(false, false)
      end
      private
      def launch(label, executable:, argv:, environment:, cwd:, stdin_data: nil)
        validate_launch!(executable, argv, environment, cwd, stdin_data)
        sequence = @state_mutex.synchronize do
          raise Error, "workflow-creator process label was already launched" if @launched.key?(label)
          @launched[label] = true
          @launched.length
        end
        reader, writer = IO.pipe
        cancel_reader, cancel_writer = IO.pipe
        writer.close_on_exec = true
        custody_pid = Process.fork do
          reader.close
          cancel_writer.close
          custody_child(writer, cancel_reader, label, sequence) do
            supervise(label, executable, argv, environment, cwd, stdin_data, cancel_reader)
          end
        end
        custody_identity = process_start_time(custody_pid)
        cancel_reader.close
        writer.close
        raw = Timeout.timeout(@timeout + @term_grace + @kill_grace + 1) { reader.read(MAX_IPC_BYTES + 1) }
        raise Error, "workflow-creator supervisor receipt exceeded its limit" if raw.bytesize > MAX_IPC_BYTES
        _pid, status = Timeout.timeout(@term_grace + @kill_grace + 1) { Process.wait2(custody_pid) }
        custody_pid = nil
        raise Error, "workflow-creator supervisor custody failed" unless status.success?
        envelope = JSON.parse(raw)
        envelope_valid = envelope.instance_of?(Hash) && envelope.keys.sort ==
          %w[correlation_id label receipt sequence].sort &&
          envelope.values_at("correlation_id", "sequence", "label") == [ @correlation_id, sequence, label ]
        raise Error, "workflow-creator supervisor receipt is invalid" unless envelope_valid
        receipt = envelope.fetch("receipt")
        validate_receipt!(receipt, label)
        @state_mutex.synchronize { @receipts << receipt }
        copy(receipt)
      rescue JSON::ParserError, SystemCallError, Timeout::Error
        raise Error, "workflow-creator supervisor receipt is invalid"
      ensure
        cancel_writer&.close
        settle_custody(custody_pid, custody_identity) if custody_pid
        close_ios(reader, writer, cancel_reader, cancel_writer)
      end
      def custody_child(writer, cancel_reader, label, sequence)
        Process.setsid
        write_payload(writer, "correlation_id" => @correlation_id, "sequence" => sequence,
                              "label" => label, "receipt" => yield)
      rescue Exception # rubocop:disable Lint/RescueException -- the custody child must fail by private IPC
        write_payload(writer, "error" => "supervision_failed")
      ensure
        close_ios(writer, cancel_reader)
        exit! 0
      end
      def supervise(label, executable, argv, environment, cwd, stdin_data, cancel_reader)
        pid = status = nil
        streams = {}
        capture = Capture.new(**@capture_options)
        enable_subreaper!
        raise Error, "supervisor has pre-existing descendants" unless child_pids(Process.pid, true).empty?
        input, input_writer = IO.pipe
        output, output_writer = IO.pipe
        error, error_writer = IO.pipe
        pid = Process.spawn(environment, [ executable, executable ], *argv, chdir: cwd, in: input,
                            out: output_writer, err: error_writer, pgroup: true,
                            unsetenv_others: true, close_others: true)
        raise Error, "process identity custody is unavailable" unless process_start_time(pid)
        close_ios(input, output_writer, error_writer)
        input_writer.write(stdin_data) if stdin_data
        input_writer.close
        streams = { output => :stdout, error => :stderr }
        status = wait_for_root(pid, streams, capture, cancel_reader, monotonic + @timeout)
        timed_out = status.nil?
        status, teardown = teardown_tree(pid, status, streams, capture)
        10.times { break if streams.empty?; drain(streams, capture) }
        { "label" => label, "exit_code" => status&.exitstatus, "signal" => status&.termsig,
          "completed" => !status.nil?, "timed_out" => timed_out, "containment_established" => true,
          "capture" => capture.finish, "teardown" => teardown }
      rescue StandardError
        emergency_teardown(pid, status, streams, capture) if pid
        raise
      ensure
        close_ios(input, input_writer, output, output_writer, error, error_writer)
      end
      def wait_for_root(pid, streams, capture, cancel_reader, deadline)
        status = nil
        until status || monotonic >= deadline
          raise Error, "workflow-creator caller custody was lost" if caller_lost?(cancel_reader)
          status = reap_all(pid, status)
          drain(streams, capture)
        end
        status
      end
      def teardown_tree(root_pid, status, streams, capture)
        targets = descendants
        term_sent = targets.any?
        signal_targets("TERM", targets)
        status, targets = wait_tree(root_pid, status, streams, capture, @term_grace, "TERM")
        kill_sent = targets.any?
        signal_targets("KILL", targets)
        status, targets = wait_tree(root_pid, status, streams, capture, @kill_grace, "KILL")
        reaped = targets.empty? && !status.nil?
        [ status, { "status" => reaped ? "passed" : "failed", "term_sent" => term_sent,
                    "kill_sent" => kill_sent, "reaped" => reaped,
                    "descendants" => targets.empty? ? "none" : "unknown", "owner_complete" => reaped } ]
      end
      def wait_tree(root_pid, status, streams, capture, grace, signal)
        deadline = monotonic + grace
        loop do
          status = reap_all(root_pid, status)
          targets = descendants
          return [ status, targets ] if targets.empty? || monotonic >= deadline
          signal_targets(signal, targets)
          drain(streams, capture)
        end
      end
      def descendants(root_pid = Process.pid, required: true)
        pending = child_pids(root_pid, required)
        seen = {}
        pending.each_with_object([]) do |pid, targets|
          next if seen[pid]
          seen[pid] = true
          identity = process_start_time(pid)
          next unless identity
          targets << { pid: pid, start_time: identity }
          pending.concat(child_pids(pid, false))
        end
      end
      def child_pids(pid, required)
        Dir.children("/proc/#{pid}/task").flat_map do |task|
          File.read("/proc/#{pid}/task/#{task}/children").split.map { |value| Integer(value, 10) }
        rescue Errno::ENOENT
          []
        end.uniq
      rescue Errno::ENOENT
        raise Error, "process-tree custody is unavailable" if required
        []
      rescue SystemCallError, ArgumentError
        raise Error, "process-tree custody is unavailable"
      end

      def process_start_time(pid)
        File.read("/proc/#{pid}/stat").split(") ", 2).fetch(1).split.fetch(19)
      rescue Errno::ENOENT, IndexError
        nil
      end

      def signal_targets(signal, targets)
        targets.each do |target|
          next unless process_start_time(target.fetch(:pid)) == target.fetch(:start_time)
          Process.kill(signal, target.fetch(:pid))
        rescue Errno::ESRCH
          nil
        end
      end

      def reap_all(root_pid, status)
        while (pair = Process.waitpid2(-1, Process::WNOHANG))
          status = pair.fetch(1) if pair.fetch(0) == root_pid
        end
        status
      rescue Errno::ECHILD
        status
      end

      def drain(streams, capture)
        ready = IO.select(streams.keys, nil, nil, POLL_SECONDS)&.first || []
        ready.each do |io|
          MAX_DRAIN_READS.times do
            chunk = io.read_nonblock(8_192, exception: false)
            break if chunk == :wait_readable
            if chunk.nil?
              streams.delete(io)
              io.close
              break
            end
            capture.write(streams.fetch(io), chunk)
          end
        rescue IOError, Errno::EBADF
          streams.delete(io)
        end
      end

      def enable_subreaper!
        function = Fiddle::Function.new(Fiddle::Handle::DEFAULT["prctl"],
                                        [ Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
                                          Fiddle::TYPE_LONG, Fiddle::TYPE_LONG ], Fiddle::TYPE_INT)
        raise Error, "child-subreaper custody is unavailable" unless function.call(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0).zero?
      rescue Fiddle::DLError
        raise Error, "child-subreaper custody is unavailable"
      end

      def validate_launch!(executable, argv, environment, cwd, stdin_data)
        plain = executable.instance_of?(String) && cwd.instance_of?(String) &&
                argv.instance_of?(Array) && argv.all? { |value| safe_string?(value) } &&
                environment.instance_of?(Hash) && environment.all? { |key, value| safe_string?(key) && safe_string?(value) } &&
                (stdin_data.nil? || (stdin_data.instance_of?(String) && stdin_data.bytesize <= MAX_STDIN_BYTES))
        raise Error, "workflow-creator launch inputs are invalid" unless plain
        stat = File.lstat(executable)
        cwd_stat = File.lstat(cwd)
        valid = File.absolute_path(executable) == executable && stat.file? && !stat.symlink? &&
                File.executable?(executable) && File.absolute_path(cwd) == cwd && cwd_stat.directory? &&
                !cwd_stat.symlink? && cwd_stat.uid == Process.uid
        raise Error, "workflow-creator launch inputs are invalid" unless valid
      rescue SystemCallError, ArgumentError
        raise Error, "workflow-creator launch inputs are invalid"
      end

      def validate_receipt!(receipt, label)
        keys = %w[label exit_code signal completed timed_out containment_established capture teardown]
        teardown = receipt["teardown"]
        valid = receipt.instance_of?(Hash) && receipt.keys.sort == keys.sort && receipt["label"] == label &&
                [ true, false ].include?(receipt["completed"]) && receipt["containment_established"] == true &&
                teardown.instance_of?(Hash) && teardown.keys.sort ==
                  %w[status term_sent kill_sent reaped descendants owner_complete].sort
        raise Error, "workflow-creator supervisor receipt is invalid" unless valid
      end

      def write_payload(writer, payload)
        bytes = JSON.generate(payload)
        writer.write(bytes) if bytes.bytesize <= MAX_IPC_BYTES
      rescue SystemCallError, IOError
        nil
      end

      def terminate_custody(pid, identity)
        return unless process_start_time(pid) == identity
        signal_targets("KILL", descendants(pid, required: false))
        Process.kill("KILL", pid)
        Process.waitpid(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def settle_custody(pid, identity)
        Timeout.timeout(@term_grace + @kill_grace + 0.5) { Process.waitpid(pid) }
      rescue Errno::ECHILD
        nil
      rescue Timeout::Error
        terminate_custody(pid, identity)
      end

      def caller_lost?(reader)
        return false unless IO.select([ reader ], nil, nil, 0)
        reader.read_nonblock(1, exception: false).nil?
      rescue IOError, Errno::EBADF
        true
      end

      def emergency_teardown(pid, status, streams, capture)
        teardown_tree(pid, status, streams, capture)
      rescue StandardError
        %w[TERM KILL].each do |signal|
          Process.kill(signal, -pid) rescue nil
          sleep(signal == "TERM" ? @term_grace : @kill_grace)
        end
        reap_all(pid, status)
      end

      def finish_cleanup(matched, removed)
        @cleanup = @workspace.except("path").merge("identity_matched" => matched, "removed" => removed)
        copy(@cleanup)
      end

      def remaining_receipts(receipts) = receipts.count { |row| row.dig("teardown", "descendants") != "none" }
      def safe_string?(value) = value.instance_of?(String) && !value.empty? && !value.include?("\0")
      def path_exists?(path)
        File.lstat(path)
        true
      rescue Errno::ENOENT
        false
      end
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def copy(value) = JSON.parse(JSON.generate(value))
      def close_ios(*ios) = ios.compact.each { |io| io.close unless io.closed? }

      def positive_integer(value, label)
        integer = Integer(value)
        raise Error, "#{label} is invalid" unless integer.positive?
        integer
      rescue ArgumentError, TypeError
        raise Error, "#{label} is invalid"
      end

      def positive_float(value, label)
        number = Float(value)
        raise Error, "#{label} is invalid" unless number.positive? && number.finite?
        number
      rescue ArgumentError, TypeError
        raise Error, "#{label} is invalid"
      end
    end
  end
end
