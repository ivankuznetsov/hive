require "test_helper"
require "json"
require "shellwords"
require "hive/cli"
require "hive/commands/init"
require "hive/commands/new"
require "hive/daemon/child_supervisor"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatcher"
require "hive/daemon/status_consumer"

class ContentWorkflowE2ETest < Minitest::Test
  include HiveTestHelper

  TOPIC = "A practical guide to git worktrees for parallel development"

  def test_registered_content_workflow_advances_to_article_through_daemon
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        project = File.basename(project_root)
        capture_io { Hive::Commands::Init.new(project_root, workflow: "content").call }
        capture_io { Hive::Commands::New.new(project, TOPIC).call }

        slug = content_slug(project_root)
        ran = []
        with_deterministic_content_agent(record: ran) do
          supervisor = InlineSupervisor.new(
            run: ->(command) { capture_io { Hive::CLI.start(Shellwords.split(command).drop(1)) }; 0 }
          )
          logger = CollectingLogger.new
          dispatcher = Hive::Daemon::Dispatcher.new(
            config: { "daemon" => { "edit_debounce_sec" => 0, "poll_interval_sec" => 30 } },
            controller: Hive::Daemon::ConcurrencyController.new(
              max_concurrent_runs: 5,
              max_concurrent_per_project: 5,
              max_runs_per_day_per_project: 100
            ),
            supervisor: supervisor,
            status_consumer: LiveStatusConsumer.new(fetch: method(:status_snapshot)),
            logger: logger
          )

          30.times do
            break if File.file?(File.join(task_folder(project_root, "6-done", slug), "article.md"))

            now = Time.now
            supervisor.now = now
            dispatcher.tick(now: now)
          end

          # Rest proof (Decision 2 / R1): once article.md exists the terminal
          # `done` stage must REST — a further tick re-classifies it without
          # re-dispatching or error-looping. Without this the loop only proves
          # `done` does not *advance* (the break fires before the tick), never
          # that a regression making it re-dispatchable would be caught.
          ran_at_rest = ran.dup
          spawned_at_rest = supervisor.spawned.size
          now = Time.now
          supervisor.now = now
          dispatcher.tick(now: now)
          assert_equal ran_at_rest, ran,
                       "terminal done stage must not re-dispatch an agent after article.md exists"
          assert_equal spawned_at_rest, supervisor.spawned.size,
                       "terminal done stage must not spawn another command after article.md exists"

          @spawned_commands = supervisor.spawned.map { |spawn| spawn.fetch(:command) }
          @logged_event_names = logger.events.map { |entry| entry.fetch(:name) }
        end

        final = task_folder(project_root, "6-done", slug)
        assert File.directory?(final), "task should end in the content workflow terminal stage"
        assert_equal %w[research outline draft critique done], ran
        %w[idea.md research.md outline.md draft.md critique.md article.md].each do |artifact|
          path = File.join(final, artifact)
          assert File.file?(path), "#{artifact} should be carried into the final task folder"
          refute_empty File.read(path), "#{artifact} should be non-empty"
        end

        refute_includes @logged_event_names, :fatal,
                        "dispatcher must drive the content workflow to completion without a :fatal event"
        refute_includes @logged_event_names, :markerless_stalled,
                        "no content stage should stall markerless during a clean run"

        assert(@spawned_commands.any? { |command| command.start_with?("hive run") },
               "daemon must dispatch `hive run` through the supervisor")
        assert(@spawned_commands.any? { |command| command.start_with?("hive approve") },
               "daemon must dispatch `hive approve` through the supervisor")

        log_subjects = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s")
        approve_commits = log_subjects.lines.grep(/ approve /)
        assert_equal 5, approve_commits.size, "one approve commit should be recorded per stage transition"
        assert_includes log_subjects, "hive: 1-inbox/#{slug} approve 1-inbox -> 2-research"
        assert_includes log_subjects, "hive: 2-research/#{slug} approve 2-research -> 3-outline"
        assert_includes log_subjects, "hive: 3-outline/#{slug} approve 3-outline -> 4-draft"
        assert_includes log_subjects, "hive: 4-draft/#{slug} approve 4-draft -> 5-critique"
        assert_includes log_subjects, "hive: 5-critique/#{slug} approve 5-critique -> 6-done"
      end
    end
  end

  private

  class CollectingLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << { name: name, attrs: attrs }
    end

    def close; end
  end

  class LiveStatusConsumer
    def initialize(fetch:)
      @fetch = fetch
    end

    def fetch
      @fetch.call
    end
  end

  class InlineSupervisor
    ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

    attr_reader :spawned
    attr_accessor :now

    def initialize(run:)
      @run = run
      @spawned = []
      @pending = []
      @next_pid = 7000
      @now = Time.now
    end

    def spawn(command_string:, project:, slug:, stage:,
              hive_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
      pid = (@next_pid += 1)
      @spawned << { command: command_string, project: project, slug: slug, stage: stage }
      exit_code = @run.call(command_string)
      @pending << ChildExit.new(
        pid: pid,
        exit_code: exit_code,
        project: project,
        slug: slug,
        stage: stage,
        command: command_string,
        state_file_path: state_file_path,
        started_at: @now,
        finished_at: @now,
        json_envelope: nil
      )
      pid
    end

    def reap_all(now: Time.now)
      pending = @pending
      @pending = []
      pending
    end

    def reap_dry_run(now: Time.now)
      []
    end

    def terminate_all(grace_sec: 600); end
    def update_timeouts(**); end
    def enforce_timeouts(now:) = []
    def in_flight_count = @pending.size
  end

  def status_snapshot
    out, = capture_io { Hive::CLI.start([ "status", "--json" ]) }
    doc = JSON.parse(out)
    mapper = Hive::Daemon::StatusConsumer.new
    Hive::Daemon::StatusConsumer::Result.new(
      ok: true,
      rows: mapper.send(:extract_rows, doc),
      projects: mapper.send(:extract_projects, doc),
      error: nil
    )
  end

  def content_slug(project_root)
    matches = Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "*")]
    assert_equal 1, matches.size, "hive new should create exactly one content inbox task"
    File.basename(matches.first)
  end

  def task_folder(project_root, stage, slug)
    File.join(project_root, ".hive-state", "stages", stage, slug)
  end
end
