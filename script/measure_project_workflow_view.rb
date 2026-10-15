# frozen_string_literal: true

# Compares the project-workflow reader boundary across two source revisions.
# Run this script once with each revision's lib directory, on the same host:
#
#   HIVE_WORKFLOW_VIEW_LABEL=baseline \
#     HIVE_WORKFLOW_VIEW_LIB=tmp/workflow-view-baseline/lib \
#     bundle exec ruby script/measure_project_workflow_view.rb
#   HIVE_WORKFLOW_VIEW_LABEL=candidate \
#     bundle exec ruby script/measure_project_workflow_view.rb
#
# Every timed status and StatusFeed sample resets Project's parsed overlay so
# the measurement includes configuration, fingerprint, descriptor, and managed
# selection I/O. The Monitor workload adds a fixed activation stall to project A
# and measures whether project B can finish while that I/O remains blocked.

source_lib = File.expand_path(
  ENV.fetch("HIVE_WORKFLOW_VIEW_LIB", File.expand_path("../lib", __dir__))
)
$LOAD_PATH.delete(source_lib)
$LOAD_PATH.unshift(source_lib)

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "hive/commands/status"
require "hive/task_meta"
require "hive/web/status_feed"

module ProjectWorkflowViewMeasurement
  SOURCE_LIB = $LOAD_PATH.first.freeze
  RUNS = Integer(ENV.fetch("HIVE_WORKFLOW_VIEW_RUNS", "3"))
  SAMPLES = Integer(ENV.fetch("HIVE_WORKFLOW_VIEW_SAMPLES", "5"))
  PROJECTS = Integer(ENV.fetch("HIVE_WORKFLOW_VIEW_PROJECTS", "3"))
  TASKS_PER_PROJECT = Integer(ENV.fetch("HIVE_WORKFLOW_VIEW_TASKS", "4"))
  STALL_MS = Float(ENV.fetch("HIVE_WORKFLOW_VIEW_STALL_MS", "25"))

  module LoaderProbe
    class << self
      def reset!
        mutex.synchronize { @durations = [] }
      end

      def durations
        mutex.synchronize { Array(@durations).dup }
      end

      def stall!(directory, entered:, release:)
        mutex.synchronize { @stall = [ directory, entered, release ] }
      end

      def clear_stall!
        mutex.synchronize { @stall = nil }
      end

      def before_load(directory)
        stall = mutex.synchronize { @stall }
        return unless stall && stall.first == directory

        stall.fetch(1) << true
        stall.fetch(2).pop
      end

      def record(duration)
        mutex.synchronize { (@durations ||= []) << duration }
      end

      private

      def mutex
        @mutex ||= Mutex.new
      end
    end

    def load_dir(directory)
      LoaderProbe.before_load(directory)
      started = ProjectWorkflowViewMeasurement.monotonic
      super
    ensure
      if started
        LoaderProbe.record((ProjectWorkflowViewMeasurement.monotonic - started) * 1_000)
      end
    end
  end

  module_function

  def run
    validate_dimensions!
    install_loader_probe!
    Dir.mktmpdir("hive-project-workflow-view-measurement") do |root|
      ENV["HIVE_HOME"] = File.join(root, "home")
      FileUtils.mkdir_p(ENV.fetch("HIVE_HOME"))
      Hive::RuntimeControlPlane.database.migrate!
      projects = build_projects(root)
      install_registered_projects(projects)
      warm(projects)

      status_runs = measure_runs { measure_status(projects) }
      feed_runs = measure_runs { measure_status_feed }
      monitor_runs = measure_runs { measure_monitor_wait(projects.first(2)) }

      puts JSON.pretty_generate(
        "schema" => "hive-project-workflow-view-measurement",
        "schema_version" => 1,
        "label" => ENV.fetch("HIVE_WORKFLOW_VIEW_LABEL", "candidate"),
        "source_lib" => SOURCE_LIB,
        "ruby" => RUBY_DESCRIPTION,
        "workload" => {
          "runs" => RUNS,
          "samples_per_run" => SAMPLES,
          "projects" => PROJECTS,
          "tasks_per_project" => TASKS_PER_PROJECT,
          "activation" => "Project.reset! before every timed sample; warm OS file cache",
          "monitor_activation_stall_ms" => STALL_MS
        },
        "status_ms" => summarize_runs(status_runs, "durations"),
        "status_feed_ms" => summarize_runs(feed_runs, "durations"),
        "activation_io" => {
          "status_load_dir_calls" => status_runs.sum { |run| run.fetch("loader_durations").length },
          "status_load_dir_ms" => stats(status_runs.flat_map { |run| run.fetch("loader_durations") }),
          "status_feed_load_dir_calls" => feed_runs.sum { |run| run.fetch("loader_durations").length },
          "status_feed_load_dir_ms" => stats(feed_runs.flat_map { |run| run.fetch("loader_durations") })
        },
        "monitor_wait" => {
          "project_b_elapsed_ms" => summarize_runs(monitor_runs, "durations"),
          "project_b_completed_while_a_stalled" => monitor_runs.sum do |run|
            run.fetch("completed_while_stalled")
          end,
          "samples" => RUNS * SAMPLES
        }
      )
    ensure
      Hive::Workflows::Project.reset!
      Hive::RuntimeControlPlane.disconnect
    end
  end

  def validate_dimensions!
    raise ArgumentError, "runs and samples must be positive" unless RUNS.positive? && SAMPLES.positive?
    raise ArgumentError, "at least two projects are required" unless PROJECTS >= 2
    raise ArgumentError, "tasks per project must be positive" unless TASKS_PER_PROJECT.positive?
    raise ArgumentError, "stall must be positive" unless STALL_MS.positive?
  end

  def install_loader_probe!
    singleton = Hive::Workflows::Loader.singleton_class
    singleton.prepend(LoaderProbe) unless singleton.ancestors.include?(LoaderProbe)
  end

  def install_registered_projects(projects)
    Hive::Config.define_singleton_method(:registered_projects) { projects }
  end

  def build_projects(root)
    PROJECTS.times.map do |project_index|
      project_root = File.join(root, "project-#{project_index}")
      hive_state = File.join(project_root, ".hive-state")
      workflow_id = "measurement-#{project_index}"
      workflows_dir = File.join(hive_state, "workflows")
      instruction_dir = File.join(workflows_dir, workflow_id)
      FileUtils.mkdir_p(instruction_dir)
      File.write(File.join(instruction_dir, "work.md"), "Produce the measured result.\n")
      File.write(
        File.join(workflows_dir, "#{workflow_id}.yml"),
        {
          "id" => workflow_id,
          "result" => { "kind" => "document", "primary_artifact" => "result.md" },
          "stages" => [
            { "name" => "inbox", "kind" => "terminal", "state_file" => "idea.md" },
            {
              "name" => "work", "kind" => "agent", "state_file" => "result.md",
              "instruction" => "./#{workflow_id}/work.md"
            },
            { "name" => "done", "kind" => "terminal", "state_file" => "result.md" }
          ]
        }.to_yaml
      )
      File.write(
        File.join(hive_state, "config.yml"),
        { "default_workflow" => workflow_id }.to_yaml
      )
      TASKS_PER_PROJECT.times do |task_index|
        slug = format("measurement-%d-%d-261014-%04x", project_index, task_index, task_index + 1)
        folder = File.join(hive_state, "stages", "2-work", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "result.md"), "<!-- WAITING -->\n")
        Hive::TaskMeta.write(
          folder, id: project_index * 100 + task_index + 1, slug: slug,
          display_name: "Measurement #{project_index}-#{task_index}", workflow: workflow_id
        )
      end
      {
        "name" => "measurement-#{project_index}",
        "path" => project_root,
        "hive_state_path" => hive_state
      }
    end
  end

  def warm(projects)
    Hive::Workflows::Project.reset!
    Hive::Commands::Status.new(json: true).json_payload(projects)
    Hive::Workflows::Project.reset!
    feed_for.snapshot_state
    Hive::Workflows::Project.reset!
  end

  def measure_runs
    RUNS.times.map { yield }
  end

  def measure_status(projects)
    LoaderProbe.reset!
    command = Hive::Commands::Status.new(json: true)
    durations = SAMPLES.times.map do
      Hive::Workflows::Project.reset!
      elapsed { command.json_payload(projects) }
    end
    { "durations" => durations, "loader_durations" => LoaderProbe.durations }
  end

  def measure_status_feed
    LoaderProbe.reset!
    durations = SAMPLES.times.map do
      Hive::Workflows::Project.reset!
      feed = feed_for
      elapsed { feed.snapshot_state }
    end
    { "durations" => durations, "loader_durations" => LoaderProbe.durations }
  end

  def feed_for
    command = Hive::Commands::Status.new(json: true)
    adapter = Class.new do
      include Hive::Web::StatusCommand

      define_method(:initialize) { |status| @status = status }
      define_method(:json_payload) { |projects| @status.json_payload(projects) }
    end
    Hive::Web::StatusFeed.new(status_command: adapter.new(command))
  end

  def measure_monitor_wait(projects)
    durations = []
    completed_while_stalled = 0
    SAMPLES.times do
      Hive::Workflows::Project.reset!
      entered = Queue.new
      release = Queue.new
      stalled_directory = File.join(projects.first.fetch("hive_state_path"), "workflows")
      LoaderProbe.stall!(stalled_directory, entered: entered, release: release)
      project_a = Thread.new { project_read(projects.first.fetch("path")) }
      entered.pop
      result = Queue.new
      project_b = Thread.new do
        result << elapsed { project_read(projects.last.fetch("path")) }
      end
      sleep(STALL_MS / 1_000.0)
      completed_while_stalled += 1 unless project_b.alive?
      release << true
      project_a.value
      project_b.value
      durations << result.pop
    ensure
      release << true if release&.empty?
      LoaderProbe.clear_stall!
      project_a&.kill if project_a&.alive?
      project_b&.kill if project_b&.alive?
    end
    { "durations" => durations, "completed_while_stalled" => completed_while_stalled }
  end

  def project_read(project_root)
    if Hive::Workflows::Project.respond_to?(:with_active_workflows)
      Hive::Workflows::Project.with_active_workflows(project_root) { |registry| registry.ids.length }
    else
      Hive::Workflows::Project.synchronize do
        Hive::Workflows::Project.load!(project_root)
        Hive::Workflows::Registry.ids.length
      end
    end
  end

  def elapsed
    started = monotonic
    yield
    (monotonic - started) * 1_000
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def summarize_runs(runs, key)
    values = runs.map { |run| run.fetch(key) }
    {
      "aggregate" => stats(values.flatten),
      "runs" => values.map { |run| stats(run) }
    }
  end

  def stats(values)
    sorted = values.sort
    return { "samples" => 0 } if sorted.empty?

    {
      "samples" => sorted.length,
      "min" => sorted.first.round(3),
      "p50" => percentile(sorted, 0.50).round(3),
      "p95" => percentile(sorted, 0.95).round(3),
      "max" => sorted.last.round(3),
      "mean" => (sorted.sum / sorted.length).round(3)
    }
  end

  def percentile(sorted, fraction)
    sorted.fetch(((sorted.length - 1) * fraction).ceil)
  end
end

ProjectWorkflowViewMeasurement.run
