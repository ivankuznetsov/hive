require_relative "../../test_helper"
require_relative "asciinema_driver"

class E2EAsciinemaDriverTest < Minitest::Test
  def test_non_executable_env_override_binary_is_unavailable
    Dir.mktmpdir("asciinema") do |dir|
      script = File.join(dir, "asciinema")
      File.write(script, "not executable\n")
      File.chmod(0o644, script)

      old = ENV["HIVE_ASCIINEMA_BIN"]
      ENV["HIVE_ASCIINEMA_BIN"] = script

      refute Hive::E2E::AsciinemaDriver.available?
      assert_nil Hive::E2E::AsciinemaDriver.version
    ensure
      ENV["HIVE_ASCIINEMA_BIN"] = old
    end
  end

  def test_records_with_env_override_binary
    Dir.mktmpdir("asciinema") do |dir|
      script = File.join(dir, "asciinema")
      cast = File.join(dir, "cast.json")
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        if ARGV == ["--version"]
          puts "asciinema 3.1.0"
          exit 0
        end

        if ARGV.first == "rec"
          File.write(ARGV.last, %({"version":2,"width":200,"height":50}\\n))
          sleep 30
        end
      RUBY
      File.chmod(0o755, script)

      old = ENV["HIVE_ASCIINEMA_BIN"]
      ENV["HIVE_ASCIINEMA_BIN"] = script
      driver = Hive::E2E::AsciinemaDriver.new(socket_name: "fake", session_name: "fake", cast_path: cast)
      driver.start
      deadline = Time.now + 2
      sleep 0.05 until File.exist?(cast) || Time.now >= deadline
      driver.stop

      assert_equal :ok, driver.integrity_status
    ensure
      ENV["HIVE_ASCIINEMA_BIN"] = old
    end
  end

  def test_start_raises_unavailable_when_recorder_spawn_fails
    Dir.mktmpdir("asciinema") do |dir|
      script = File.join(dir, "asciinema")
      cast = File.join(dir, "cast.json")
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        if ARGV == ["--version"]
          puts "asciinema 3.1.0"
          exit 0
        end
      RUBY
      File.chmod(0o755, script)

      old = ENV["HIVE_ASCIINEMA_BIN"]
      ENV["HIVE_ASCIINEMA_BIN"] = script
      driver = Hive::E2E::AsciinemaDriver.new(socket_name: "fake", session_name: "fake", cast_path: cast)
      File.chmod(0o644, script)

      error = assert_raises(Hive::E2E::AsciinemaDriver::Unavailable) { driver.start }
      assert_match(/failed to start asciinema/, error.message)
    ensure
      ENV["HIVE_ASCIINEMA_BIN"] = old
    end
  end

  def test_uses_window_size_arg_for_v3_binary
    Dir.mktmpdir("asciinema") do |dir|
      script = File.join(dir, "asciinema")
      cast = File.join(dir, "cast.json")
      args = File.join(dir, "args.json")
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"

        if ARGV == ["--version"]
          puts "asciinema 3.2.0"
          exit 0
        end

        if ARGV.first == "rec"
          File.write(#{args.inspect}, JSON.dump(ARGV))
          File.write(ARGV.last, %({"version":2,"width":200,"height":50}\\n))
          sleep 30
        end
      RUBY
      File.chmod(0o755, script)

      old = ENV["HIVE_ASCIINEMA_BIN"]
      ENV["HIVE_ASCIINEMA_BIN"] = script
      driver = Hive::E2E::AsciinemaDriver.new(socket_name: "fake", session_name: "fake", cast_path: cast)
      driver.start
      deadline = Time.now + 2
      sleep 0.05 until File.exist?(args) || Time.now >= deadline
      driver.stop

      argv = JSON.parse(File.read(args))
      assert_includes argv, "--window-size"
      assert_includes argv, "200x50"
      assert_includes argv, "--output-format=asciicast-v2"
      refute_includes argv, "--rows"
      refute_includes argv, "--cols"
    ensure
      ENV["HIVE_ASCIINEMA_BIN"] = old
    end
  end

  def test_omits_output_format_arg_for_v2_binary
    Dir.mktmpdir("asciinema") do |dir|
      script = File.join(dir, "asciinema")
      cast = File.join(dir, "cast.json")
      args = File.join(dir, "args.json")
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"

        if ARGV == ["--version"]
          puts "asciinema 2.4.0"
          exit 0
        end

        if ARGV.include?("--output-format=asciicast-v2")
          exit 64
        end

        if ARGV.first == "rec"
          File.write(#{args.inspect}, JSON.dump(ARGV))
          File.write(ARGV.last, %({"version":2,"width":200,"height":50}\\n))
          sleep 30
        end
      RUBY
      File.chmod(0o755, script)

      old = ENV["HIVE_ASCIINEMA_BIN"]
      ENV["HIVE_ASCIINEMA_BIN"] = script
      driver = Hive::E2E::AsciinemaDriver.new(socket_name: "fake", session_name: "fake", cast_path: cast)
      driver.start
      deadline = Time.now + 2
      sleep 0.05 until File.exist?(args) || Time.now >= deadline
      driver.stop

      argv = JSON.parse(File.read(args))
      assert_includes argv, "--rows"
      assert_includes argv, "50"
      assert_includes argv, "--cols"
      assert_includes argv, "200"
      refute_includes argv, "--window-size"
      refute_includes argv, "--output-format=asciicast-v2"
    ensure
      ENV["HIVE_ASCIINEMA_BIN"] = old
    end
  end
end
