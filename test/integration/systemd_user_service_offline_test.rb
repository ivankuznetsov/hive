require "test_helper"
require "open3"
require "rbconfig"
require "securerandom"
require "shellwords"
require "socket"
require "hive/user_service"

class SystemdUserServiceOfflineTest < Minitest::Test
  include HiveTestHelper

  OFFLINE_ATTEMPTS = 6
  OFFLINE_TIMEOUT_SEC = 8
  RECONNECT_TIMEOUT_SEC = 5
  RETRY_INTERVAL_SEC = 0.15

  def test_real_user_manager_stays_single_process_while_offline_and_reconnects
    skip "real user-manager lifecycle belongs to the declared Linux gate" unless gate_required?

    preflight!
    home = File.expand_path(ENV.fetch("HIVE_SYSTEMD_USER_HOME"))
    service_name = "hive-offline-probe-#{Process.pid}-#{SecureRandom.hex(4)}"
    unit_name = "#{service_name}.service"
    target_path = File.join(home, ".config", "systemd", "user", unit_name)
    definition = nil
    server = nil
    server_thread = nil

    Dir.mktmpdir("hive-systemd-offline-") do |dir|
      attempts_path = File.join(dir, "attempts.log")
      success_path = File.join(dir, "success.log")
      command_log_path = File.join(dir, "systemctl.log")
      port = unused_port
      definition = Hive::UserService::Definition.new(
        platform: :linux,
        service_name: service_name,
        target_path: target_path,
        content: unit_content(
          port: port,
          attempts_path: attempts_path,
          success_path: success_path
        )
      )
      shim_dir = provision_systemctl_shim(dir, command_log_path)

      with_env(
        "PATH" => "#{shim_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
        "HIVE_SYSTEMD_COMMAND_LOG" => command_log_path
      ) do
        service = build_service(definition, home: home)
        begin
          result = service.apply(service.plan(autostart: true))
          assert result.success?, "install failed: #{result.diagnostics.inspect} #{result.error_class}"
          assert_equal :written, result.kind

          wait_until(OFFLINE_TIMEOUT_SEC, "#{unit_name} did not remain alive for offline retries") do
            record_count(attempts_path) >= OFFLINE_ATTEMPTS && active?(unit_name)
          end
          assert enabled?(unit_name)
          assert_equal 0, integer_property(unit_name, "NRestarts")
          original_pid = integer_property(unit_name, "MainPID")
          assert_operator original_pid, :positive?
          assert process_alive?(original_pid)
          assert_equal [ original_pid ], live_cgroup_pids(unit_name)

          server = TCPServer.new("127.0.0.1", port)
          server_errors = Queue.new
          server_thread = Thread.new do
            client = server.accept
            client.gets
            client.puts("ready")
          rescue IOError, Errno::EBADF
            nil
          rescue StandardError => error
            server_errors << error
          ensure
            client&.close
          end

          wait_until(RECONNECT_TIMEOUT_SEC, "#{unit_name} did not become healthy after reconnect") do
            record_count(success_path) == 1
          end
          server_thread.join(2)
          raise server_errors.pop unless server_errors.empty?
          assert_equal original_pid, integer_property(unit_name, "MainPID")
          assert_equal [ original_pid ], live_cgroup_pids(unit_name)
          assert_equal 1, unit_inventory(unit_name).size

          mutations = manager_mutation_count(command_log_path)
          replay = build_service(definition, home: home)
          replay_result = replay.apply(replay.plan(autostart: true))
          assert_equal :unchanged, replay_result.kind
          assert_equal mutations, manager_mutation_count(command_log_path)
          assert_equal original_pid, integer_property(unit_name, "MainPID")

          busy_plan = replay.plan(autostart: true)
          ready = Queue.new
          release = Queue.new
          holder_error = Queue.new
          transaction = Hive::UserService::Transaction.new(
            definition: definition,
            home: home,
            lock_wait: 0.05
          )
          holder = Thread.new do
            transaction.with_lock do
              ready << true
              release.pop
            end
          rescue StandardError => error
            holder_error << error
          end
          ready.pop
          contender = build_service(definition, home: home, lock_wait: 0.05)
          busy_result = contender.apply(busy_plan)
          release << true
          holder.join
          raise holder_error.pop unless holder_error.empty?

          assert_equal :failed, busy_result.kind
          assert_includes busy_result.diagnostics, :operation_busy
          assert_equal mutations, manager_mutation_count(command_log_path)
          assert_equal original_pid, integer_property(unit_name, "MainPID")
          assert_equal [ original_pid ], live_cgroup_pids(unit_name)
          assert_equal 1, record_count(success_path)
          assert_equal 1, Dir[File.join(File.dirname(target_path), unit_name)].size
        ensure
          server&.close
          server_thread&.join(2)
          cleanup!(definition, home: home) if definition
        end
      end
    end
  end

  private

  def gate_required?
    ENV["HIVE_REQUIRE_SYSTEMD_USER_GATE"] == "1"
  end

  def preflight!
    assert RbConfig::CONFIG["host_os"].match?(/linux/i), "real user-manager gate requires Linux"
    runtime_dir = ENV["XDG_RUNTIME_DIR"]
    assert runtime_dir && File.directory?(runtime_dir), "XDG_RUNTIME_DIR must name an existing directory"
    assert command_success?(%w[systemctl --user show-environment]), "a functional systemd user manager is required"
    assert command_success?(%w[systemctl --user daemon-reload]), "the user manager must accept daemon-reload"
    assert File.file?(File.join("/sys/fs/cgroup", "cgroup.controllers")), "the gate requires cgroup v2"
  end

  def unit_content(port:, attempts_path:, success_path:)
    fixture = File.expand_path("../fixtures/systemd/offline_reconnect_probe.rb", __dir__)
    command = [
      RbConfig.ruby,
      fixture,
      port.to_s,
      attempts_path,
      success_path,
      RETRY_INTERVAL_SEC.to_s
    ].map { |argument| systemd_quote(argument) }.join(" ")
    <<~UNIT
      [Unit]
      Description=Hive deterministic offline reconnect probe
      StartLimitIntervalSec=3
      StartLimitBurst=3

      [Service]
      Type=simple
      ExecStart=#{command}
      Restart=on-failure
      RestartSec=100ms
      TimeoutStopSec=5s

      [Install]
      WantedBy=default.target
    UNIT
  end

  def systemd_quote(argument)
    escaped = argument.gsub("\\", "\\\\").gsub('"', '\\"')
    %Q("#{escaped}")
  end

  def build_service(definition, home:, lock_wait: Hive::UserService::Transaction::LOCK_WAIT_SEC)
    Hive::UserService.new(
      definition: definition,
      query_available: true,
      manager_available: :available,
      home: home,
      lock_wait: lock_wait
    )
  end

  def cleanup!(definition, home:)
    service = build_service(definition, home: home)
    result = service.remove(service.plan_remove)
    return verify_removed!(definition) if %i[removed absent].include?(result.kind)

    system("systemctl", "--user", "disable", "--now", definition.service_name,
           out: File::NULL, err: File::NULL)
    FileUtils.rm_f(definition.target_path)
    system("systemctl", "--user", "daemon-reload", out: File::NULL, err: File::NULL)
    verify_removed!(definition)
  end

  def verify_removed!(definition)
    wait_until(5, "#{definition.service_name} survived cleanup") do
      !active?("#{definition.service_name}.service") &&
        integer_property("#{definition.service_name}.service", "MainPID").zero? &&
        !File.exist?(definition.target_path)
    end
  end

  def unused_port
    socket = TCPServer.new("127.0.0.1", 0)
    socket.local_address.ip_port
  ensure
    socket&.close
  end

  def wait_until(timeout, message)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
    flunk message
  end

  def command_success?(argv)
    system(*argv, out: File::NULL, err: File::NULL)
  end

  def active?(unit_name)
    command_success?([ "systemctl", "--user", "is-active", "--quiet", unit_name ])
  end

  def enabled?(unit_name)
    command_success?([ "systemctl", "--user", "is-enabled", "--quiet", unit_name ])
  end

  def integer_property(unit_name, property)
    output, status = Open3.capture2(
      "systemctl", "--user", "show", unit_name,
      "--property=#{property}", "--value"
    )
    return 0 unless status.success?

    Integer(output.strip, exception: false) || 0
  end

  def live_cgroup_pids(unit_name)
    output, status = Open3.capture2(
      "systemctl", "--user", "show", unit_name,
      "--property=ControlGroup", "--value"
    )
    assert status.success?, "could not inspect #{unit_name} cgroup"
    path = File.join("/sys/fs/cgroup", output.strip.delete_prefix("/"), "cgroup.procs")
    assert File.file?(path), "missing cgroup process list for #{unit_name}: #{path}"
    File.readlines(path, chomp: true).filter_map do |line|
      pid = Integer(line, exception: false)
      pid if pid&.positive? && process_alive?(pid)
    end.sort
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def record_count(path)
    File.exist?(path) ? File.foreach(path).count : 0
  end

  def unit_inventory(unit_name)
    output, status = Open3.capture2(
      "systemctl", "--user", "list-unit-files", unit_name,
      "--no-legend", "--no-pager"
    )
    assert status.success?, "could not enumerate #{unit_name}"
    output.lines.select { |line| line.split.first == unit_name }
  end

  def provision_systemctl_shim(dir, command_log_path)
    real_systemctl = executable_path("systemctl")
    assert real_systemctl, "systemctl must be executable in PATH"
    shim_dir = File.join(dir, "bin")
    FileUtils.mkdir_p(shim_dir)
    shim = File.join(shim_dir, "systemctl")
    File.write(shim, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> "$HIVE_SYSTEMD_COMMAND_LOG"
      exec #{Shellwords.escape(real_systemctl)} "$@"
    SH
    FileUtils.chmod(0o755, shim)
    File.write(command_log_path, "")
    shim_dir
  end

  def executable_path(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      candidate = File.join(directory, name)
      return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end

  def manager_mutation_count(path)
    return 0 unless File.exist?(path)

    File.foreach(path).count do |line|
      arguments = line.split
      arguments.first == "--user" &&
        (arguments[1] == "daemon-reload" ||
         %w[enable disable start stop restart].include?(arguments[1]))
    end
  end
end
