# frozen_string_literal: true

# A separate installation daemon process, never owned by the HTTP request.
require "bundler/setup"
require "json"
require "hive"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/attempts/api"
require "hive/attempts/reconciler"

request_id = ARGV.fetch(0)
repository = Hive::RuntimeControlPlane::DispatchRepository.open_default
request = repository.fetch(request_id)
raise "missing persisted request" unless request&.state == "queued"
project = Hive::Config.find_project(request.project)
ENV["HIVE_CLAUDE_BIN"] = File.expand_path("fake-claude", __dir__)
ENV["HIVE_CODEX_BIN"] = ENV.fetch("HIVE_CLAUDE_BIN")
ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = File.join(ENV.fetch("HIVE_HOME"), "fake-agent-logs")
ENV["HIVE_FAKE_CLAUDE_DELAY_BEFORE_WRITE"] = "3"
ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(project.fetch("hive_state_path"), "stages", "3-plan", request.slug, "plan.md")
ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Plan\n<!-- WAITING -->\n"
logger = Object.new
events = []
logger.define_singleton_method(:event) { |name, **attributes| events << { "name" => name.to_s, "attributes" => attributes } }
store = Hive::Attempts::Repository.open_default
dispatcher = Hive::Daemon::Dispatcher.new(
  config: { "daemon" => { "edit_debounce_sec" => 0 } },
  controller: Hive::Daemon::ConcurrencyController.new(
    max_concurrent_runs: 1, max_concurrent_per_project: 1, max_runs_per_day_per_project: 100),
  supervisor: Hive::Daemon::ChildSupervisor.new(hive_bin: File.expand_path("../../bin/hive", __dir__)),
  status_consumer: Hive::Daemon::StatusConsumer.new,
  logger: logger, dispatch_repository: repository,
  attempt_dispatcher: Hive::Attempts::API.new(store: store),
  attempt_reconciler: Hive::Attempts::Reconciler.new(store: store),
  scope_projects: [ request.project ]
)
dispatcher.tick
row = repository.database.read { |db| db[:attempts][request_id: request_id] }
raise "daemon did not consume the persisted request: #{JSON.generate(events)}" unless row
attempt_id = row.fetch(:attempt_id)
$stdout.puts(JSON.generate("state" => "running", "request_id" => request_id, "attempt_id" => attempt_id))
$stdout.flush
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
loop do
  attempt = store.fetch(attempt_id)
  if attempt.final?
    # Complete the real daemon's durable receipt/result lifecycle without a
    # second scheduling tick launching unrelated workflow transitions.
    dispatcher.send(:write_attempt_dispatch_result, request, attempt, attempt.receipt, now: Time.now.utc)
    $stdout.puts(JSON.generate("state" => "finished", "outcome" => attempt.receipt.fetch("outcome"), "events" => events))
    $stdout.flush
    break
  end
  raise "detached attempt did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  sleep 0.05
end
