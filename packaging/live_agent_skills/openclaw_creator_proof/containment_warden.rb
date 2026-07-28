module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ContainmentWarden
      PR_SET_CHILD_SUBREAPER = 36
      PR_GET_CHILD_SUBREAPER = 37

      attr_reader :kill_sent, :term_sent

      def self.ensure_available!
        available = RUBY_PLATFORM.include?("linux") &&
                    File.directory?("/proc") &&
                    Process.respond_to?(:fork)
        return if available

        raise Failure.new(
          phase: "process",
          reason: "containment_unavailable",
          detail: "Linux /proc child-subreaper containment is required"
        )
      end

      def initialize(root_pid:, budget:, process_tree: nil)
        @budget = budget
        @process_tree = process_tree || ProcessTree.new(root_pid: root_pid)
        @term_sent = false
        @kill_sent = false
      end

      def enable_child_subreaper!
        handle = Fiddle::Handle::DEFAULT
        function = Fiddle::Function.new(
          handle["prctl"],
          [
            Fiddle::TYPE_INT, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG,
            Fiddle::TYPE_LONG, Fiddle::TYPE_LONG
          ],
          Fiddle::TYPE_INT
        )
        state = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        state[0, Fiddle::SIZEOF_INT] = [ 0 ].pack("i")
        configured = function.call(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0).zero?
        observed =
          function.call(PR_GET_CHILD_SUBREAPER, state.to_i, 0, 0, 0).zero? &&
          state[0, Fiddle::SIZEOF_INT].unpack1("i") == 1
        return if configured && observed

        raise Failure.new(
          phase: "process",
          reason: "containment_unavailable",
          detail: "cannot establish and verify Linux child-subreaper containment"
        )
      rescue Fiddle::DLError => e
        raise Failure.new(
          phase: "process",
          reason: "containment_unavailable",
          detail: "cannot load Linux process containment: #{e.message}"
        )
      end

      def terminate_worker(worker)
        signal_process(worker, "CONT")
        record_signal(
          "TERM",
          signal_process(worker, "TERM") || signal_descendants("TERM")
        )
        return if wait_until_descendants_gone(@budget.term_grace)

        record_signal(
          "KILL",
          signal_process(worker, "KILL") || signal_descendants("KILL")
        )
        wait_until_descendants_gone(@budget.post_kill_grace)
      end

      def terminate_group(pgid, signal)
        record_signal(
          signal,
          signal_group(pgid, signal) || signal_descendants(signal)
        )
      end

      def drain_remaining_descendants
        return [] if descendants.empty?

        record_signal("TERM", signal_descendants("TERM"))
        return [] if wait_until_descendants_gone(@budget.term_grace)

        record_signal("KILL", signal_descendants("KILL"))
        wait_until_descendants_gone(@budget.post_kill_grace)
        descendants
      end

      # The outer subreaper uses only its current direct, unreaped children as
      # signal authority. Once one exits, Linux reparents its surviving child
      # generation to this root and the next pass discovers that generation.
      # A PID cannot be reused until we reap it, and no PID is retained across
      # a reap.
      def drain_child_domain
        term_deadline = monotonic_now + @budget.term_grace
        return [] if drain_direct_children("TERM", deadline: term_deadline)

        kill_deadline = monotonic_now + @budget.post_kill_grace
        drain_direct_children("KILL", deadline: kill_deadline)
        reap_adopted_children
        return [] if child_domain_empty?

        @process_tree.pids(include_zombies: true)
      end

      def wait_until_descendants_gone(seconds)
        deadline = monotonic_now + seconds
        loop do
          reap_adopted_children
          return true if descendants.empty?
          return false if monotonic_now >= deadline

          sleep 0.01
        end
      end

      def descendants
        @process_tree.pids
      end

      def reap_specific(pid, nonblock: false)
        flags = nonblock ? Process::WNOHANG : 0
        waited, status = Process.wait2(pid, flags)
        waited ? status : nil
      rescue Errno::ECHILD
        nil
      end

      def reap_adopted_children
        loop do
          pid = Process.waitpid(-1, Process::WNOHANG)
          break unless pid
        end
      rescue Errno::ECHILD
        nil
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      end

      private

      def drain_direct_children(signal, deadline:)
        loop do
          reap_adopted_children
          return true if child_domain_empty?

          children = @process_tree.direct_pids
          children.each { |pid| signal_process(pid, "CONT") }
          sent = false
          children.each { |pid| sent = signal_process(pid, signal) || sent }
          record_signal(signal, sent)
          reap_adopted_children
          return true if child_domain_empty?
          return false if monotonic_now >= deadline

          sleep 0.01
        end
      end

      def child_domain_empty?
        loop do
          return false unless @process_tree.direct_pids.empty?

          waited = Process.waitpid(-1, Process::WNOHANG)
          return false unless waited
        end
      rescue Errno::ECHILD
        true
      end

      def signal_descendants(signal)
        signalled = false
        descendants.reverse_each do |pid|
          Process.kill(signal, pid)
          signalled = true
        rescue Errno::ESRCH
          nil
        end
        signalled
      end

      def signal_process(pid, signal)
        Process.kill(signal, pid)
        true
      rescue Errno::ESRCH
        false
      end

      def signal_group(pgid, signal)
        Process.kill(signal, -pgid)
        true
      rescue Errno::ESRCH
        false
      end

      def record_signal(signal, sent)
        @term_sent ||= sent if signal == "TERM"
        @kill_sent ||= sent if signal == "KILL"
        sent
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
