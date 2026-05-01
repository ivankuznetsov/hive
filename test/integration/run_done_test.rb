require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/run"

class RunDoneTest < Minitest::Test
  include HiveTestHelper

  def test_done_prints_cleanup_with_pointer
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-x-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)
        File.write(File.join(done_dir, "task.md"), "## work\n<!-- EXECUTE_COMPLETE -->\n")
        File.write(File.join(done_dir, "worktree.yml"),
                   { "path" => "/tmp/wt-feat-x", "branch" => slug }.to_yaml)
        out, _err = capture_io { Hive::Commands::Run.new(done_dir).call }
        assert_includes out, "git worktree remove /tmp/wt-feat-x"
        assert_includes out, "git branch -d #{slug}"
        assert_equal :complete, Hive::Markers.current(File.join(done_dir, "task.md")).name
      end
    end
  end

  def test_done_without_pointer_archives
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-y-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)
        out, _err = capture_io { Hive::Commands::Run.new(done_dir).call }
        assert_includes out, "archived"
      end
    end
  end

  # --json contract: stdout must be a SINGLE parseable JSON document. Before
  # the Done.run! refactor, the stage puts'd cleanup instructions to stdout
  # before report_json wrote the SuccessPayload, breaking JSON.parse(stdout).
  # cleanup_instructions now travels in the envelope under its own key.
  def test_done_json_stdout_is_single_parseable_document_with_pointer
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-json-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)
        File.write(File.join(done_dir, "task.md"), "## work\n<!-- EXECUTE_COMPLETE -->\n")
        File.write(File.join(done_dir, "worktree.yml"),
                   { "path" => "/tmp/wt-feat-json", "branch" => slug }.to_yaml)

        out, _err = capture_io { Hive::Commands::Run.new(done_dir, json: true).call }

        nonblank = out.lines.reject { |l| l.strip.empty? }
        assert_equal 1, nonblank.length,
                     "--json must emit EXACTLY ONE JSON document on stdout, got: #{out.inspect}"

        payload = JSON.parse(out)
        assert_equal "hive-run", payload["schema"]
        assert_equal "complete", payload["marker"]
        assert_kind_of Array, payload["cleanup_instructions"],
                       "cleanup_instructions must be present as an array under --json"
        assert_includes payload["cleanup_instructions"].join("\n"),
                        "git worktree remove /tmp/wt-feat-json"
        assert_includes payload["cleanup_instructions"].join("\n"),
                        "git branch -d #{slug}"

        schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
        assert schemer.valid?(payload),
               "Done --json envelope must validate (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
      end
    end
  end

  def test_done_json_stdout_is_single_parseable_document_without_pointer
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-json-archived-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)

        out, _err = capture_io { Hive::Commands::Run.new(done_dir, json: true).call }

        nonblank = out.lines.reject { |l| l.strip.empty? }
        assert_equal 1, nonblank.length,
                     "--json must emit EXACTLY ONE JSON document on stdout, got: #{out.inspect}"

        payload = JSON.parse(out)
        assert_equal 1, payload["cleanup_instructions"].length
        assert_includes payload["cleanup_instructions"].first, "archived"
      end
    end
  end

  # R3 regression: human path still renders cleanup instructions on stdout.
  def test_done_human_path_still_prints_cleanup_lines
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "feat-human-260424-aaaa"
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(done_dir)
        File.write(File.join(done_dir, "task.md"), "## work\n<!-- EXECUTE_COMPLETE -->\n")
        File.write(File.join(done_dir, "worktree.yml"),
                   { "path" => "/tmp/wt-feat-human", "branch" => slug }.to_yaml)
        out, _err = capture_io { Hive::Commands::Run.new(done_dir).call }
        assert_includes out, "Task #{slug} marked done. To clean up:"
        assert_includes out, "git worktree remove /tmp/wt-feat-human"
        assert_includes out, "git branch -d #{slug}"
        assert_includes out, "(Use -D / --force if the branch was squash-merged.)"
      end
    end
  end
end
