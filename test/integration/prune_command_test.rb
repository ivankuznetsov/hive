require "test_helper"
require "json"
require "hive/commands/prune"

# End-to-end coverage for `hive prune`. Drives the command class
# directly. Asserts:
#   * registry rewrite drops only entries whose path is gone,
#   * `--dry-run` returns the would-be-removed list without writing,
#   * `--json` envelope shape matches schemas/hive-prune.v1.json.
class PruneCommandTest < Minitest::Test
  include HiveTestHelper

  def test_prune_removes_only_entries_whose_path_is_gone
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")

        out, _err = capture_io { Hive::Commands::Prune.new.call }
        assert_match(/removed 1, kept 1/, out)
        assert_match(/dead/, out)

        kept = Hive::Config.registered_projects.map { |p| p["name"] }
        assert_equal [ "live" ], kept
      end
    end
  end

  def test_prune_dry_run_does_not_rewrite_registry
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")
        before = File.read(File.join(home, "config.yml"))

        out, _err = capture_io { Hive::Commands::Prune.new(dry_run: true).call }
        assert_match(/would remove 1, kept 1/, out)
        assert_match(/dry-run/, out)

        after = File.read(File.join(home, "config.yml"))
        assert_equal before, after, "dry-run must not rewrite config.yml"
        assert_equal 2, Hive::Config.registered_projects.size
      end
    end
  end

  def test_prune_no_stale_entries
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        out, _err = capture_io { Hive::Commands::Prune.new.call }
        assert_match(/no stale entries/, out)
      end
    end
  end

  def test_prune_json_envelope_shape
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")

        out, _err = capture_io { Hive::Commands::Prune.new(json: true).call }
        payload = JSON.parse(out)

        assert_equal "hive-prune", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal true, payload["ok"]
        assert_equal false, payload["dry_run"]
        assert_equal 1, payload["removed_count"]
        assert_equal 1, payload["kept_count"]
        assert_equal 1, payload["removed"].size
        assert_equal "dead", payload["removed"].first["name"]
      end
    end
  end

  def test_prune_dry_run_json_payload_marks_dry_run_true
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        Hive::Config.register_project(name: "dead", path: "/tmp/hive-prune-#{rand(1_000_000)}-gone")

        out, _err = capture_io { Hive::Commands::Prune.new(dry_run: true, json: true).call }
        payload = JSON.parse(out)

        assert_equal true, payload["dry_run"]
        assert_equal 1, payload["removed_count"]
        assert_equal 2, Hive::Config.registered_projects.size,
                     "dry-run JSON path must still leave the registry untouched"
      end
    end
  end
end
