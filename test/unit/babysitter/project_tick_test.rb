require "test_helper"
require "json"
require "set"
require "hive/babysitter/project_tick"
require "hive/babysitter/logger"

class BabysitterProjectTickTest < Minitest::Test
  include HiveTestHelper

  def project_entry(dir)
    { "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state") }
  end

  def write_config(dir, babysitter:)
    FileUtils.mkdir_p(File.join(dir, ".hive-state"))
    File.write(File.join(dir, ".hive-state", "config.yml"), { "babysitter" => babysitter }.to_yaml)
  end

  def make_logger(dir)
    Hive::Babysitter::Logger.new(path: File.join(dir, ".hive-state", "babysitter", "log.jsonl"))
  end

  def test_filters_ignored_labels_and_limits_to_oldest_updated_prs
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(
        dir,
        babysitter: {
          "enabled" => true,
          "labels_ignore" => %w[wip do-not-merge draft],
          "max_concurrent_prs" => 2
        }
      )
      prs = [
        { "number" => 1, "labels" => [ { "name" => "wip" } ], "updatedAt" => "2026-05-26T12:00:00Z" },
        { "number" => 2, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" },
        { "number" => 3, "labels" => [], "updatedAt" => "2026-05-26T11:00:00Z" },
        { "number" => 4, "labels" => [], "updatedAt" => "2026-05-26T09:00:00Z" }
      ]
      called = []
      logger = make_logger(dir)

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, _project, _cfg, **_kwargs|
          called << pr["number"]
          :success
        }) do
          summary = Hive::Babysitter::ProjectTick.run(project, {}, dry_run: true, logger: logger, inflight: Set.new)
          assert_equal({ total: 2, fixed: 2, untouched: 0, needs_human: 0 }, summary)
        end
      end

      assert_equal [ 4, 2 ], called
      events = File.readlines(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")).map { |line| JSON.parse(line) }
      assert events.any? { |event| event["action"] == "skipped" && event["outcome"] == "label_ignored" && event["pr"] == 1 }
      assert File.exist?(File.join(project.fetch("hive_state_path"), "babysitter", "status.md"))
    ensure
      logger&.close
    end
  end

  def test_gh_error_emits_event_and_does_not_spawn_agent
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true })
      logger = make_logger(dir)
      spawned = false

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { raise Hive::GhError, "api down" }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, ->(*_args, **_kwargs) { spawned = true }) do
          summary = Hive::Babysitter::ProjectTick.run(project, {}, dry_run: false, logger: logger, inflight: Set.new)
          assert_equal({ total: 0, fixed: 0, untouched: 0, needs_human: 0 }, summary)
        end
      end

      refute spawned
      event = JSON.parse(File.read(File.join(project.fetch("hive_state_path"), "babysitter", "events.jsonl")))
      assert_equal "list-prs", event.fetch("action")
      assert_equal "gh-error", event.fetch("outcome")
    ensure
      logger&.close
    end
  end

  def test_inflight_prs_are_not_spawned
    with_tmp_dir do |dir|
      project = project_entry(dir)
      write_config(dir, babysitter: { "enabled" => true, "max_concurrent_prs" => 2 })
      logger = make_logger(dir)
      prs = [
        { "number" => 7, "labels" => [], "updatedAt" => "2026-05-26T10:00:00Z" }
      ]
      called = []
      inflight = Set.new([ [ "demo", 7 ] ])

      with_replaced_singleton_method(Hive::Gh, :list_open_prs, ->(_path, **_kwargs) { prs }) do
        with_replaced_singleton_method(Hive::Babysitter::PrFixer, :run, lambda { |pr, *_args, **_kwargs|
          called << pr["number"]
        }) do
          Hive::Babysitter::ProjectTick.run(project, {}, dry_run: false, logger: logger, inflight: inflight)
        end
      end

      assert_empty called
    ensure
      logger&.close
    end
  end
end
