require "socket"

port = Integer(ARGV.fetch(0))
attempt_path = ARGV.fetch(1)
success_path = ARGV.fetch(2)
retry_interval = Float(ARGV.fetch(3, "0.15"))
running = true

Signal.trap("TERM") { running = false }
Signal.trap("INT") { running = false }

append_record = lambda do |path, record|
  File.open(path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
    file.write("#{record}\n")
    file.flush
    file.fsync
  end
end

while running
  begin
    socket = TCPSocket.new("127.0.0.1", port)
    socket.puts("probe")
    if socket.gets&.strip == "ready"
      append_record.call(success_path, "healthy")
      break
    end
  rescue SystemCallError, IOError
    append_record.call(attempt_path, "unavailable")
  ensure
    socket&.close
  end
  sleep retry_interval if running
end

sleep 0.1 while running
