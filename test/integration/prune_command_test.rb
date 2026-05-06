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

  # P1 #4 + #5: a malformed config used to leak as InternalError(70).
  # Now: ConfigError → exit 78 with `error_kind: "config"`.
  def test_prune_malformed_yaml_emits_config_error
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "registered_projects: [\nthis: is: not: yaml")

      out, _err, status = with_captured_exit do
        Hive::Commands::Prune.new(json: true).call
      end
      assert_equal Hive::ExitCodes::CONFIG, status

      payload = JSON.parse(out)
      assert_equal "config", payload["error_kind"]
      assert_equal "ConfigError", payload["error_class"]
    end
  end

  # NEW-1: typoed $HIVE_HOME must surface as CONFIG, not silently no-op.
  def test_prune_with_typoed_hive_home_emits_config_error
    bad = "/tmp/hive-typo-#{Process.pid}-#{rand(1_000_000)}"
    prev = ENV["HIVE_HOME"]
    ENV["HIVE_HOME"] = bad

    out, _err, status = with_captured_exit do
      Hive::Commands::Prune.new(json: true).call
    end
    assert_equal Hive::ExitCodes::CONFIG, status

    payload = JSON.parse(out)
    assert_equal "config", payload["error_kind"]
  ensure
    ENV["HIVE_HOME"] = prev
  end

  # P1 #5: hand-edited malformed registry rows must be reported as
  # droppable instead of bricking the loader. They show up in `removed`
  # alongside missing-path entries.
  def test_prune_drops_malformed_registry_rows
    with_tmp_global_config do |home|
      Dir.mktmpdir("hive-live") do |live_dir|
        File.write(
          File.join(home, "config.yml"),
          {
            "registered_projects" => [
              { "name" => "live", "path" => live_dir, "hive_state_path" => File.join(live_dir, ".hive-state") },
              "garbage-non-hash-row",
              { "name" => "missing-path-key" }
            ]
          }.to_yaml
        )

        out, _err = capture_io { Hive::Commands::Prune.new(json: true).call }
        payload = JSON.parse(out)
        assert_equal true, payload["ok"]
        assert_equal 2, payload["removed_count"],
                     "both malformed rows must be dropped"
        assert_equal 1, payload["kept_count"]
      end
    end
  end

  # `prune --dry-run` on an empty / clean registry must say so AND
  # surface that the dry-run flag was honoured (P3 #27 fix).
  def test_prune_dry_run_with_no_stale_entries_says_dry_run
    with_tmp_global_config do
      Dir.mktmpdir("hive-live-project") do |live_dir|
        Hive::Config.register_project(name: "live", path: live_dir)
        out, _err = capture_io { Hive::Commands::Prune.new(dry_run: true).call }
        assert_match(/no stale entries/, out)
        assert_match(/dry-run/, out, "dry-run flag must be visible even when nothing changes")
      end
    end
  end

  # PR-review P1 #2: a non-Hash registry row (e.g. `- 42`) used to be
  # rewritten out of the registry by `prune_missing_projects!` and THEN
  # crash `entry_payload` on `42["path"]` (TypeError), emitting an
  # `error_kind: "internal"` envelope at exit 70. The two surfaces were
  # silently disagreeing about row shape — drop succeeded, JSON contract
  # was violated. `entry_payload` now returns `name=entry.to_s, path=""`
  # for non-Hash entries so the success envelope reaches stdout.
  def test_prune_drops_integer_row_and_emits_success_envelope
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), "registered_projects:\n  - 42\n")

      out, _err = capture_io { Hive::Commands::Prune.new(json: true).call }
      payload = JSON.parse(out)
      assert_equal true, payload["ok"], "non-Hash row must not crash the success path"
      assert_equal 1, payload["removed_count"]
      removed = payload["removed"].first
      assert_equal "42", removed["name"], "operator must see what was dropped"
      assert_equal "", removed["path"]
      assert_equal "", removed["hive_state_path"]
      assert_equal [], YAML.safe_load(File.read(File.join(home, "config.yml")))["registered_projects"]
    end
  end

  # PR-review P1 #3: a hand-edited row carrying `~/project` must be
  # treated as live when `~` expands to a real directory. Without
  # `File.expand_path`, `File.directory?("~/project")` returns false
  # and the row was reported as droppable.
  def test_prune_keeps_tilde_path_pointing_at_existing_directory
    Dir.mktmpdir("hive-tilde-home") do |fake_home|
      live = File.join(fake_home, "live-project")
      Dir.mkdir(live)
      prev_home = ENV["HOME"]
      ENV["HOME"] = fake_home
      with_tmp_global_config do |home|
        File.write(
          File.join(home, "config.yml"),
          { "registered_projects" => [ { "name" => "live", "path" => "~/live-project" } ] }.to_yaml
        )

        result = Hive::Config.prune_missing_projects!(dry_run: true)
        assert_empty result.fetch(:removed),
                     "~/live-project resolves to an existing directory; must not be droppable"
      end
    ensure
      ENV["HOME"] = prev_home
    end
  end

  # PR-review P2 #5: `Psych::DisallowedClass` (e.g. `!ruby/object:Object`)
  # and `Psych::AliasesNotEnabled` (anchor + alias) must be classified as
  # config errors, not internal crashes — same treatment as
  # `Psych::SyntaxError`.
  def test_prune_disallowed_class_yaml_emits_config_error
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"),
                 "registered_projects:\n  - name: foo\n    path: !ruby/object:Object {}\n")

      out, _err, status = with_captured_exit do
        Hive::Commands::Prune.new(json: true).call
      end
      assert_equal Hive::ExitCodes::CONFIG, status,
                   "Psych::DisallowedClass must exit 78 (CONFIG), not 70 (SOFTWARE)"
      payload = JSON.parse(out)
      assert_equal "config", payload["error_kind"]
      assert_equal "ConfigError", payload["error_class"]
    end
  end

  def test_prune_aliases_not_enabled_yaml_emits_config_error
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), <<~YAML)
        defaults: &d
          name: foo
          path: /tmp
        registered_projects:
          - *d
      YAML

      out, _err, status = with_captured_exit do
        Hive::Commands::Prune.new(json: true).call
      end
      assert_equal Hive::ExitCodes::CONFIG, status,
                   "Psych::AliasesNotEnabled must exit 78 (CONFIG), not 70 (SOFTWARE)"
      payload = JSON.parse(out)
      assert_equal "config", payload["error_kind"]
    end
  end

  # P3 #25: schema describes `path` / `hive_state_path` as absolute. A
  # hand-edited row carrying `~/foo` or `./foo` must be normalized in
  # the prune success-payload `removed[]` array.
  def test_prune_success_payload_normalizes_relative_paths_in_removed_entries
    with_tmp_global_config do |home|
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            { "name" => "rel-gone", "path" => "relative/that/does/not/exist", "hive_state_path" => "relative/that/does/not/exist/.hive-state" }
          ]
        }.to_yaml
      )

      out, _err = capture_io { Hive::Commands::Prune.new(json: true).call }
      payload = JSON.parse(out)
      removed = payload["removed"]
      assert_equal 1, removed.size
      assert removed.first["path"].start_with?("/"),
             "schema says 'Absolute path' — relative input must be normalized in prune output"
      assert removed.first["hive_state_path"].start_with?("/"),
             "hive_state_path must also be absolute"
    end
  end
end
