require_relative "../../test_helper"
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

  def test_cd_uses_realpath_six_ups_to_repo_root
    # repro.sh lives at <repo>/test/e2e/runs/<id>/scenarios/<name>/repro.sh.
    # Six `..` reaches the repo root; we wrap in realpath so a wrong depth
    # surfaces visibly (rather than silently cd'ing into a stale parent).
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: [], failed_index: 0
          ).write

          body = File.read(path)
          assert_includes body, 'cd "$(realpath "$(dirname "$0")/../../../../../..")"',
            "repro.sh should cd via 6-ups + realpath, body was:\n#{body}"
        end
      end
    end
  end

  def test_non_cli_steps_emit_skipped_comment
    Dir.mktmpdir("scenario") do |scenario_dir|
      Dir.mktmpdir("sandbox") do |sandbox|
        Dir.mktmpdir("home") do |run_home|
          steps = [
            make_step("ruby_block", args: { "block" => "puts 1" }, position: 1),
            make_step("cli", args: { "args" => [ "version" ] }, position: 2)
          ]
          path = Hive::E2E::ReproScriptWriter.new(
            scenario_dir: scenario_dir, sandbox_dir: sandbox, run_home: run_home,
            steps: steps, failed_index: 2
          ).write

          body = File.read(path)
          assert_includes body, "# step skipped: kind=ruby_block (stateful)",
            "non-CLI steps should be commented out, not silently dropped"
          assert_match(/bin\/hive\b.*\bversion\b/, body, "the cli step is still emitted")
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
end
