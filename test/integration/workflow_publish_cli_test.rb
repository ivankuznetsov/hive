require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"

class WorkflowPublishCliTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def test_real_cli_dry_run_packages_and_lints_without_git_or_gh
    with_cli_project do |project_root, env, remote_marker|
      out, err, status = Open3.capture3(
        env,
        RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", HIVE_BIN,
        "workflow", "publish", "cli-flow", "--dry-run", "--json",
        chdir: project_root
      )

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal true, payload.fetch("ok")
      assert_equal true, payload.fetch("dry_run")
      assert_equal "cli-flow", payload.fetch("id")
      assert_nil payload.fetch("pr_url")
      refute File.exist?(remote_marker), "dry-run must not execute git or gh"
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-publish"))))
      assert_empty schema.validate(payload).map { |row| row["error"] }
    end
  end

  def test_real_cli_secret_failure_uses_safe_publish_error_schema
    secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    with_cli_project(asset_content: secret) do |project_root, env, remote_marker|
      out, _err, status = Open3.capture3(
        env,
        RbConfig.ruby, "-I#{File.expand_path('../../lib', __dir__)}", HIVE_BIN,
        "workflow", "publish", "cli-flow", "--dry-run", "--json",
        chdir: project_root
      )

      refute status.success?
      assert_equal Hive::ExitCodes::CONFIG, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-workflow-publish", payload.fetch("schema")
      assert_equal "preflight", payload.fetch("error_kind")
      refute_includes payload.inspect, secret
      refute File.exist?(remote_marker)
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-workflow-publish"))))
      assert_empty schema.validate(payload).map { |row| row["error"] }
    end
  end

  private

    def with_cli_project(asset_content: nil)
      with_tmp_dir do |dir|
        project_root = File.join(dir, "project")
        workflows = File.join(project_root, ".hive-state", "workflows")
        owned = File.join(workflows, "cli-flow")
        fake_bin = File.join(dir, "bin")
        remote_marker = File.join(dir, "remote-called")
        FileUtils.mkdir_p(owned)
        FileUtils.mkdir_p(fake_bin)
        File.write(File.join(project_root, ".hive-state", "config.yml"), YAML.dump(
          "hive_state_path" => ".hive-state",
          "honeycomb" => { "repository" => "example/honeycomb" }
        ))
        File.write(File.join(owned, "work.md"), "Perform a safe local review.\n")
        metadata = {
          "version" => "1.0.0",
          "author" => "CLI Author",
          "description" => "CLI publication fixture",
          "minimum_hive_version" => Hive::VERSION
        }
        if asset_content
          File.write(File.join(owned, "payload.txt"), asset_content)
          metadata["assets"] = [ "./cli-flow/payload.txt" ]
        end
        File.write(File.join(workflows, "cli-flow.yml"), YAML.dump(
          "id" => "cli-flow",
          "metadata" => metadata,
          "stages" => [
            {
              "name" => "work", "kind" => "agent", "state_file" => "work.md",
              "instruction" => "./cli-flow/work.md"
            }
          ]
        ))
        %w[git gh].each do |name|
          path = File.join(fake_bin, name)
          File.write(path, "#!/bin/sh\ntouch \"#{remote_marker}\"\nexit 99\n")
          FileUtils.chmod(0o755, path)
        end
        env = {
          "HOME" => File.join(dir, "home"),
          "HIVE_HOME" => File.join(dir, "hive-home"),
          "PATH" => [ fake_bin, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
        }
        yield(project_root, env, remote_marker)
      end
    end
end
