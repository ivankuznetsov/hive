require "test_helper"
require "hive/config"

class DailyDigestMembershipHistoryTest < Minitest::Test
  include HiveTestHelper

  def test_register_replace_unregister_and_prune_share_the_registry_write
    with_tmp_global_config do |home|
      first = File.join(home, "first").tap { |path| FileUtils.mkdir_p(path) }
      second = File.join(home, "second").tap { |path| FileUtils.mkdir_p(path) }
      stale = File.join(home, "stale").tap { |path| FileUtils.mkdir_p(path) }

      registered = Hive::Config.register_project(
        name: "demo", path: first, now: Time.iso8601("2026-08-30T08:00:00Z")
      )
      replaced = Hive::Config.register_project(
        name: "demo", path: second, now: Time.iso8601("2026-08-30T09:00:00Z")
      )
      Hive::Config.register_project(
        name: "stale", path: stale, now: Time.iso8601("2026-08-30T10:00:00Z")
      )
      FileUtils.remove_entry(stale)
      Hive::Config.prune_missing_projects!(now: Time.iso8601("2026-08-30T11:00:00Z"))
      Hive::Config.unregister_project(
        name: "demo", now: Time.iso8601("2026-08-30T12:00:00Z")
      )

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      history = data.fetch("project_membership_history")
      assert_equal %w[registered replaced registered pruned unregistered],
                   history.map { |event| event.fetch("kind") }
      assert_equal registered.fetch("project_id"), replaced.fetch("project_id")
      assert_equal registered.fetch("registration_id"), replaced.fetch("registration_id")
      assert_equal first, history[1].dig("before", "path")
      assert_equal second, history[1].dig("after", "path")
      assert_empty data.fetch("registered_projects")
      assert history.all? { |event| event.fetch("event_id").match?(/\A[0-9a-f]{64}\z/) }
    end
  end

  def test_prune_dry_run_does_not_append_membership_history
    with_tmp_global_config do |home|
      stale = File.join(home, "stale").tap { |path| FileUtils.mkdir_p(path) }
      Hive::Config.register_project(name: "stale", path: stale)
      FileUtils.remove_entry(stale)
      before = File.binread(File.join(home, "config.yml"))

      Hive::Config.prune_missing_projects!(dry_run: true)

      assert_equal before, File.binread(File.join(home, "config.yml"))
    end
  end
end
