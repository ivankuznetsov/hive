require "test_helper"
require "socket"
require "hive/artifacts/managed_project_server"

class ArtifactsManagedProjectServerTest < Minitest::Test
  include HiveTestHelper

  def test_starts_repository_executable_in_closed_sandbox_and_proves_cleanup
    Dir.mktmpdir("hive-managed-project-server") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p([ File.join(source, "bin"), File.join(source, "log"),
                          File.join(source, "storage"), File.join(source, "tmp") ])
      executable = File.join(source, "bin", "server")
      sandbox = File.join(root, "bwrap")
      [ executable, sandbox ].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      spawned = nil
      spawner = lambda do |environment, *argv, **options|
        spawned = { environment: environment, argv: argv, options: options }
        42_424
      end
      killed = []
      killer = lambda do |pid, **options|
        killed << [ pid, options ]
        Hive::ProcessKill::Result.new(pid: pid, killed: true, skipped_reason: nil)
      end
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: 41_234, sandbox_binary: sandbox,
        spawner: spawner, waiter: ->(_pid) { nil }, process_killer: killer,
        start_time_resolver: ->(_pid) { "start-1" },
        readiness_probe: ->(url) { url == "http://127.0.0.1:41234/" }
      )

      receipt = server.start!([ "bin/server", "--port", "41234" ])

      assert_equal "ready", receipt.fetch("status")
      assert_equal "http://127.0.0.1:41234", receipt.fetch("app_endpoint")
      assert_equal({}, spawned.fetch(:environment))
      assert_equal true, spawned.dig(:options, :unsetenv_others)
      argv = spawned.fetch(:argv)
      assert_equal sandbox, argv.first
      assert_includes argv, "--unshare-all"
      assert_includes argv, "--share-net"
      assert_includes argv.each_cons(3).to_a, [ "--ro-bind", source, source ]
      %w[log storage tmp].each do |relative|
        path = File.join(source, relative)
        assert_includes argv.each_cons(3).to_a, [ "--bind", path, path ]
      end
      assert_equal [ executable, "--port", "41234" ], argv.last(3)
      refute_includes argv, ENV["DBUS_SESSION_BUS_ADDRESS"] if ENV["DBUS_SESSION_BUS_ADDRESS"]
      refute_includes argv, ENV["SSH_AUTH_SOCK"] if ENV["SSH_AUTH_SOCK"]
      assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.start!([ "bin/server" ])
      end

      assert server.close
      assert_equal 42_424, killed.first.first
      assert_equal "start-1", killed.first.last.fetch(:recorded_start_time)
    end
  end

  def test_rejects_commands_outside_the_repository
    Dir.mktmpdir("hive-managed-project-server-invalid") do |root|
      sandbox = File.join(root, "bwrap")
      File.write(sandbox, "#!/bin/sh\n")
      FileUtils.chmod(0o755, sandbox)
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: root, port: 41_235, sandbox_binary: sandbox
      )

      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.start!([ "/usr/bin/ruby", "-e", "exit" ])
      end
      assert_includes error.message, "escapes the source root"

      assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        Hive::Artifacts::ManagedProjectServer.new(
          source_root: root, port: 0, sandbox_binary: sandbox
        )
      end
    end
  end

  def test_rejects_unlaunchable_commands_and_reports_startup_failures
    Dir.mktmpdir("hive-managed-project-server-failures") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "bin"))
      executable = File.join(source, "bin", "server")
      sandbox = File.join(root, "bwrap")
      [ executable, sandbox ].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      symlink = File.join(source, "bin", "linked")
      File.symlink(executable, symlink)
      base = {
        source_root: source, port: 41_236, sandbox_binary: sandbox,
        spawner: ->(*, **) { 42_425 }, process_killer: method(:successful_kill),
        start_time_resolver: ->(_pid) { "start-2" }, sleeper: ->(_seconds) { }
      }

      server = Hive::Artifacts::ManagedProjectServer.new(**base)
      assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.start!([])
      end
      assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.start!([ "bin/linked" ])
      end
      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.start!([ "bin/absent" ])
      end
      assert_includes error.message, "executable is unavailable"

      status = Struct.new(:exitstatus).new(7)
      exited = Hive::Artifacts::ManagedProjectServer.new(
        **base, waiter: ->(_pid) { [ 42_425, status ] }, readiness_probe: ->(_url) { false }
      )
      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        exited.start!([ "bin/server" ])
      end
      assert_includes error.message, "exit=7"

      ticks = [ 0, 91 ]
      timed_out = Hive::Artifacts::ManagedProjectServer.new(
        **base, waiter: ->(_pid) { nil }, readiness_probe: ->(_url) { false },
        clock: -> { ticks.shift || 91 }
      )
      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        timed_out.start!([ "bin/server" ])
      end
      assert_includes error.message, "not ready"

      unidentified = Hive::Artifacts::ManagedProjectServer.new(
        **base, waiter: ->(_pid) { nil },
        start_time_resolver: ->(_pid) { nil }, readiness_probe: ->(_url) { true }
      )
      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        unidentified.start!([ "bin/server" ])
      end
      assert_includes error.message, "identity is unavailable"
    end
  end

  # Bubblewrap is absent on some supported hosts, so the managed lifetime is
  # proven twice: here against a sandbox stub that only forwards the wrapped
  # command -- which still spawns, polls for readiness, drains output and tears
  # down for real -- and below against real bubblewrap for the filesystem
  # boundary that only bubblewrap can enforce.
  def test_stubbed_sandbox_serves_only_for_the_managed_lifetime
    Dir.mktmpdir("hive-managed-project-server-stub") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p([ File.join(source, "bin"), File.join(source, "tmp") ])
      sandbox = File.join(root, "bwrap")
      File.write(sandbox, <<~SH)
        #!/bin/sh
        while [ "$1" != "--" ]; do
          if [ "$1" = "--setenv" ]; then
            export "$2=$3"
            shift 3
          else
            shift
          fi
        done
        shift
        exec "$@"
      SH
      executable = File.join(source, "bin", "server")
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require "socket"
        server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
        loop do
          socket = server.accept
          begin
            socket.readpartial(8192)
          rescue IOError, SystemCallError, EOFError
            nil
          end
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
          socket.close
        end
      RUBY
      FileUtils.chmod(0o755, [ sandbox, executable ])
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.local_address.ip_port
      probe.close
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: port, sandbox_binary: sandbox
      )

      receipt = server.start!([ "bin/server" ])

      assert_equal "ready", receipt.fetch("status")
      assert_equal "http://127.0.0.1:#{port}", receipt.fetch("app_endpoint")
      assert_equal "ok", Net::HTTP.get(URI(receipt.fetch("app_endpoint")))
      assert server.close
      assert_raises(Errno::ECONNREFUSED) do
        TCPSocket.new("127.0.0.1", port)
      end
    ensure
      server&.close if server&.receipt
    end
  end

  def test_teardown_tolerates_an_already_reaped_server
    Dir.mktmpdir("hive-managed-project-server-reaped") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "bin"))
      executable = File.join(source, "bin", "server")
      sandbox = File.join(root, "bwrap")
      [ executable, sandbox ].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      reaped = []
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: 41_235, sandbox_binary: sandbox,
        spawner: ->(_environment, *_argv, **_options) { 42_425 },
        waiter: lambda do |_pid|
          reaped << true
          raise Errno::ECHILD if reaped.length > 1

          nil
        end,
        process_killer: method(:successful_kill),
        start_time_resolver: ->(_pid) { "start-1" },
        readiness_probe: ->(_url) { true }
      )

      assert_equal "ready", server.start!([ "bin/server" ]).fetch("status")
      assert server.close
      assert_equal 2, reaped.length
    end
  end

  # A spawn that never reaches the sandbox still has to release the runtime
  # boundary. When that teardown also fails, the startup diagnosis is what the
  # producer needs to act on, so the teardown error is swallowed rather than
  # replacing the reason the server never came up.
  def test_spawn_failures_release_the_runtime_and_keep_the_startup_diagnosis
    Dir.mktmpdir("hive-managed-project-server-spawn") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "bin"))
      executable = File.join(source, "bin", "server")
      sandbox = File.join(root, "bwrap")
      [ executable, sandbox ].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      server = nil
      runtime = nil
      spawner = lambda do |_environment, *_argv, **_options|
        # The runtime the sandbox just built is replaced by a symlink, so its
        # own teardown cannot prove ownership when the failing spawn unwinds.
        runtime = server.instance_variable_get(:@sandbox)
                        .instance_variable_get(:@runtime_root)
        FileUtils.remove_entry_secure(runtime)
        File.symlink(source, runtime)
        raise Errno::ENOENT, "bwrap"
      end
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: 41_237, sandbox_binary: sandbox,
        spawner: spawner, waiter: ->(_pid) { nil },
        process_killer: method(:successful_kill),
        start_time_resolver: ->(_pid) { "start-3" },
        readiness_probe: ->(_url) { true }
      )

      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.start!([ "bin/server" ])
      end

      assert_includes error.message, "could not start"
      assert_nil server.receipt
    ensure
      File.unlink(runtime) if runtime && File.symlink?(runtime)
    end
  end

  # Teardown Hive cannot prove is a failure the attempt has to see, and the
  # sandbox runtime is still released before that failure surfaces so a
  # half-torn-down capture cannot strand the boundary.
  def test_unproven_teardown_fails_after_releasing_the_runtime
    Dir.mktmpdir("hive-managed-project-server-unproven") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "bin"))
      executable = File.join(source, "bin", "server")
      sandbox = File.join(root, "bwrap")
      [ executable, sandbox ].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      unproven = lambda do |pid, **|
        Hive::ProcessKill::Result.new(
          pid: pid, killed: false, skipped_reason: "start_time_changed"
        )
      end
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: 41_238, sandbox_binary: sandbox,
        spawner: ->(_environment, *_argv, **_options) { 42_427 },
        waiter: ->(_pid) { nil }, process_killer: unproven,
        start_time_resolver: ->(_pid) { "start-4" },
        readiness_probe: ->(_url) { true }
      )

      assert_equal "ready", server.start!([ "bin/server" ]).fetch("status")
      runtime = server.instance_variable_get(:@sandbox)
                      .instance_variable_get(:@runtime_root)
      error = assert_raises(Hive::Artifacts::ManagedProjectServer::ServerError) do
        server.close
      end

      assert_includes error.message, "teardown was not proven"
      assert_includes error.message, "start_time_changed"
      refute_path_exists runtime
      assert_nil server.receipt
      assert server.close
    end
  end

  # The producer only ever reads server output through Hive's bounded copy, so
  # whatever the process wrote to its pipe has to land in that buffer.
  def test_server_output_is_drained_into_the_bounded_buffer
    Dir.mktmpdir("hive-managed-project-server-output") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "bin"))
      executable = File.join(source, "bin", "server")
      sandbox = File.join(root, "bwrap")
      [ executable, sandbox ].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      spawner = lambda do |_environment, *_argv, **options|
        options.fetch(:out).write("listening on 41239\n")
        42_428
      end
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: 41_239, sandbox_binary: sandbox,
        spawner: spawner, waiter: ->(_pid) { nil },
        process_killer: method(:successful_kill),
        start_time_resolver: ->(_pid) { "start-5" },
        readiness_probe: ->(_url) { true }
      )

      assert_equal "ready", server.start!([ "bin/server" ]).fetch("status")
      # The writer closed with the spawn, so the drain thread reaches EOF and
      # finishes on its own; joining it makes the copy observable.
      server.instance_variable_get(:@output_thread).join(5)

      assert_includes server.instance_variable_get(:@output), "listening on 41239"
      assert server.close
    end
  end

  def test_real_sandbox_serves_only_for_the_managed_lifetime
    sandbox = Hive::InvokedBinary.which("bwrap")
    skip "bubblewrap is unavailable" unless sandbox

    Dir.mktmpdir("hive-managed-project-server-live") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p([ File.join(source, "bin"), File.join(source, "tmp") ])
      executable = File.join(source, "bin", "server")
      File.write(executable, <<~RUBY)
        #!/usr/bin/ruby
        require "socket"
        begin
          File.write("forbidden.txt", "must not escape the runtime boundary")
        rescue Errno::EROFS
        end
        server = TCPServer.new("127.0.0.1", Integer(ENV.fetch("PORT")))
        loop do
          socket = server.accept
          socket.readpartial(8192) rescue nil
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
          socket.close
        end
      RUBY
      FileUtils.chmod(0o755, executable)
      probe = TCPServer.new("127.0.0.1", 0)
      port = probe.local_address.ip_port
      probe.close
      server = Hive::Artifacts::ManagedProjectServer.new(
        source_root: source, port: port, sandbox_binary: sandbox
      )

      receipt = server.start!([ "bin/server" ])

      assert_equal "http://127.0.0.1:#{port}", receipt.fetch("app_endpoint")
      assert_equal "ok", Net::HTTP.get(URI(receipt.fetch("app_endpoint")))
      refute_path_exists File.join(source, "forbidden.txt")
      assert server.close
      assert_raises(Errno::ECONNREFUSED) do
        TCPSocket.new("127.0.0.1", port)
      end
    ensure
      server&.close if server&.receipt
    end
  end

  private

  def successful_kill(pid, **)
    Hive::ProcessKill::Result.new(pid: pid, killed: true, skipped_reason: nil)
  end
end
