require_relative "../../test_helper"
require_relative "asciinema_driver"

class E2EAsciinemaDriverTest < Minitest::Test
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
end
