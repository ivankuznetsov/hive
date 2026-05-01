require "test_helper"
require "hive/config"
require "hive/task"
require "hive/stages/done"

# Unit-level pin on Hive::Stages::Done.run!: it must return cleanup_instructions
# in its result hash and write nothing to stdout. The previous implementation
# puts'd the cleanup lines, which polluted stdout under `hive run --json`
# (lines landed on stdout BEFORE report_json's SuccessPayload, breaking
# JSON.parse(stdout)). See test/integration/run_done_test.rb for the
# end-to-end contract; this file pins the stage-level invariant.
class StagesDoneTest < Minitest::Test
  include HiveTestHelper

  def test_run_returns_cleanup_instructions_with_pointer_and_writes_nothing_to_stdout
    with_tmp_dir do |dir|
      slug = "feat-x-260424-aaaa"
      folder = File.join(dir, ".hive-state", "stages", "7-done", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "worktree.yml"),
                 { "path" => "/tmp/wt-feat-x", "branch" => slug }.to_yaml)
      task = Hive::Task.new(folder)
      cfg = Hive::Config.load(dir)

      result = nil
      out, err = capture_io { result = Hive::Stages::Done.run!(task, cfg) }

      assert_empty out, "Done.run! must not write to stdout (caller renders cleanup_instructions)"
      assert_empty err, "Done.run! must not write to stderr"
      assert_equal "archived", result[:commit]
      assert_equal :complete, result[:status]
      assert_kind_of Array, result[:cleanup_instructions]
      assert_equal 5, result[:cleanup_instructions].length,
                   "with-pointer instruction set is exactly 5 lines (header + 3 commands + footer)"
      joined = result[:cleanup_instructions].join("\n")
      assert_includes joined, "Task #{slug} marked done. To clean up:"
      assert_includes joined, "git worktree remove /tmp/wt-feat-x"
      assert_includes joined, "git branch -d #{slug}"
      assert_includes joined, "(Use -D / --force if the branch was squash-merged.)"
    end
  end

  def test_run_returns_archived_message_without_pointer
    with_tmp_dir do |dir|
      slug = "feat-y-260424-bbbb"
      folder = File.join(dir, ".hive-state", "stages", "7-done", slug)
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      cfg = Hive::Config.load(dir)

      result = nil
      out, err = capture_io { result = Hive::Stages::Done.run!(task, cfg) }

      assert_empty out
      assert_empty err
      assert_equal [ "Task #{slug} archived. No worktree pointer; nothing to clean up." ],
                   result[:cleanup_instructions]
    end
  end

  def test_run_sets_complete_marker_on_state_file
    with_tmp_dir do |dir|
      slug = "feat-z-260424-cccc"
      folder = File.join(dir, ".hive-state", "stages", "7-done", slug)
      FileUtils.mkdir_p(folder)
      task = Hive::Task.new(folder)
      cfg = Hive::Config.load(dir)

      capture_io { Hive::Stages::Done.run!(task, cfg) }

      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end
end
