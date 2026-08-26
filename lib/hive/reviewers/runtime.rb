module Hive::Reviewers::Runtime
  MAX_OUTPUT_BYTES = 4 * 1024 * 1024

  Result = Struct.new(:stdout, :exit_code, :error) do
    def success? = error.nil? && exit_code&.zero? || false
  end

  module_function

  def capture(environment:, argv:, chdir:, timeout_sec:, timeout_message:)
    pipe_r, pipe_w = IO.pipe
    pid = Process.spawn(
      environment, *argv, chdir:, pgroup: true, out: pipe_w, err: pipe_w
    )
    pipe_w.close

    reader = Thread.new do
      output = +"".b
      while (chunk = pipe_r.read(65_536))
        output << chunk if output.bytesize < MAX_OUTPUT_BYTES
      end
      output.byteslice(0, MAX_OUTPUT_BYTES)
    end

    status = wait(pid, timeout_sec)
    unless status
      terminate(pid)
      reader.join(2)
      reader.kill if reader.alive?
      pipe_r.close unless pipe_r.closed?
      return Result.new(nil, nil, timeout_message)
    end

    output = reader.value.to_s
    pipe_r.close unless pipe_r.closed?
    output = output.dup.force_encoding(Encoding::UTF_8)
    output.scrub!("?")
    Result.new(output, status.exitstatus, nil)
  end

  def write(path, content) = File.write(path, content)

  def delete(path, label:)
    File.delete(path)
  rescue Errno::ENOENT
    nil
  rescue SystemCallError => error
    raise Hive::Error,
          "#{label}: failed to clear partial output_path #{path}: " \
          "#{error.class}: #{error.message}"
  end

  def wait(pid, timeout_sec)
    deadline = Time.now + timeout_sec
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      return if Time.now > deadline

      sleep 0.05
    end
  end

  def terminate(pid)
    pgid = Process.getpgid(pid)
    Process.kill("TERM", -pgid)
    sleep 1
    Process.kill("KILL", -pgid) if process_group_alive?(pgid)
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    nil
  ensure
    reap(pid)
  end

  def process_group_alive?(pgid)
    Process.kill(0, -pgid)
    true
  rescue Errno::ESRCH, Errno::ECHILD
    false
  rescue Errno::EPERM
    true
  end

  def reap(pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end
end
