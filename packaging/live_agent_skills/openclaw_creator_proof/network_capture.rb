module HiveLiveAgentProof
  module OpenClawCreatorProof
    class NetworkCapture
      SOCKET_LIMIT = 64
      SAMPLE_INTERVAL = 0.01
      STOP_GRACE = 1.0
      TABLES = {
        "/proc/net/tcp" => "tcp4",
        "/proc/net/tcp6" => "tcp6",
        "/proc/net/udp" => "udp4",
        "/proc/net/udp6" => "udp6"
      }.freeze

      def initialize(root_pid, process_tree: nil)
        @root_pid = root_pid
        @process_tree = process_tree || ProcessTree.new(root_pid: root_pid)
        @sockets = {}
        @sample_count = 0
        @available = TABLES.keys.all? { |path| File.file?(path) }
        @stopped = false
      end

      def start
        @thread = Thread.new do
          until @stopped
            sample
            sleep SAMPLE_INTERVAL
          end
          sample
        end
        @thread.report_on_exception = false
      end

      def stop
        @stopped = true
        return true unless @thread
        unless @thread.join(STOP_GRACE)
          raise Failure.new(
            phase: "process",
            reason: "containment_failed",
            detail: "network capture thread did not stop"
          )
        end

        @thread.value
        true
      rescue Failure
        raise
      rescue StandardError => e
        raise Failure.new(
          phase: "process",
          reason: "containment_failed",
          detail: "network capture thread failed: #{e.class}: #{e.message}"
        )
      end

      def record
        {
          "status" => @available ? "observed" : "unavailable",
          "sample_count" => @sample_count,
          "socket_count" => @sockets.length,
          "sockets" => @sockets.values.sort_by {
            |row| [ row.fetch("protocol"), row.fetch("remote"), row.fetch("state") ]
          }
        }
      end

      private

      def sample
        return unless @available

        table = socket_table
        socket_inodes.each do |inode|
          row = table[inode]
          @sockets[inode] = row if row && @sockets.length < SOCKET_LIMIT
        end
        @sample_count += 1
      rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
        nil
      end

      def socket_table
        TABLES.each_with_object({}) do |(path, protocol), rows|
          File.readlines(path, chomp: true).drop(1).each do |line|
            fields = line.split
            next unless fields.length >= 10

            rows[fields.fetch(9)] = {
              "protocol" => protocol,
              "remote" => fields.fetch(2),
              "state" => fields.fetch(3)
            }
          end
        end
      end

      def socket_inodes
        @process_tree.pids(include_root: true, include_zombies: true).flat_map do |pid|
          Dir.glob("/proc/#{pid}/fd/*").filter_map do |path|
            target = File.readlink(path)
            match = /\Asocket:\[(\d+)\]\z/.match(target)
            match && match[1]
          rescue Errno::ENOENT, Errno::EACCES
            nil
          end
        end.uniq
      end
    end
  end
end
