require_relative "../../test_helper"
require "open3"
require_relative "gh_stub"
require_relative "repro_script_writer"
require_relative "scenario"

class E2EReproScriptWriterTest < Minitest::Test
  def make_step(kind, args: {}, position: 1)
    Hive::E2E::Step.new(kind: kind, args: args, description: "", position: position)
  end

  # Regression (ce-code-review): update-flow scenarios write/assert under
  # {run_home} and use the new stateful step kinds. The repro must NOT abort
  # at "step 1 not replayable" — run_home paths replay, and start_releases_stub
  # / spawn_background / stop_process emit RUNNABLE bash (not informational
  # comments) so failure artifacts actually replay.
  def test_run_home_paths_and_new_kinds_produce_a_usable_repro
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [
            make_step("write_file", args: { "path" => "{run_home}/install-channel", "content" => "brew\n" }, position: 1),
            make_step("start_releases_stub", args: { "tag" => "v999.0.0" }, position: 2),
            make_step("spawn_background", args: { "id" => "daemon", "args" => %w[daemon start] }, position: 3),
            make_step("state_assert", args: { "path" => "{run_home}/update_check.json", "match" => "999" }, position: 4),
            make_step("stop_process", args: { "id" => "daemon" }, position: 5)
          ]
          body = File.read(Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 5
          ).write)

          refute_match(/not replayable/, body, "run_home write_file must replay, not abort the repro")
          assert_match(/cat > \S*install-channel/, body, "run_home write_file should emit a heredoc")
          assert_includes body, File.join(run_home, "update_check.json")
          # start_releases_stub launches ReleasesStubServer in a background Ruby
          # child, captures its URL via a tempfile, and exports HIVE_RELEASES_API_URL.
          assert_match(/# step 2 start_releases_stub: tag=v999\.0\.0/, body)
          assert_match(/HIVE_REPRO_STUB_URL_FILE=\$\(mktemp/, body,
                       "start_releases_stub must capture the stub's URL via mktemp + ReleasesStubServer")
          # Shellwords escapes the single quotes around the require literal;
          # match the Ruby identifier instead. This both proves the stub-server
          # class is being required AND that ruby_body went into the -e flag.
          assert_includes body, "releases_stub_server",
                          "start_releases_stub must require the harness's stub-server class"
          assert_match(/ -e /, body,
                       "start_releases_stub must invoke ruby -e with the inline server script")
          assert_match(/export HIVE_RELEASES_API_URL=/, body,
                       "start_releases_stub must export HIVE_RELEASES_API_URL for downstream steps")
          # spawn_background launches the daemon under setsid (matching
          # BackgroundProcess pgroup: true) and captures its PID for stop_process.
          assert_match(/# step 3 spawn_background id=daemon: hive daemon start/, body)
          assert_match(/setsid /, body, "spawn_background must use setsid so the pgroup matches BackgroundProcess")
          assert_match(/HIVE_REPRO_BG_PID_DAEMON=\$!/, body,
                       "spawn_background must capture $! into a per-id PID variable")
          assert_match(/HIVE_REPRO_BG_PIDS\+=\("\$HIVE_REPRO_BG_PID_DAEMON"\)/, body,
                       "spawn_background must register the PID in the global teardown array")
          # stop_process TERMs the matching pgroup with a brief KILL grace.
          assert_match(/# step 5 stop_process id=daemon/, body)
          assert_match(/kill -TERM -"\$HIVE_REPRO_BG_PID_DAEMON"/, body,
                       "stop_process must signal the per-id PID's pgroup")
          # Script-level teardown trap reaps any survivors.
          assert_match(/trap _hive_repro_cleanup EXIT/, body,
                       "the harness teardown trap must be installed at script entry")
        end
      end
    end
  end

  def test_script_gh_repro_installs_the_expanded_interactions
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          # A failure run already has transcript state. Replay must start a
          # fresh transcript instead of failing on the single-install guard;
          # the original evidence was copied into the scenario artifact dir.
          Hive::E2E::GhStub.new(run_home).install([])
          step = make_step(
            "script_gh",
            args: {
              "interactions" => [
                { "args" => [ "pr", "view", "7" ], "cwd" => "{sandbox}",
                  "response" => { "state" => "OPEN" } }
              ]
            }
          )
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: [ step ], failed_index: 1
          ).write

          body = File.read(path)
          assert_includes body, "GhStub"
          assert_includes body, sandbox
          assert_includes body, "pr"
          assert_includes body, "rm_rf"
          assert_includes body, "complete default-deny GitHub transcript"
          cleanup_index = body.rindex("_hive_repro_cleanup")
          verification_index = body.index("# verify the complete default-deny GitHub transcript")
          assert_operator cleanup_index, :<, verification_index,
                          "background producers must stop before GitHub transcript verification"
          out = `bash -n #{Shellwords.escape(path)} 2>&1`
          assert $CHILD_STATUS.success?, "script_gh repro must be valid bash: #{out}"
        end
      end
    end
  end

  def test_script_gh_repro_fails_when_expected_interactions_are_unconsumed
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          Hive::E2E::GhStub.new(run_home).install([])
          step = make_step(
            "script_gh",
            args: { "interactions" => [ { "args" => [ "pr", "view", "7" ] } ] }
          )
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: [ step ], failed_index: 1
          ).write

          _out, err, status = Open3.capture3("bash", path)

          refute status.success?
          assert_match(/consumed 0 of 1/, err)
        end
      end
    end
  end

  # The generated repro for the update-flow pipeline must be syntactically
  # valid bash. Catches accidental quoting / heredoc / line-continuation
  # regressions in the new stateful-kind emissions without needing a real
  # daemon to replay end-to-end.
  def test_update_flow_pipeline_repro_is_syntactically_valid_bash
    require_relative "scenario_parser"
    require_relative "paths"

    scenario_path = File.join(Hive::E2E::Paths.scenarios_dir, "update_flow_pipeline.yml")
    scenario = Hive::E2E::ScenarioParser.parse(scenario_path)

    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: scenario.steps, failed_index: scenario.steps.size
          ).write

          out = `bash -n #{Shellwords.escape(path)} 2>&1`
          assert $CHILD_STATUS.success?, "bash -n must accept the generated repro.sh:\n#{out}\n\nscript:\n#{File.read(path)}"
        end
      end
    end
  end

  # The two single-step blocks for start_releases_stub and stop_process
  # must themselves be valid bash — i.e. quoting around the embedded Ruby
  # heredoc-equivalents holds up. Easier to inspect than the full pipeline.
  def test_start_releases_stub_block_parses_with_bash
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [ make_step("start_releases_stub", args: { "tag" => "v1.2.3" }, position: 1) ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 1
          ).write

          out = `bash -n #{Shellwords.escape(path)} 2>&1`
          assert $CHILD_STATUS.success?, "start_releases_stub block must be valid bash:\n#{out}\n\n#{File.read(path)}"
        end
      end
    end
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
            make_step("tui_expect", args: { "anchor" => "Tasks ·" }, position: 6),
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
          assert_includes body, Shellwords.escape("cfg['claude']['mode'] = 'headless'"),
                          "secondary-project replay must not enter interactive agent mode"
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

  def test_patrol_evidence_replay_is_executable_and_confined_to_the_preserved_run
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          step = make_step(
            "patrol_evidence",
            args: {}
          )
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox,
            run_home: run_home, steps: [ step ], failed_index: 1,
            coverage_id:
              "module.patrol_compressed_evidence_diagnostic"
          ).write

          body = File.read(path)
          assert_includes body, "patrol_qualification_runner"
          assert_includes body, "coverage_complete\\?"
          assert_includes body,
                          "module.patrol_compressed_evidence_diagnostic"
          refute_includes body, "compressed-run-1"
          assert_includes body, sandbox
          assert_includes body, run_home
          assert_includes body,
                          File.join(scenario_dir, "patrol-evidence")
          refute_includes body, "skipped: kind=patrol_evidence"
          out = `bash -n #{Shellwords.escape(path)} 2>&1`
          assert $CHILD_STATUS.success?,
                 "patrol evidence repro must be valid bash: #{out}"
        end
      end
    end
  end
end
