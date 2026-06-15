require "test_helper"
require "stringio"
require "logger"
require "hive/digest/collector"

class HiveDigestCollectorTest < Minitest::Test
  include HiveTestHelper

  FakeShipTimes = Struct.new(:times) do
    def shipped_at(hive_state_path:, slug:)
      times.fetch([ hive_state_path, slug ], nil)
    end
  end

  RaisingShipTimes = Class.new do
    def shipped_at(hive_state_path:, slug:)
      raise Hive::GitError, "git log exploded for #{slug}"
    end
  end

  def test_groups_shipped_items_by_project_and_omits_empty_projects
    with_tmp_dir do |root|
      project_a = project(root, "alpha")
      project_b = project(root, "beta")
      inside = Time.utc(2026, 6, 13, 12)
      outside = Time.utc(2026, 6, 12, 12)

      create_done_task(project_a, "feature-260613-abcd", display_name: "Feature work", pr_number: 10)
      create_done_task(project_a, "old-260612-abcd", display_name: "Old work", pr_number: 11)
      create_done_task(project_b, "empty-260613-abcd", display_name: "Other work", pr_number: 12)

      ship_times = FakeShipTimes.new(
        {
          [ project_a.fetch("hive_state_path"), "feature-260613-abcd" ] => inside,
          [ project_a.fetch("hive_state_path"), "old-260612-abcd" ] => outside
        }
      )
      grouped = collector([ project_a, project_b ], ship_times).for_date(Date.new(2026, 6, 13))

      assert_equal [ "alpha" ], grouped.keys
      assert_equal [ "feature-260613-abcd" ], grouped.fetch("alpha").map(&:slug)
      assert_equal "Feature work", grouped.fetch("alpha").first.display_name
      assert_equal "https://example.test/pulls/10", grouped.fetch("alpha").first.pr_url
      # The boilerplate "## Summary" heading carries no signal, so pr_title
      # falls back to the display name instead of the literal "Summary".
      assert_equal "Feature work", grouped.fetch("alpha").first.pr_title
      assert_match(/full body/, grouped.fetch("alpha").first.pr_body)
    end
  end

  def test_git_error_drops_item_and_logs_the_slug
    with_tmp_dir do |root|
      entry = project(root, "alpha")
      create_done_task(entry, "boom-260613-abcd", display_name: "Boom", pr_number: 30)
      buf = StringIO.new

      grouped = collector([ entry ], RaisingShipTimes.new, logger: Logger.new(buf))
                .for_date(Date.new(2026, 6, 13))

      assert_empty grouped, "a git failure must drop the item, not crash the whole digest"
      assert_includes buf.string, "boom-260613-abcd"
    end
  end

  def test_pr_body_degraded_read_logs_and_returns_blank
    with_tmp_dir do |root|
      # File.read on a directory raises Errno::EISDIR (a SystemCallError).
      dir_as_file = File.join(root, "pr.md")
      FileUtils.mkdir_p(dir_as_file)
      buf = StringIO.new
      collector = collector([], FakeShipTimes.new({}), logger: Logger.new(buf))

      assert_equal "", collector.send(:pr_body, dir_as_file)
      assert_includes buf.string, "degraded pr.md read"
    end
  end

  def test_pr_title_extracts_heading_and_skips_summary_boilerplate
    collector = collector([], FakeShipTimes.new({}))

    assert_equal "Real heading", collector.send(:pr_title, "## Real heading\n\nbody", "fallback")
    assert_equal "Display name", collector.send(:pr_title, "## Summary\n\nbody", "Display name")
    assert_equal "Display name", collector.send(:pr_title, "no heading at all", "Display name")
  end

  def test_missing_meta_and_pr_file_degrade_to_blank_fields
    with_tmp_dir do |root|
      entry = project(root, "alpha")
      folder = File.join(entry.fetch("hive_state_path"), "stages", "9-done", "raw-260613-abcd")
      FileUtils.mkdir_p(folder)
      ship_times = FakeShipTimes.new(
        { [ entry.fetch("hive_state_path"), "raw-260613-abcd" ] => Time.utc(2026, 6, 13, 12) }
      )

      grouped = collector([ entry ], ship_times).for_date(Date.new(2026, 6, 13))
      item = grouped.fetch("alpha").first

      assert_equal "raw-260613-abcd", item.slug
      assert_equal "raw-260613-abcd", item.display_name
      assert_equal "", item.pr_url
      assert_equal "", item.pr_body
    end
  end

  def test_local_window_membership_uses_host_timezone
    with_env("TZ" => "America/New_York") do
      with_tmp_dir do |root|
        entry = project(root, "alpha")
        create_done_task(entry, "late-260613-abcd", display_name: "Late", pr_number: 13)
        ship_times = FakeShipTimes.new(
          { [ entry.fetch("hive_state_path"), "late-260613-abcd" ] => Time.utc(2026, 6, 14, 3, 59, 59) }
        )

        grouped = collector([ entry ], ship_times).for_date(Date.new(2026, 6, 13))

        assert_equal [ "late-260613-abcd" ], grouped.fetch("alpha").map(&:slug)
      end
    end
  end

  private

  def collector(entries, ship_times, logger: nil)
    Hive::Digest::Collector.new(registry: -> { entries }, ship_times: ship_times, logger: logger)
  end

  def project(root, name)
    path = File.join(root, name)
    hive_state_path = File.join(path, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state_path, "stages", "9-done"))
    { "name" => name, "path" => path, "hive_state_path" => hive_state_path }
  end

  def create_done_task(entry, slug, display_name:, pr_number:)
    folder = File.join(entry.fetch("hive_state_path"), "stages", "9-done", slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: pr_number, slug: slug, display_name: display_name)
    File.write(File.join(folder, "pr.md"), <<~MD)
      ---
      pr_url: https://example.test/pulls/#{pr_number}
      pr_number: #{pr_number}
      ---

      ## Summary

      This is the full body for #{slug}.
    MD
  end
end
