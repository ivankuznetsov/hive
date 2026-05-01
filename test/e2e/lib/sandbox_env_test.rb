require_relative "../../test_helper"
require_relative "sandbox_env"

class E2ESandboxEnvTest < Minitest::Test
  def test_yields_clean_repro_env
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")
        ENV["BUNDLE_PATH"] = "/tmp/leak"
        ENV["RUBYOPT"] = "-I/tmp/leak"

        yielded = nil
        Hive::E2E::SandboxEnv.with(sandbox, home) { |env| yielded = env }

        assert_equal File.join(sandbox, "Gemfile"), yielded["BUNDLE_GEMFILE"]
        assert_equal home, yielded["HIVE_HOME"]
        assert_equal "xterm-256color", yielded["TERM"]
        refute_includes yielded.keys, "BUNDLE_PATH"
        refute_includes yielded.keys, "RUBYOPT"
      ensure
        ENV.delete("BUNDLE_PATH")
        ENV.delete("RUBYOPT")
      end
    end
  end
end
