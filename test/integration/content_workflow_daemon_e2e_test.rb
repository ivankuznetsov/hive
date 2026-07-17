require "test_helper"
require "json"
require "shellwords"
require "hive/cli"
require "hive/attempts/context"
require "hive/commands/init"
require "hive/commands/new"
require "hive/daemon/child_supervisor"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatcher"
require "hive/daemon/status_consumer"

class ContentWorkflowDaemonE2ETest < Minitest::Test
  include HiveTestHelper

  def test_content_fixture_advances_from_init_new_to_terminal_stage
    descriptor = content_workflow

    with_registered_workflow(descriptor) do
      with_tmp_global_config do
        with_tmp_git_repo do |project_root|
          project = File.basename(project_root)
          capture_io { Hive::Commands::Init.new(project_root, workflow: "content_fixture").call }
          capture_io { Hive::Commands::New.new(project, "draft launch post").call }

          slug = File.basename(Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "draft-launch-post-*")].first)
          ran = []
          with_deterministic_content_agent(record: ran) do
            with_attempt_context(
              attempt_id: "content-fixture-test-attempt",
              task_generation: "content-fixture-test-generation"
            ) do
              supervisor = InlineSupervisor.new(
                run: ->(command) { capture_io { Hive::CLI.start(Shellwords.split(command).drop(1)) }; 0 }
              )
              dispatcher = Hive::Daemon::Dispatcher.new(
                config: { "daemon" => { "edit_debounce_sec" => 0, "poll_interval_sec" => 30 } },
                controller: Hive::Daemon::ConcurrencyController.new(
                  max_concurrent_runs: 5,
                  max_concurrent_per_project: 5,
                  max_runs_per_day_per_project: 100
                ),
                supervisor: supervisor,
                status_consumer: LiveStatusConsumer.new(
                  fetch: lambda do
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
                ),
                logger: CollectingLogger.new
              )

              24.times do
                break if File.file?(File.join(task_folder(project_root, "4-done", slug), "done.md"))

                now = Time.now
                supervisor.now = now
                dispatcher.tick(now: now)
              end

              @spawned_commands = supervisor.spawned.map { |s| s[:command] }
            end
          end

          final = task_folder(project_root, "4-done", slug)
          assert File.directory?(final), "task should end in the content fixture terminal stage"
          assert_equal %w[research draft done], ran
          %w[idea.md research.md draft.md done.md].each do |artifact|
            assert File.file?(File.join(final, artifact)), "#{artifact} should be carried into the final task folder"
          end

          # Defense-in-depth parity with the generic sibling: assert the daemon —
          # not a direct CLI call — drove both the run and the advancing approve
          # through the supervisor's spawn.
          assert(@spawned_commands.any? { |c| c.start_with?("hive run") },
                 "daemon must have dispatched at least one `hive run` through the supervisor")
          assert(@spawned_commands.any? { |c| c.start_with?("hive approve") },
                 "daemon must have dispatched the advancing `hive approve` through the supervisor")

          log_subjects = run!("git", "-C", File.join(project_root, ".hive-state"), "log", "--format=%s")
          approve_commits = log_subjects.lines.grep(/ approve /)
          assert_equal 3, approve_commits.size, "one approve commit should be recorded per stage transition"
          assert_includes log_subjects, "hive: 1-inbox/#{slug} approve 1-inbox -> 2-research"
          assert_includes log_subjects, "hive: 2-research/#{slug} approve 2-research -> 3-draft"
          assert_includes log_subjects, "hive: 3-draft/#{slug} approve 3-draft -> 4-done"
        end
      end
    end
  end

  private

  class CollectingLogger
    def event(_name, **_attrs); end
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
      @next_pid = 6000
      @now = Time.now
    end

    def spawn(command_string:, project:, slug:, stage:,
              log_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
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

  def task_folder(project_root, stage, slug)
    File.join(project_root, ".hive-state", "stages", stage, slug)
  end
end
