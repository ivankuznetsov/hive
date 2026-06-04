require "test_helper"
require "json"
require "hive/patrol/dismissals"

class HivePatrolDismissalsTest < Minitest::Test
  include HiveTestHelper

  class FakeGh
    attr_accessor :prs

    def initialize(prs)
      @prs = prs
    end

    def lookup_prs_for_branch(_project_root, _branch)
      @prs
    end
  end

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  end

  def test_closed_unmerged_pr_is_recorded_as_dismissed
    with_tmp_dir do |dir|
      write_json(File.join(dir, ".hive-state", "patrol", "fingerprints.json"), {
        "fp1" => { "branch" => "hive-patrol/x", "pr_url" => "https://example.com/pr/1", "state" => "open" }
      })
      gh = FakeGh.new([ { "state" => "CLOSED", "url" => "https://example.com/pr/1" } ])

      dismissed = Hive::Patrol::Dismissals.new(dir, gh: gh).reconcile(now: Time.utc(2026, 5, 28, 12))

      assert_equal "https://example.com/pr/1", dismissed["fp1"]["pr_url"]
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "dismissed", fingerprints["fp1"]["state"]
    end
  end

  # The dismissed entry must carry the finding content forward so the
  # similarity gate can still recognise a re-worded re-file of it.
  def test_closed_pr_carries_content_into_dismissed_entry
    with_tmp_dir do |dir|
      write_json(File.join(dir, ".hive-state", "patrol", "fingerprints.json"), {
        "fp1" => { "branch" => "hive-patrol/x", "pr_url" => "https://example.com/pr/1",
                   "state" => "open", "category" => "security",
                   "title_tokens" => %w[implicit post mutations] }
      })
      gh = FakeGh.new([ { "state" => "CLOSED", "url" => "https://example.com/pr/1" } ])

      dismissed = Hive::Patrol::Dismissals.new(dir, gh: gh).reconcile(now: Time.utc(2026, 5, 28, 12))

      assert_equal "security", dismissed["fp1"]["category"]
      assert_equal %w[implicit post mutations], dismissed["fp1"]["title_tokens"]
    end
  end

  def test_merged_pr_marks_fingerprint_merged
    with_tmp_dir do |dir|
      write_json(File.join(dir, ".hive-state", "patrol", "fingerprints.json"), {
        "fp1" => { "branch" => "hive-patrol/x", "pr_url" => "https://example.com/pr/1", "state" => "open" }
      })
      gh = FakeGh.new([ { "state" => "MERGED", "url" => "https://example.com/pr/1" } ])

      Hive::Patrol::Dismissals.new(dir, gh: gh).reconcile

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "merged", fingerprints["fp1"]["state"]
    end
  end

  def test_reconcile_updates_open_prs_and_ignores_gh_errors
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      state.write_fingerprints(
        "fp-open" => { "branch" => "b1", "pr_url" => "https://example.com/1" },
        "fp-error" => { "branch" => "b2", "pr_url" => "https://example.com/2" }
      )
      gh = Object.new
      gh.define_singleton_method(:lookup_prs_for_branch) do |_root, branch|
        raise Hive::GhError, "gh down" if branch == "b2"

        [ { "state" => "OPEN", "url" => "https://example.com/1" } ]
      end

      Hive::Patrol::Dismissals.new(dir, state: state, gh: gh).reconcile

      fingerprints = state.fingerprints
      assert_equal "open", fingerprints["fp-open"]["state"]
      refute fingerprints["fp-error"].key?("state")
    end
  end
end
