# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "installed_target"

module HiveReleaseCandidate
  class ProcessTeardown
    DEFAULT_OUTPUT_LIMIT = 64 * 1024
    DEFAULT_TIMEOUT = 120
    TERM_GRACE = 0.2
    KINDS = %w[daemon tui web service producer observer candidate].freeze

    def initialize(output_limit: DEFAULT_OUTPUT_LIMIT, timeout: DEFAULT_TIMEOUT,
                   process_alive: nil, service_active: nil, service_stopper: nil,
                   signaler: nil, sleeper: nil)
      @output_limit = Integer(output_limit)
      @timeout = Float(timeout)
      raise UsageError, "output limit must be positive" unless @output_limit.positive?
      raise UsageError, "process timeout must be positive" unless @timeout.positive?

      @process_alive = process_alive || method(:process_alive?)
      @service_active = service_active || ->(_name) { false }
      @service_stopper = service_stopper || ->(_name) { }
      @signaler = signaler || ->(signal, target) { Process.kill(signal, target) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def capture(target:, argv:, environment:, cwd:, label:)
      validate_target!(target)
      validate_argv!(argv)
      root = safe_directory!(cwd, "process working directory")
      stdout = +""
      stderr = +""
      stdout_truncated = false
      stderr_truncated = false
      status = nil
      timed_out = false

      Open3.popen3(
        environment, target.executable, *argv,
        chdir: root, pgroup: true, unsetenv_others: true
      ) do |stdin, out, err, waiter|
        stdin.close
        out_reader = Thread.new { read_bounded(out) }
        err_reader = Thread.new { read_bounded(err) }
        status = waiter.join(@timeout)&.value
        unless status
          timed_out = true
          terminate_group(waiter.pid)
          status = waiter.value
        end
        stdout, stdout_truncated = out_reader.value
        stderr, stderr_truncated = err_reader.value
      end

      {
        "label" => label.to_s,
        "role" => target.role,
        "argv" => argv.dup,
        "status" => status.success? && !timed_out ? "passed" : "failed",
        "exit_status" => status.exitstatus,
        "timed_out" => timed_out,
        "stdout" => stdout,
        "stderr" => stderr,
        "stdout_truncated" => stdout_truncated,
        "stderr_truncated" => stderr_truncated
      }
    rescue SystemCallError => e
      raise Error, "cannot execute installed #{target.role} target: #{e.message}"
    end

    def verify!(processes:, services:)
      process_records = Array(processes).map { |record| normalize_process(record) }
      service_names = Array(services).map(&:to_s).uniq.sort

      process_records.each do |record|
        next unless @process_alive.call(record.fetch("pid"))
        terminate_group(record.fetch("pgid"))
      end
      service_names.each do |name|
        @service_stopper.call(name) if @service_active.call(name)
      end

      leaked_processes = process_records.select { |record| @process_alive.call(record.fetch("pid")) }
      leaked_services = service_names.select { |name| @service_active.call(name) }
      unless leaked_processes.empty? && leaked_services.empty?
        labels = leaked_processes.map { |record| "#{record.fetch('kind')}:#{record.fetch('pid')}" }
        labels.concat(leaked_services.map { |name| "service:#{name}" })
        raise Error, "upgrade teardown leaked #{labels.join(', ')}"
      end

      {
        "status" => "passed",
        "process_count" => process_records.size,
        "service_count" => service_names.size,
        "leaks" => []
      }
    end

    private

    def validate_target!(target)
      role = target.respond_to?(:role) ? target.role.to_s : nil
      executable = target.respond_to?(:executable) ? target.executable.to_s : nil
      unless InstalledTarget::ROLES.include?(role) && !executable.to_s.empty?
        raise UsageError, "process capture requires a role-bound installed target"
      end
    end

    def validate_argv!(argv)
      unless argv.is_a?(Array) && argv.all? do |item|
        item.is_a?(String) && !item.empty? && !item.include?("\0")
      end
        raise UsageError, "installed target arguments must be a safe argv array"
      end
    end

    def safe_directory!(value, label)
      path = File.expand_path(value)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise Error, "#{label} must be an owned directory"
      end
      path
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "#{label} must be an owned directory"
    end

    def read_bounded(io)
      output = +""
      truncated = false
      while (chunk = io.read(16 * 1024))
        remaining = @output_limit - output.bytesize
        if remaining.positive?
          output << chunk.byteslice(0, remaining)
        end
        truncated ||= chunk.bytesize > remaining
      end
      [ output, truncated ]
    ensure
      io.close rescue nil
    end

    def terminate_group(pid)
      safe_signal("TERM", -Integer(pid))
      @sleeper.call(TERM_GRACE)
      safe_signal("KILL", -Integer(pid)) if @process_alive.call(Integer(pid))
    end

    def safe_signal(signal, target)
      @signaler.call(signal, target)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def process_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue Errno::ESRCH, Errno::ECHILD
      false
    rescue Errno::EPERM
      true
    end

    def normalize_process(value)
      unless value.is_a?(Hash) && KINDS.include?(value["kind"].to_s)
        raise Error, "upgrade process record has an invalid kind"
      end
      pid = Integer(value.fetch("pid"))
      pgid = Integer(value.fetch("pgid"))
      raise Error, "upgrade process record has an invalid process identity" unless pid.positive? && pgid.positive?
      { "kind" => value.fetch("kind").to_s, "pid" => pid, "pgid" => pgid }
    rescue KeyError, ArgumentError, TypeError
      raise Error, "upgrade process record has an invalid process identity"
    end
  end
end
