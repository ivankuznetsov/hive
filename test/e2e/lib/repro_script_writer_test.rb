require_relative "../../test_helper"
require "shellwords"
require "tmpdir"
require_relative "repro_script_writer"
require_relative "scenario"

class E2EReproScriptWriterTest < Minitest::Test
  def make_step(kind, args: {}, position: 1)
    Hive::E2E::Step.new(kind: kind, args: args, description: "", position: position)
  end

  def test_writes_executable_script_with_shebang_env_and_cli_command
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [ make_step("cli", args: { "args" => [ "version" ] }) ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 1
          ).write

          assert File.exist?(path), "repro.sh should be written"
          assert_equal 0o755, File.stat(path).mode & 0o777, "repro.sh should be chmod 0755"

          body = File.read(path)
          assert body.start_with?("#!/usr/bin/env bash\n"), "repro.sh should have a bash shebang"
          assert_includes body, "export BUNDLE_GEMFILE="
          assert_includes body, "export HIVE_HOME="
          assert_match(/bin\/hive\b.*\bversion\b/, body, "repro.sh should re-run the failed CLI step")
        end
      end
    end
  end

  # The CLI step runs inside a `( cd <sandbox> && ... )` subshell, so the
  # outer `cd <repo>` at the top of repro.sh does not apply. `-Ilib` and
  # `bin/hive` must resolve as ABSOLUTE paths, otherwise replay looks them
  # up under the sandbox dir and fails to find the gem code / binary.
  def test_cli_step_uses_absolute_paths_for_lib_and_bin_hive
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [ make_step("cli", args: { "args" => [ "version" ] }) ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 1
          ).write

          body = File.read(path)
          refute_match(%r{ -Ilib bin/hive\b}, body,
                       "repro.sh must NOT emit relative -Ilib bin/hive — those resolve under <sandbox> in the subshell")
          assert_match(%r{-I#{Regexp.escape(Hive::E2E::Paths.lib_dir)}}, body,
                       "repro.sh must emit -I<absolute-repo>/lib so it resolves from inside the cd <sandbox> subshell")
          assert_includes body, Hive::E2E::Paths.hive_bin,
                          "repro.sh must reference the absolute path to bin/hive"
        end
      end
    end
  end

  def test_cd_uses_absolute_repo_root
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: [], failed_index: 0
          ).write

          body = File.read(path)
          assert_includes body, "cd #{Shellwords.escape(Hive::E2E::Paths.repo_root)}",
            "repro.sh should not derive repo root from the run artifact location, body was:\n#{body}"
        end
      end
    end
  end

  def test_setup_steps_replay_inline_and_live_tmux_steps_skip
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [
            make_step("seed_state",
                      args: { "stage" => "2-brainstorm", "slug" => "auth-task",
                              "state_file" => "brainstorm.md", "content" => "# Brainstorm\n<!-- COMPLETE -->\n" },
                      position: 1),
            make_step("write_file",
                      args: { "path" => "notes/extra.md", "content" => "extra\n" },
                      position: 2),
            make_step("register_project", args: { "name" => "project-b" }, position: 3),
            make_step("ruby_block", args: { "block" => "puts 1" }, position: 4),
            make_step("tui_keys", args: { "keys" => "p" }, position: 5),
            make_step("tui_expect", args: { "anchor" => "hive tui" }, position: 6),
            make_step("cli", args: { "args" => [ "version" ] }, position: 7)
          ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 7
          ).write

          body = File.read(path)
          # Setup steps must REPLAY inline — not be commented out.
          refute_match(/# step \d+ skipped: kind=seed_state/, body, "seed_state must replay inline")
          refute_match(/# step \d+ skipped: kind=write_file/, body, "write_file must replay inline")
          refute_match(/# step \d+ skipped: kind=register_project/, body, "register_project must replay inline")
          refute_match(/# step \d+ skipped: kind=ruby_block/, body, "ruby_block must replay inline")
          assert_includes body, "seed_state: 2-brainstorm/auth-task",
                          "seed_state should emit a heredoc-write block"
          assert_includes body, "<!-- COMPLETE -->", "seed_state content must land in the heredoc body"
          assert_includes body, "write_file: notes/extra.md",
                          "write_file should emit a heredoc-write block"
          assert_includes body, "register_project: project-b",
                          "register_project should emit a cp -a + bin/hive init block"
          refute_match(%r{cd .* -Ilib bin/hive init}, body,
                       "register_project replay must not use relative -Ilib bin/hive from the copied project")
          assert_includes body, Hive::E2E::Paths.hive_bin,
                          "register_project replay must use the absolute hive binary"
          assert_includes body, "ruby_block runs with sandbox, run_home, and slug locals restored",
                          "ruby_block must include the restored binding-context note"
          # Live-tmux steps are explicitly skipped with the new comment.
          assert_includes body, "step 5 skipped: requires live tmux (kind=tui_keys)",
                          "tui_keys cannot replay offline"
          assert_includes body, "step 6 skipped: requires live tmux (kind=tui_expect)",
                          "tui_expect cannot replay offline"
          # cli step still re-runs.
          assert_match(/bin\/hive\b.*\bversion\b/, body, "the cli step is still emitted")
        end
      end
    end
  end

  def test_state_assert_and_log_assert_emit_real_checks
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [
            make_step("state_assert",
                      args: { "path" => "{task_dir:3-plan}/plan.md" }, position: 1),
            make_step("log_assert",
                      args: { "path" => "log.txt", "match" => "ok" }, position: 2)
          ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 2
          ).write

          body = File.read(path)
          assert_includes body, "# step 1 state_assert:"
          assert_match(/state_assert.*failed/m, body)
          assert_includes body, "# step 2 log_assert:"
          assert_match(/log.*not.*found/m, body)
        end
      end
    end
  end

  def test_rejects_shell_metacharacters_in_seed_state_paths
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [
            make_step("seed_state",
                      args: { "stage" => "2-brainstorm", "slug" => "auth-task",
                              "state_file" => "../$(touch hacked)" },
                      position: 1)
          ]

          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 1
          ).write

          body = File.read(path)
          assert_includes body, "not replayable: unsafe seed_state input"
          assert_includes body, "exit 1"
        end
      end
    end
  end

  def test_shellwords_escape_applied_to_env_values
    Dir.mktmpdir("scenario") do |scenario_dir|
      # Construct a sandbox path containing a space — the writer must
      # Shellwords.escape values so `export BUNDLE_GEMFILE=...` survives.
      Dir.mktmpdir("withspace") do |parent|
        sandbox = File.join(parent, "with space sandbox")
        FileUtils.mkdir_p(sandbox)
        Dir.mktmpdir("home") do |run_home|
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: [], failed_index: 0
          ).write

          body = File.read(path)
          export_line = body.lines.find { |line| line.start_with?("export BUNDLE_GEMFILE=") }
          refute_nil export_line, "BUNDLE_GEMFILE export line should be present"
          # An unescaped space would split the value; escaped values either
          # quote (`'a b'`) or backslash-escape (`a\ b`).
          assert export_line.include?("\\ ") || export_line.include?("'"),
            "BUNDLE_GEMFILE value with spaces must be shell-escaped, was: #{export_line.inspect}"
        end
      end
    end
  end

  def test_cli_steps_expand_placeholders_env_cwd_and_expected_exit
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [
            make_step("cli",
                      args: {
                        "args" => [ "run", "{slug}", "--stage", "4-execute" ],
                        "env" => { "HIVE_FAKE_CLAUDE_WRITE_FILE" => "{task_dir:4-execute}/task.md" },
                        "cwd" => "{sandbox}",
                        "expect_exit" => 75
                      },
                      position: 1)
          ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir,
            sandbox_dir: sandbox,
            run_home: run_home,
            steps: steps,
            failed_index: 1,
            expander_context: {
              sandbox_dir: sandbox,
              run_home: run_home,
              run_id: "run-1",
              slug: "expanded-slug"
            }
          ).write

          body = File.read(path)
          assert_includes body, "expanded-slug", "CLI args should be expanded before replay"
          assert_includes body, File.join(sandbox, ".hive-state", "stages", "4-execute", "expanded-slug", "task.md"),
                          "per-step env should be expanded before replay"
          assert_includes body, "if [ \"$status\" -ne 75 ]",
                          "expected non-zero exits should not abort under set -e before validation"
        end
      end
    end
  end

  def test_seed_state_without_slug_uses_executor_default_slug
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [ make_step("seed_state", args: { "stage" => "2-brainstorm" }, position: 1) ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir,
            sandbox_dir: sandbox,
            run_home: run_home,
            steps: steps,
            failed_index: 1,
            scenario_name: "my_scenario"
          ).write

          assert_includes File.read(path), "my-scenario-task",
            "seed_state default slug should match StepExecutor's scenario-name default"
        end
      end
    end
  end
end
