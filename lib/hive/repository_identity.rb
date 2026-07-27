require "pathname"
require "uri"

module Hive
  module RepositoryIdentity
    LOOKUP_TIMEOUT_SECONDS = 2.0
    LOOKUP_POLL_SECONDS = 0.01
    LOOKUP_TERM_GRACE_SECONDS = 0.1

    module_function

    def normalize(remote, base_path: nil)
      value = remote.to_s.strip
      return nil if value.empty?

      if !value.include?("://") &&
          (scp = value.match(/\A(?:[^@\s\/]+@)?(?<host>[^:\/\s]+):(?<path>[^\s]+)\z/))
        return network_identity(scp[:host], scp[:path])
      end

      uri = URI.parse(value)
      return local_identity(uri.path, base_path) if uri.scheme == "file"
      if uri.scheme && uri.host
        host = uri.host
        host = "#{host}:#{uri.port}" if non_default_port?(uri)
        return network_identity(host, uri.path)
      end

      local_identity(value, base_path)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def current(project_root, timeout_sec: LOOKUP_TIMEOUT_SECONDS)
      stdout, status = capture_origin(
        File.expand_path(project_root), timeout_sec: timeout_sec
      )
      return nil unless status&.success?

      normalize(stdout, base_path: project_root)
    rescue SystemCallError, IOError
      nil
    end

    def origin_absent?(project_root, timeout_sec: LOOKUP_TIMEOUT_SECONDS)
      _stdout, status = capture_origin(
        File.expand_path(project_root), timeout_sec: timeout_sec
      )
      status&.exitstatus == 2
    rescue SystemCallError, IOError
      false
    end

    def capture_origin(project_root, timeout_sec:)
      stdout_r, stdout_w = IO.pipe
      pid = Process.spawn(
        { "GIT_TERMINAL_PROMPT" => "0" },
        "git", "-C", project_root, "remote", "get-url", "origin",
        in: :close, out: stdout_w, err: File::NULL, pgroup: true
      )
      stdout_w.close
      deadline = monotonic_now + timeout_sec
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return [ stdout_r.read, waited[1] ] if waited
        break if monotonic_now >= deadline

        sleep LOOKUP_POLL_SECONDS
      end

      terminate_process_group(pid)
      [ "", nil ]
    ensure
      [ stdout_w, stdout_r ].each { |io| close_io(io) }
    end

    def terminate_process_group(pid)
      signal_process_group("TERM", pid)
      deadline = monotonic_now + LOOKUP_TERM_GRACE_SECONDS
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return if waited
        break if monotonic_now >= deadline

        sleep LOOKUP_POLL_SECONDS
      end
      signal_process_group("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end

    def signal_process_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def close_io(io)
      io.close if io && !io.closed?
    rescue IOError
      nil
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def network_identity(host, path)
      normalized_path = path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "").sub(/\.git\z/i, "")
      return nil if host.to_s.empty? || normalized_path.empty?

      "#{host.downcase}/#{normalized_path}"
    end

    def local_identity(path, base_path)
      return nil if path.to_s.strip.empty?

      expanded = if Pathname.new(path).absolute?
        File.expand_path(path)
      else
        File.expand_path(path, base_path || Dir.pwd)
      end
      canonical = File.realpath(expanded)
      "local:#{canonical}"
    rescue SystemCallError
      "local:#{expanded}"
    end

    def non_default_port?(uri)
      return false unless uri.port

      defaults = { "http" => 80, "https" => 443, "ssh" => 22, "git" => 9418 }
      defaults[uri.scheme] != uri.port
    end
  end
end
