require "set"

module Hive
  module Attempts
    ProcessTableSnapshot = Data.define(:session_ids, :process_group_ids) do
      def session_alive?(session_id) = session_ids.include?(Integer(session_id))
      def process_group_alive?(process_group_id) = process_group_ids.include?(Integer(process_group_id))
    end

    # One host-wide read of every visible process's session and process group,
    # from Linux procfs. It is the absence evidence used where no delegated
    # cgroup custody exists: a session id that no live process carries proves
    # that nothing which stayed in that session (every descendant that did not
    # call setsid) is still running.
    #
    # Returns nil, never a partial snapshot, when procfs is unavailable or any
    # process entry is unreadable, so callers keep their rows fail-closed.
    module ProcessTable
      module_function

      def snapshot(proc_root: "/proc")
        return nil unless File.file?(File.join(proc_root, "self", "stat"))

        sessions = Set.new
        groups = Set.new
        Dir.children(proc_root).each do |entry|
          next unless entry.match?(/\A\d+\z/)

          fields = stat_fields(File.join(proc_root, entry, "stat"))
          next unless fields

          groups << Integer(fields.fetch(2))
          sessions << Integer(fields.fetch(3))
        end
        ProcessTableSnapshot.new(session_ids: sessions.freeze, process_group_ids: groups.freeze)
      rescue SystemCallError, IOError, ArgumentError, TypeError, IndexError
        nil
      end

      # Fields after "pid (comm) ": state ppid pgrp session ...; comm may itself
      # contain ") ", so split at the last closing parenthesis. A process that
      # exited between listing and reading is simply absent.
      def stat_fields(path)
        data = File.read(path)
        close = data.rindex(")")
        raise ArgumentError, "unparseable process stat #{path}" unless close

        data[(close + 1)..].split
      rescue Errno::ENOENT, Errno::ESRCH
        nil
      end
    end
  end
end
