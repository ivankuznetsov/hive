module HiveLiveAgentProof
  module OpenClawCreatorProof
    class ProcessTree
      def initialize(root_pid:, proc_root: "/proc")
        @root_pid = Integer(root_pid)
        @proc_root = proc_root
      end

      def pids(include_root: false, include_zombies: false)
        parent_map, states = snapshot
        queue = Array(parent_map[@root_pid]).dup
        visited = Set.new
        descendants = []
        until queue.empty?
          pid = queue.shift
          next unless visited.add?(pid)

          descendants << pid if include_zombies || states[pid] != "Z"
          queue.concat(Array(parent_map[pid]))
        end
        include_root ? [ @root_pid, *descendants ] : descendants
      end

      private

      def snapshot
        parent_map = Hash.new { |hash, key| hash[key] = [] }
        states = {}
        Dir.glob(File.join(@proc_root, "[0-9]*", "stat")).each do |path|
          pid, parent_pid, state = identity(path)
          parent_map[parent_pid] << pid
          states[pid] = state
        rescue Errno::ENOENT, Errno::EACCES, ArgumentError, IndexError
          next
        end
        [ parent_map, states ]
      end

      def identity(path)
        stat = File.read(path)
        suffix = stat[(stat.rindex(")") + 2)..]
        fields = suffix.split
        [
          Integer(File.basename(File.dirname(path)), 10),
          Integer(fields.fetch(1), 10),
          fields.fetch(0)
        ]
      end
    end
  end
end
