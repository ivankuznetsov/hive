require "test_helper"
require "hive/env_file"

class HiveEnvFileTest < Minitest::Test
  include HiveTestHelper

  def test_load_sets_keys_from_file
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "HIVE_TELEGRAM_BOT_TOKEN=secret:abc\n")
      env = {}

      added = Hive::EnvFile.load!(path: path, env: env)

      assert_equal [ "HIVE_TELEGRAM_BOT_TOKEN" ], added
      assert_equal "secret:abc", env["HIVE_TELEGRAM_BOT_TOKEN"]
    end
  end

  def test_load_ignores_comments_and_blank_lines
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, <<~ENV)
        # this is a comment
        HIVE_TELEGRAM_BOT_TOKEN=t1

           # indented comment

        OTHER=v
      ENV
      env = {}

      Hive::EnvFile.load!(path: path, env: env)

      assert_equal "t1", env["HIVE_TELEGRAM_BOT_TOKEN"]
      assert_equal "v", env["OTHER"]
    end
  end

  def test_load_does_not_overwrite_existing_env_values
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "HIVE_TELEGRAM_BOT_TOKEN=from_file\n")
      env = { "HIVE_TELEGRAM_BOT_TOKEN" => "from_shell" }

      added = Hive::EnvFile.load!(path: path, env: env)

      assert_empty added, "manual export must win over .env file"
      assert_equal "from_shell", env["HIVE_TELEGRAM_BOT_TOKEN"]
    end
  end

  def test_load_strips_outer_quotes
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, <<~ENV)
        DOUBLE="hello world"
        SINGLE='hello world'
        BARE=hello world
      ENV
      env = {}

      Hive::EnvFile.load!(path: path, env: env)

      assert_equal "hello world", env["DOUBLE"]
      assert_equal "hello world", env["SINGLE"]
      assert_equal "hello world", env["BARE"]
    end
  end

  def test_load_skips_malformed_lines
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, <<~ENV)
        no_equals_here
        =empty_key
        VALID=ok
      ENV
      env = {}

      added = Hive::EnvFile.load!(path: path, env: env)

      assert_equal [ "VALID" ], added
      assert_equal "ok", env["VALID"]
    end
  end

  def test_load_handles_values_with_embedded_equals
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "TOKEN=abc=def=ghi\n")
      env = {}

      Hive::EnvFile.load!(path: path, env: env)

      assert_equal "abc=def=ghi", env["TOKEN"],
                   "values containing '=' must round-trip; only the first '=' delimits key/value"
    end
  end

  def test_load_silently_returns_empty_when_file_missing
    with_tmp_dir do |dir|
      missing = File.join(dir, "does-not-exist.env")
      env = {}

      added = Hive::EnvFile.load!(path: missing, env: env)

      assert_empty added
      assert_empty env
    end
  end

  def test_load_silently_returns_empty_when_file_unreadable
    with_tmp_dir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "TOKEN=secret\n")
      File.chmod(0o000, path)
      env = {}

      added = Hive::EnvFile.load!(path: path, env: env)

      assert_empty added
    ensure
      File.chmod(0o644, path) if path && File.exist?(path)
    end
  end
end
