require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/init"
require "hive/commands/run"

class RunDoneTest < Minitest::Test
  include HiveTestHelper

  def test_done_removes_registered_worktree_and_local_branch_then_records_receipt
    with_ready_done_task(create_worktree: true) do |dir, task|
      path = Hive::Worktree.read_pointer(task.folder).fetch("path")

      out, _err = capture_io { Hive::Commands::Run.new(task.folder).call }

      refute File.exist?(path)
      refute Hive::GitOps.new(dir).ref_exists?("refs/heads/#{task.slug}")
      assert_includes out, "local recovery state was removed"
      assert_equal :complete, Hive::Markers.current(task.state_file).name
      records = Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl"))
      assert_equal 1, records.count { |record| record["event_type"] == "cleanup_completed" }
      receipt = records.find { |record| record["event_type"] == "cleanup_completed" }
      assert_equal false, receipt.dig("payload", "remote_branch_deleted")
    end
  end

  def test_done_resumes_when_resources_were_already_removed
    with_ready_done_task do |_dir, task|
      out, _err = capture_io { Hive::Commands::Run.new(task.folder).call }

      assert_includes out, "cleanup receipt"
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_done_json_is_one_schema_valid_document_with_receipt
    with_ready_done_task do |_dir, task|
      out, _err = capture_io { Hive::Commands::Run.new(task.folder, json: true).call }

      assert_equal 1, out.lines.reject { |line| line.strip.empty? }.length
      payload = JSON.parse(out)
      assert_equal "hive-run", payload["schema"]
      assert_equal "complete", payload["marker"]
      assert_includes payload.fetch("cleanup_instructions").join("\n"), "cleanup receipt"
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
      assert schemer.valid?(payload), schemer.validate(payload).map { |error| error["error"] }.inspect
      assert_equal "terminal_stage", payload.dig("rebase", "reason")
    end
  end

  def test_done_rejects_a_missing_pointer_without_marking_complete
    with_ready_done_task do |_dir, task|
      FileUtils.rm_f(File.join(task.folder, "worktree.yml"))

      error = assert_raises(Hive::WorktreeError) do
        Hive::Commands::Run.new(task.folder).call
      end

      assert_includes error.message, "retained worktree pointer"
      refute_equal :complete, Hive::Markers.current(task.state_file).name
      records = Hive::TaskProjection.read_journal(File.join(task.folder, "events.jsonl"))
      refute records.any? { |record| record["event_type"] == "cleanup_completed" }
    end
  end

  private

  def with_ready_done_task(create_worktree: false)
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "durable-done-260717-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "9-done", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "task.md"), "## archived\n")
        if create_worktree
          Hive::Worktree.new(dir, slug).create!(slug, default_branch: "master")
        end
        prepare_archive_ready(project_root: dir, task_folder: folder, slug: slug)
        yield dir, Hive::Task.new(folder)
      end
    end
  end
end
