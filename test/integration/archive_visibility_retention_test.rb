require "test_helper"
require "hive/commands/status"
require "hive/daemon/status_consumer"
require "hive/operational_status"
require "hive/tui/snapshot"
require "hive/web/status_feed"

class ArchiveVisibilityRetentionTest < Minitest::Test
  include HiveTestHelper

  FixedStatus = Data.define(:command, :project, :now) do
    def json_payload(_registered_projects)
      command.json_payload([ project ], now: now)
    end
  end

  NOW = Time.utc(2026, 7, 24, 12, 0, 0)
  DAY = Hive::ArchiveFilter::SECONDS_PER_DAY

  def test_one_fixed_generation_drives_status_operational_daemon_tui_and_web
    with_tmp_global_config do
      with_tmp_dir do |project_root|
        project = build_mixed_project(project_root)
        ordinary_command = Hive::Commands::Status.new
        archive_command = Hive::Commands::Status.new(archive: true)
        feed = Hive::Web::StatusFeed.new(
          status_command: FixedStatus.new(command: ordinary_command, project:, now: NOW),
          archive_status_command: FixedStatus.new(command: archive_command, project:, now: NOW)
        )

        ordinary = feed.snapshot
        archive = feed.archive_snapshot
        ordinary_project = ordinary.fetch("projects").fetch(0)
        archive_project = archive.fetch("projects").fetch(0)
        ordinary_slugs = ordinary_project.fetch("tasks").map { |row| row.fetch("slug") }.sort
        archive_slugs = archive_project.fetch("tasks").map { |row| row.fetch("slug") }.sort

        assert_equal %w[
          active-coding-260724-abcd boundary-legacy-260721-abcd
          visible-forever-260416-abcd visible-seven-260719-abcd
          visible-three-260722-abcd
        ], ordinary_slugs
        assert_equal %w[
          boundary-legacy-260721-abcd expired-legacy-260720-abcd
          expired-seven-260716-abcd expired-three-260720-abcd
          visible-forever-260416-abcd visible-seven-260719-abcd
          visible-three-260722-abcd
        ], archive_slugs
        assert_equal 3, ordinary_project.fetch("hidden_archived_task_count")
        refute archive_project.key?("hidden_archived_task_count")

        (ordinary_project.fetch("tasks") + archive_project.fetch("tasks")).each do |row|
          refute row.key?("completed_at")
          refute row.key?("archive_visibility_retention_days")
        end

        operational = Hive::OperationalStatus.new(
          status_payload: ordinary,
          project_context: { "demo" => { "daemon_enabled" => false } },
          now: NOW
        ).to_h
        assert_equal 1, operational.dig("summary", "active")
        assert_equal 4, operational.dig("summary", "archived")
        assert_equal 3, operational.dig("summary", "hidden_archived_task_count")

        consumer = Hive::Daemon::StatusConsumer.new
        daemon_projects = consumer.send(:extract_projects, ordinary)
        daemon_rows = consumer.send(:extract_rows, ordinary)
        assert_equal 1, daemon_projects.size
        assert_equal 3, daemon_projects.fetch(0).hidden_archived_task_count
        assert_equal ordinary_slugs, daemon_rows.map(&:slug).sort

        tui = Hive::Tui::Snapshot.from_payload(ordinary, archive_payload: archive)
        assert_equal ordinary_slugs, tui.rows.map(&:slug).sort
        assert_equal archive_slugs, tui.archive_rows.map(&:slug).sort
        assert_equal 3, tui.hidden_archived_task_count
      ensure
        feed&.stop
        Hive::Workflows::Project.reset!
      end
    end
  end

  def test_same_size_policy_edit_reprojects_on_the_next_web_refresh
    with_tmp_global_config do
      with_tmp_dir do |project_root|
        project = build_mixed_project(project_root)
        seven_path = File.join(project.fetch("hive_state_path"), "workflows", "seven.yml")
        original_mtime = File.mtime(seven_path)
        feed = Hive::Web::StatusFeed.new(
          status_command: FixedStatus.new(
            command: Hive::Commands::Status.new, project:, now: NOW
          )
        )
        initial = feed.snapshot
        initial_token = feed.prime(initial)

        descriptor = File.read(seven_path).sub(
          "archive_visibility_retention_days: 7",
          "archive_visibility_retention_days: 3"
        )
        File.write(seven_path, descriptor)
        File.utime(original_mtime, original_mtime, seven_path)
        changed = feed.snapshot
        feed.send(:publish, changed)

        project_payload = changed.fetch("projects").fetch(0)
        refute_includes project_payload.fetch("tasks").map { |row| row.fetch("slug") },
                        "visible-seven-260719-abcd"
        assert_equal 4, project_payload.fetch("hidden_archived_task_count")
        refute feed.current_version?(initial_token)
      ensure
        feed&.stop
        Hive::Workflows::Project.reset!
      end
    end
  end

  private

  def build_mixed_project(project_root)
    hive_state = File.join(project_root, ".hive-state")
    workflows = File.join(hive_state, "workflows")
    FileUtils.mkdir_p(workflows)
    write_workflow(workflows, "legacy", nil)
    write_workflow(workflows, "three", 3)
    write_workflow(workflows, "seven", 7)
    write_workflow(workflows, "forever", "never")

    write_task(
      hive_state, "1-inbox", "active-coding-260724-abcd",
      state_file: "idea.md", marker: "WAITING"
    )
    write_task(
      hive_state, "2-done", "expired-legacy-260720-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "legacy",
      completed_at: NOW - (4 * DAY)
    )
    write_task(
      hive_state, "2-done", "boundary-legacy-260721-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "legacy",
      completed_at: NOW - (3 * DAY)
    )
    write_task(
      hive_state, "2-done", "visible-three-260722-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "three",
      completed_at: NOW - (2 * DAY)
    )
    write_task(
      hive_state, "2-done", "expired-three-260720-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "three",
      completed_at: NOW - (4 * DAY)
    )
    write_task(
      hive_state, "2-done", "visible-seven-260719-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "seven",
      completed_at: NOW - (5 * DAY)
    )
    write_task(
      hive_state, "2-done", "expired-seven-260716-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "seven",
      completed_at: NOW - (8 * DAY)
    )
    write_task(
      hive_state, "2-done", "visible-forever-260416-abcd",
      state_file: "done.md", marker: "COMPLETE", workflow: "forever",
      completed_at: NOW - (99 * DAY)
    )

    { "name" => "demo", "path" => project_root, "hive_state_path" => hive_state }
  end

  def write_workflow(workflows, id, retention)
    retention_line = if retention.nil?
      ""
    else
      "archive_visibility_retention_days: #{retention}\n"
    end
    File.write(File.join(workflows, "#{id}.yml"), <<~YAML)
      id: #{id}
      #{retention_line}stages:
        - name: inbox
          kind: terminal
          state_file: idea.md
        - name: done
          kind: terminal
          state_file: done.md
    YAML
  end

  def write_task(hive_state, stage, slug, state_file:, marker:, workflow: nil, completed_at: nil)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, state_file), "<!-- #{marker} -->\n")
    Hive::TaskMeta.write(
      folder,
      id: nil,
      slug: slug,
      display_name: nil,
      workflow: workflow,
      completed_at: completed_at
    )
  end
end
