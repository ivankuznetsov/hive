require "objspace"

module Hive
  module RuntimeControlPlane
    # Coordinates every Sequel checkout with Ruby process creation. Sequel's
    # pool disconnect only closes idle connections, so a fork must first stop
    # new checkouts and prove that no transaction is active.
    module ProcessGuard
      module_function

      def register(database)
        state[:mutex].synchronize { state[:databases][database] = true }
        database
      end

      def checkout(transaction: false)
        current = state
        checked_out = false
        current[:mutex].synchronize do
          current[:condition].wait(current[:mutex]) while
            current[:forking] || current[:fork_waiters].positive?
          current[:checkouts] += 1
          current[:transactions] += 1 if transaction
          owner = (current[:owners][Thread.current] ||= [ 0, 0 ])
          owner[0] += 1
          owner[1] += 1 if transaction
          checked_out = true
        end
        yield
      ensure
        if checked_out
          current[:mutex].synchronize do
            current[:checkouts] -= 1
            current[:transactions] -= 1 if transaction
            owner = current[:owners].fetch(Thread.current)
            owner[0] -= 1
            owner[1] -= 1 if transaction
            current[:owners].delete(Thread.current) if owner[0].zero?
            current[:condition].broadcast if current[:checkouts].zero?
          end
        end
      end

      def before_fork!
        current = state
        databases = current[:mutex].synchronize do
          if current[:owners].key?(Thread.current)
            raise ForkUnsafe, "current thread owns a runtime control-plane checkout"
          end
          current[:fork_waiters] += 1
          begin
            current[:condition].wait(current[:mutex]) while current[:forking]
            if current[:owners].key?(Thread.current)
              raise ForkUnsafe, "current thread owns a runtime control-plane checkout"
            end
            raise ForkUnsafe, "runtime control-plane transaction is active" if
              current[:transactions].positive?

            current[:forking] = true
            current[:fork_owner] = Thread.current
            current[:condition].wait(current[:mutex]) until current[:checkouts].zero?
            database_list(current)
          ensure
            current[:fork_waiters] -= 1
            current[:condition].broadcast
          end
        end
        databases.each(&:disconnect)
        true
      rescue Exception
        after_fork_parent!
        raise
      end

      def after_fork_parent!
        current = state
        current[:mutex].synchronize do
          if current[:fork_owner].equal?(Thread.current)
            current[:forking] = false
            current[:fork_owner] = nil
            current[:condition].broadcast
          end
        end
        true
      end

      # The parent disconnects every handle before the fork. Replace all
      # synchronization objects in the child because mutex state copied from a
      # multi-threaded parent is not safe to reuse.
      def after_fork_child!
        databases = @state ? database_list(@state) : []
        @state = fresh_state
        databases.each { |database| @state[:databases][database] = true }
        true
      end

      def fork(&block)
        before_fork!
        pid = Process.fork do
          after_fork_child!
          block.call
        end
        after_fork_parent!
        pid
      rescue Exception
        after_fork_parent!
        raise
      end

      def daemonize(*arguments)
        before_fork!
        Process.daemon(*arguments)
        after_fork_child!
        true
      rescue Exception
        after_fork_parent!
        raise
      end

      def exec(*arguments, **options)
        before_fork!
        Kernel.exec(*arguments, **options)
      ensure
        after_fork_parent!
      end

      def state
        current = @state
        return current if current && current[:pid] == Process.pid

        @state = fresh_state
      end

      def fresh_state
        mutex = Mutex.new
        {
          pid: Process.pid,
          mutex: mutex,
          condition: ConditionVariable.new,
          databases: ObjectSpace::WeakMap.new,
          checkouts: 0,
          transactions: 0,
          owners: {}.compare_by_identity,
          forking: false,
          fork_owner: nil,
          fork_waiters: 0
        }
      end

      def database_list(current)
        values = []
        current.fetch(:databases).each_key { |database| values << database }
        values
      end
      private_class_method :state, :fresh_state, :database_list
    end
  end
end
