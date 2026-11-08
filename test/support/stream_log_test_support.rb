module StreamLogTestSupport
  class DelegatingIO
    def initialize(io)
      @io = io
    end

    def syswrite(bytes) = @io.syswrite(bytes)
    def pread(length, offset) = @io.pread(length, offset)
    def flush = @io.flush
    def flock(operation) = @io.flock(operation)
    def stat = @io.stat
    def fsync = @io.fsync
    def chmod(mode) = @io.chmod(mode)
    def close = @io.close
    def closed? = @io.closed?
  end

  def seed_torn_tail(path, bytes = "torn")
    File.open(path, "ab") { |file| file.write(bytes) }
  end
end
