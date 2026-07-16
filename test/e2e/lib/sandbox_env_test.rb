require_relative "../../test_helper"
require "open3"
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
        assert_equal yielded["HIVE_CLAUDE_BIN"], yielded["HIVE_CODEX_BIN"]
        assert_equal "xterm-256color", yielded["TERM"]
        refute_includes yielded.keys, "BUNDLE_PATH"
        refute_includes yielded.keys, "RUBYOPT"
      ensure
        ENV.delete("BUNDLE_PATH")
        ENV.delete("RUBYOPT")
      end
    end
  end

  def test_gh_shim_precedes_a_poisoned_host_binary_and_defaults_to_deny
    Dir.mktmpdir("sandbox") do |sandbox|
      Dir.mktmpdir("home") do |home|
        Dir.mktmpdir("poisoned-path") do |poisoned_path|
          marker = File.join(home, "real-gh-ran")
          host_gh = File.join(poisoned_path, "gh")
          File.write(host_gh, "#!/usr/bin/env bash\ntouch #{marker}\n")
          File.chmod(0o755, host_gh)
          File.write(File.join(sandbox, "Gemfile"), "source \"https://rubygems.org\"\n")

          original_path = ENV["PATH"]
          ENV["PATH"] = "#{poisoned_path}:#{original_path}"
          env = Hive::E2E::SandboxEnv.repro_env(sandbox, home)
          _out, err, status = Open3.capture3(env, "gh", "auth", "status", chdir: sandbox)

          refute status.success?
          assert_match(/no scripted interactions/, err)
          refute File.exist?(marker), "the poisoned host gh must never execute"
          assert_equal Hive::E2E::Paths.fixtures_dir, env.fetch("PATH").split(":").first
        ensure
          ENV["PATH"] = original_path
        end
      end
    end
  end
end
