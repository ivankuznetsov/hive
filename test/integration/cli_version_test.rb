require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "hive/commands/init"
require "hive/refactor_patrol/job_store"
require "hive/task_meta"

class CliVersionTest < Minitest::Test
  include HiveTestHelper

  def test_bin_hive_version_outputs_version
    out = run!(RbConfig.ruby, "-Ilib", "bin/hive", "--version")

    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_normal_cli_use_leaves_v2_untouched_and_explicit_candidate_migrates_profile
    with_tmp_dir do |root|
      %w[user-a user-b].each_with_index do |user, user_index|
        home = File.join(root, user, "hive-home")
        FileUtils.mkdir_p(home)
        released_bytes = File.binread(File.expand_path(
          "../fixtures/refactor_patrol/released_v2_job.json",
          __dir__
        ))
        projects = %w[first second].map.with_index do |suffix, project_index|
          project = File.join(root, user, suffix, "project")
          state = File.join(root, user, suffix, "custom-state")
          FileUtils.mkdir_p([
            state,
            File.join(project, ".hive-state", "stages")
          ])
          File.write(
            File.join(project, ".hive-state", "config.yml"),
            {
              "project_name" => "#{user}-#{suffix}",
              "hive_state_path" => ".hive-state"
            }.to_yaml
          )
          legacy_job = File.join(
            state, "refactor_patrol", "v2", "jobs",
            "job-released.json"
          )
          FileUtils.mkdir_p(File.dirname(legacy_job))
          File.binwrite(legacy_job, released_bytes)
          {
            "name" => "#{user}-#{suffix}",
            "path" => project,
            "real_path" => File.realpath(project),
            "hive_state_path" => state,
            "project_id" => format(
              "00000000-0000-4000-a000-%012d",
              (user_index * 100) + project_index + 1
            )
          }
        end
        File.write(
          File.join(home, "config.yml"),
          { "registered_projects" => projects }.to_yaml
        )

        out, err, status = Open3.capture3(
          {
            "HIVE_HOME" => home,
            "HOME" => home,
            "HIVE_BIN" => "/nonexistent/hive",
            "PATH" => ENV.fetch("PATH", "")
          },
          RbConfig.ruby, "-Ilib", "bin/hive", "migrate",
          projects.first.fetch("path")
        )

        assert status.success?, err
        assert_includes out, "hive: migrate found nothing to move"
        projects.each do |project|
          legacy = File.join(
            project.fetch("hive_state_path"),
            "refactor_patrol", "v2", "jobs", "job-released.json"
          )
          current = Hive::RefactorPatrol::JobStore.root_for(
            project.fetch("path"),
            hive_state_path: project.fetch("hive_state_path")
          )
          assert_equal released_bytes, File.binread(legacy)
          refute_path_exists File.join(current, "jobs", "job-released.json")
        end
        receipt = File.join(
          home, "schema-migrations", "refactor-patrol-job-v3.json"
        )
        refute_path_exists receipt

        explicit_out, explicit_err, explicit_status = Open3.capture3(
          {
            "HIVE_HOME" => home,
            "HOME" => home,
            "HIVE_BIN" => "/nonexistent/hive",
            "PATH" => ENV.fetch("PATH", "")
          },
          RbConfig.ruby, "-Ilib", "bin/hive",
          "refactor-patrol-migrate-installed"
        )

        assert explicit_status.success?, explicit_err
        payload = JSON.parse(explicit_out)
        assert_equal "hive-user-profile-job-schema-migration",
                     payload.fetch("schema")
        assert_equal %w[migrated migrated],
                     payload.fetch("projects").map { |row| row.fetch("status") }
        projects.each do |project|
          current = Hive::RefactorPatrol::JobStore.root_for(
            project.fetch("path"),
            hive_state_path: project.fetch("hive_state_path")
          )
          migrated = JSON.parse(File.binread(File.join(
            current, "jobs", "job-released.json"
          )))
          assert_equal 3, migrated.fetch("schema_version")
        end
        assert_path_exists receipt
      end
    end
  end

  def test_strict_no_write_routes_skip_scheduler_reconciliation
    with_tmp_global_config do |home|
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        assert_startup_reconcile(project_root, home, %w[workflow validate coding --json], expected: false)
      end

      with_tmp_git_repo do |project_root|
        assert_startup_reconcile(
          project_root, home,
          [ "init", "--new-workflow", "editorial", "--minimal", "--preview", "--json" ],
          expected: false
        )
      end

      with_tmp_git_repo do |project_root|
        assert_startup_reconcile(
          project_root, home,
          [ "init", "--new-workflow", "workflow", "--minimal", "--preview", "--json" ],
          expected: false
        )
      end

      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        assert_startup_reconcile(
          project_root, home, %w[workflow --json validate coding], expected: false
        )
      end

      assert_startup_reconcile(
        Dir.pwd, home,
        %w[refactor-patrol-migrate-installed --resume],
        expected: false
      )
      assert_startup_reconcile(Dir.pwd, home, [ "--version" ], expected: true)
    end
  end

  def test_bin_hive_help_after_option_value_shows_command_usage
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "bin/hive", "approve", "--from", "2-brainstorm", "--help"
    )

    assert status.success?, "bin/hive approve --from 2-brainstorm --help should exit 0, stderr was: #{err}"
    assert_includes out, "Usage:"
    assert_includes out, "approve"
    refute_includes err, "No value provided for required arguments"
  end

  def test_bin_hive_treats_help_after_delimiter_as_literal_target
    with_tmp_global_config do
      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "run", "--", "--help")

      assert_equal 64, status.exitstatus
      assert_empty out
      assert_match(/no task folder for slug '--help'/, err)
      refute_match(/Usage:/, err)
    end
  end

  def test_bin_hive_accepts_json_before_status_command
    with_tmp_global_config do |home|
      leading = run_status_json!("--json", "status", home: home)
      trailing = run_status_json!("status", "--json", home: home)

      assert_equal without_generated_at(trailing), without_generated_at(leading)
    end
  end

  def test_bin_hive_accepts_leading_json_true_before_status_command
    with_tmp_global_config do |home|
      leading = run_status_json!("--json=true", "status", home: home)
      trailing = run_status_json!("status", "--json=true", home: home)

      assert_equal without_generated_at(trailing), without_generated_at(leading)
    end
  end

  def test_bin_hive_rejects_unsupported_json_assignments_before_target_dispatch
    with_tmp_global_config do
      %w[--json=1 --json=yes].each do |flag|
        out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "run", flag)

        assert_equal 64, status.exitstatus, "#{flag}: malformed JSON flag should be a usage error"
        assert_empty out, "#{flag}: unsupported JSON assignments must not request JSON mode"
        assert_match(/invalid boolean value for --json/, err)
        refute_match(/slug '#{Regexp.escape(flag.split("=", 2).last)}'/, err)
      end
    end
  end

  def test_bin_hive_treats_unsupported_json_assignment_after_delimiter_as_literal_target
    with_tmp_global_config do
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "bin/hive", "run", "--", "--json=bogus"
      )

      assert_equal 64, status.exitstatus
      assert_empty out
      assert_match(/no task folder for slug '--json=bogus'/, err)
      refute_match(/invalid boolean value for --json/, err)
    end
  end

  def test_bin_hive_usage_error_respects_last_json_boolean_flag
    with_tmp_global_config do
      [
        %w[--json --no-json],
        %w[--json --json=false]
      ].each do |flags|
        out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "run", *flags)

        assert_equal 64, status.exitstatus, "#{flags.join(" ")}: missing target should be a usage error"
        assert_empty out, "#{flags.join(" ")}: final false JSON flag must force prose output"
        assert_match(/Usage: "hive run TARGET"/, err)
      end
    end
  end

  def test_bin_hive_usage_error_ignores_json_booleans_after_delimiter
    with_tmp_global_config do
      out, err, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "bin/hive", "run", "--json", "target", "--", "--no-json"
      )

      assert_equal 64, status.exitstatus
      assert_equal "hive-run", JSON.parse(out)["schema"]
      assert_match(/hive:/, err)

      out, err, status = Open3.capture3(
        RbConfig.ruby, "-Ilib", "bin/hive", "run", "--no-json", "target", "--", "--json"
      )

      assert_equal 64, status.exitstatus
      assert_empty out
      assert_match(/Usage: "hive run TARGET"/, err)
    end
  end

  def test_bin_hive_new_treats_help_flag_as_task_text_after_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", project, "add", "--help", "docs")

      assert status.success?, "hive new should capture --help as text after PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      refute_includes out, "Usage:"
      assert_new_idea_includes(dir, "add --help docs")
    end
  end

  def test_bin_hive_new_treats_json_assignment_as_task_text_after_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", project, "literal", "--json=yes", "text")

      assert status.success?, "hive new should capture --json=yes as text after PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      refute_match(/invalid boolean value for --json/, err)
      assert_new_idea_includes(dir, "literal --json=yes text")
    end
  end

  def test_bin_hive_new_accepts_workflow_option_before_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", "--workflow", "coding", project, "workflow", "flag")

      assert status.success?, "hive new should parse --workflow before PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      folder = only_inbox_folder(dir, "workflow-flag-*")
      assert_equal "coding", Hive::TaskMeta.read(folder)[:workflow]
    end
  end

  def test_bin_hive_new_lifts_workflow_option_after_project
    with_cli_project do |dir, project|
      out, err, status = run_bin_hive("new", project, "--workflow", "coding", "literal")

      assert status.success?, "hive new should parse --workflow after PROJECT, stderr was: #{err}"
      assert_includes out, "hive: captured"
      folder = only_inbox_folder(dir, "literal-*")
      assert_equal "coding", Hive::TaskMeta.read(folder)[:workflow]
      refute_includes File.read(File.join(folder, "idea.md")), "--workflow"
    end
  end

  private

  def with_cli_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        yield dir, File.basename(dir)
      end
    end
  end

  def run_bin_hive(*args)
    Open3.capture3(
      { "HIVE_BIN" => "/nonexistent/hive" },
      RbConfig.ruby, "-Ilib", "bin/hive", *args
    )
  end

  def run_status_json!(*args, home:)
    env = {
      "HIVE_HOME" => home,
      "HOME" => home,
      "PATH" => ENV.fetch("PATH", "")
    }
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "bin/hive", *args)
    assert status.success?, "bin/hive #{args.join(" ")} should exit 0, stderr was: #{err}"
    JSON.parse(out)
  end

  def assert_startup_reconcile(chdir, home, args, expected:)
    with_tmp_dir do |dir|
      probe = File.join(dir, "reconciled")
      preload = File.join(dir, "scheduler_probe.rb")
      File.write(preload, <<~RUBY)
        require "hive/llm_wiki_bootstrap"
        Hive::LlmWikiBootstrap::Scheduler.define_singleton_method(:reconcile_existing!) do |**|
          File.write(ENV.fetch("HIVE_RECONCILE_PROBE"), "called")
        end
      RUBY
      env = {
        "HIVE_HOME" => home,
        "HOME" => home,
        "PATH" => ENV.fetch("PATH", ""),
        "HIVE_RECONCILE_PROBE" => probe,
        "RUBYOPT" => [ ENV["RUBYOPT"], "-r#{preload}" ].compact.join(" ")
      }
      bin = File.expand_path("../../bin/hive", __dir__)
      lib = File.expand_path("../../lib", __dir__)
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{lib}", bin, *args, chdir: chdir)

      assert status.success?, "#{args.join(' ')} failed: #{out}\n#{err}"
      assert_equal expected, File.exist?(probe)
    end
  end

  def assert_new_idea_includes(dir, text)
    idea_paths = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*", "idea.md")]
    assert_equal 1, idea_paths.size, "expected one captured idea, got #{idea_paths.inspect}"
    assert_includes File.read(idea_paths.first), text
  end

  def only_inbox_folder(dir, glob)
    folders = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", glob)]
    assert_equal 1, folders.size, "expected one task folder for #{glob.inspect}, got #{folders.inspect}"
    folders.first
  end

  def without_generated_at(payload)
    payload.reject { |key, _value| key == "generated_at" }
  end
end
