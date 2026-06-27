require "fileutils"
require "time"
require "yaml"
require "hive/archive_filter"
require "hive/commands/status"
require "hive/config"
require "hive/lock"
require "hive/task"
require "hive/task_meta"

module HiveTuiScaleFixture
  DEFAULT_ACTIVE_COUNT = 8
  ACTIVE_STAGES = (Hive::Stages::DIRS - [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]).freeze

  module_function

  def build(root:, projects: 8, tasks_per_project: 200, active_count: DEFAULT_ACTIVE_COUNT)
    max_tasks = projects * tasks_per_project
    raise ArgumentError, "active_count cannot exceed total task count" if active_count > max_tasks

    project_entries = []
    active_counts = active_counts_by_project(projects, active_count)
    active_index = 0
    id = 1
    projects.times do |project_index|
      project_root = File.join(root, "project-#{project_index + 1}")
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      Hive::Stages::DIRS.each { |stage| FileUtils.mkdir_p(File.join(hive_state, "stages", stage)) }
      File.write(File.join(hive_state, "config.yml"), Hive::Config::DEFAULTS.to_yaml)
      project_entries << {
        "name" => File.basename(project_root),
        "path" => project_root,
        "hive_state_path" => hive_state
      }

      active_counts.fetch(project_index).times do |task_index|
        stage = ACTIVE_STAGES[active_index % ACTIVE_STAGES.length]
        slug = slug_for(project_index, task_index, "active")
        write_task(hive_state, stage, slug, id: id, marker: marker_for(stage), active_index: active_index)
        id += 1
        active_index += 1
      end

      archived_total = tasks_per_project - active_counts.fetch(project_index)
      archived_total.times do |task_index|
        slug = slug_for(project_index, task_index, "archived")
        write_task(hive_state, Hive::ArchiveFilter::ARCHIVE_STAGE_DIR, slug, id: id, marker: "COMPLETE")
        id += 1
      end
    end
    write_registry(project_entries)
    project_entries
  end

  def active_counts_by_project(projects, active_count)
    Array.new(projects) do |index|
      base = active_count / projects
      index < (active_count % projects) ? base + 1 : base
    end
  end

  def write_registry(projects)
    config_path = Hive::Config.global_config_path
    FileUtils.mkdir_p(File.dirname(config_path))
    File.write(config_path, { "registered_projects" => projects }.to_yaml)
  end

  def write_task(hive_state, stage, slug, id:, marker:, active_index: nil)
    folder = File.join(hive_state, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: display_name_for(slug))
    File.write(File.join(folder, state_file_for(stage)), state_body(stage, marker))
    write_lock(folder) if active_index && (active_index % 5).zero?
    write_pr(folder) if stage_index(stage) >= stage_index(Hive::Commands::Status::OPEN_PR_STAGE_DIR)
    folder
  end

  def state_file_for(stage)
    _, name = Hive::Stages.parse(stage)
    Hive::Task::STATE_FILES.fetch(name)
  end

  def state_body(stage, marker)
    title = stage.split("-", 2).last.capitalize
    "# #{title}\n<!-- #{marker} -->\n"
  end

  def write_lock(folder)
    File.write(File.join(folder, ".lock"), {
      "pid" => Process.pid,
      "process_start_time" => Hive::Lock.process_start_time(Process.pid)
    }.to_yaml)
  end

  def write_pr(folder)
    File.write(File.join(folder, "pr.md"), <<~MD)
      ---
      pr_url: https://github.com/example/hive/pull/1
      ---
      # Pull request
    MD
  end

  def marker_for(stage)
    case stage
    when "1-inbox" then "WAITING"
    when "2-brainstorm" then "COMPLETE"
    when "3-plan" then "WAITING"
    when "4-execute" then "EXECUTE_COMPLETE"
    when "5-open-pr" then "COMPLETE"
    when "6-review" then "REVIEW_WAITING escalations=1 pass=1"
    when "7-artifacts" then "COMPLETE"
    when "8-finalize" then "COMPLETE"
    else "COMPLETE"
    end
  end

  def slug_for(project_index, task_index, prefix)
    format("%<prefix>s-task-%<project>02d-%<task>04d", prefix: prefix,
                                                        project: project_index + 1,
                                                        task: task_index + 1)
  end

  def display_name_for(slug)
    slug.tr("-", " ").capitalize
  end

  def stage_index(stage)
    Hive::Stages.parse(stage).first
  end
end
