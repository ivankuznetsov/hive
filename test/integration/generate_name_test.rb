require "test_helper"
require "hive/commands/generate_name"
require "hive/commands/init"
require "hive/commands/new"
require "hive/task_meta"

class GenerateNameTest < Minitest::Test
  include HiveTestHelper

  def test_generate_name_populates_meta_and_commits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        configure_fake_agent(dir, output: { "type" => "result", "result" => "\"Readable inbox title.\"" })
        capture_io { Hive::Commands::New.new(File.basename(dir), "readable inbox title").call }
        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "readable-inbox-title-*")].first

        out, = capture_io { Hive::Commands::GenerateName.new(folder).call }

        assert_equal "Readable inbox title\n", out
        meta = Hive::TaskMeta.read(folder)
        assert_equal 1, meta[:id]
        assert_equal File.basename(folder), meta[:slug]
        assert_equal "Readable inbox title", meta[:display_name]
        log = run!("git", "-C", File.join(dir, ".hive-state"), "log", "--format=%s", "-1").strip
        assert_match(%r{\Ahive: 1-inbox/#{Regexp.escape(File.basename(folder))} named\z}, log)
      end
    end
  end

  def test_generate_name_failure_leaves_meta_unchanged
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        configure_fake_agent(dir, exit_code: 2, output: "boom")
        capture_io { Hive::Commands::New.new(File.basename(dir), "failing name").call }
        folder = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "failing-name-*")].first

        out, = capture_io { Hive::Commands::GenerateName.new(folder).call }

        assert_equal "", out
        assert_nil Hive::TaskMeta.read(folder)[:display_name]
      end
    end
  end

  private

  def configure_fake_agent(project_root, output:, exit_code: 0)
    bin = File.join(project_root, "fake-display-agent")
    payload = output.is_a?(String) ? output : JSON.generate(output)
    File.write(bin, <<~SH)
      #!/bin/sh
      printf '%s\\n' #{Shellwords.escape(payload)}
      exit #{exit_code}
    SH
    FileUtils.chmod(0o755, bin)

    config_path = File.join(project_root, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(config_path)) || {}
    cfg["execute"] ||= {}
    cfg["execute"]["agent"] = "claude"
    cfg["agents"] ||= {}
    cfg["agents"]["claude"] ||= {}
    cfg["agents"]["claude"]["bin"] = bin
    cfg["display_name_timeout_sec"] = 5
    File.write(config_path, cfg.to_yaml)
  end
end
