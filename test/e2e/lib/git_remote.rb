require "socket"

module Hive
  module E2E
    # Real Git transport on loopback, including the hardened publication gate.
    class GitRemote
      attr_reader :url

      def initialize(root:)
        @server = TCPServer.new("127.0.0.1", 0)
        @url = "git://127.0.0.1:#{@server.addr[1]}/acme/app.git"
        @thread = Thread.new do
          loop do
            client = @server.accept
            begin
              @pid = Process.spawn("git", "daemon", "--inetd", "--export-all",
                "--enable=receive-pack", "--base-path=#{root}",
                in: client, out: client, err: File::NULL)
              Process.wait(@pid)
            ensure
              @pid = nil
              client.close
            end
          end
        rescue IOError, Errno::EBADF
          # Closing the listener ends the accept loop during harness teardown.
        end
      end

      def stop
        @server.close
        pid = @pid
        Process.kill("TERM", pid) if pid
        @thread.join(2)
      rescue Errno::ESRCH
        @thread.join(2)
      end
    end
  end
end
