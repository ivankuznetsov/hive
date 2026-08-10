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

      state = configured_state(dir)
      dismissed = Hive::Patrol::Dismissals.new(
        dir, state: state, gh: gh
      ).reconcile(now: Time.utc(2026, 5, 28, 12))

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
                   "feature_id" => "command-bin-x",
                   "target_sha" => "a" * 40,
                   "title_tokens" => %w[implicit post mutations],
                   "root_cause_tokens" => %w[payload changes method] }
      })
      gh = FakeGh.new([ { "state" => "CLOSED", "url" => "https://example.com/pr/1" } ])

      state = configured_state(dir)
      dismissed = Hive::Patrol::Dismissals.new(
        dir, state: state, gh: gh
      ).reconcile(now: Time.utc(2026, 5, 28, 12))

      assert_equal "security", dismissed["fp1"]["category"]
      assert_equal "command-bin-x", dismissed["fp1"]["feature_id"]
      assert_equal "a" * 40, dismissed["fp1"]["target_sha"]
      assert_equal %w[implicit post mutations], dismissed["fp1"]["title_tokens"]
      assert_equal %w[payload changes method], dismissed["fp1"]["root_cause_tokens"]
    end
  end

  def test_merged_pr_marks_fingerprint_merged
    with_tmp_dir do |dir|
      write_json(File.join(dir, ".hive-state", "patrol", "fingerprints.json"), {
        "fp1" => { "branch" => "hive-patrol/x", "pr_url" => "https://example.com/pr/1", "state" => "open" }
      })
      gh = FakeGh.new([ { "state" => "MERGED", "url" => "https://example.com/pr/1" } ])

      state = configured_state(dir)
      Hive::Patrol::Dismissals.new(
        dir, state: state, gh: gh
      ).reconcile

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "merged", fingerprints["fp1"]["state"]
    end
  end

  def test_reconcile_updates_open_prs_and_ignores_gh_errors
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      state.send(:raw_write_fingerprints,
        "fp-open" => { "branch" => "b1", "pr_url" => "https://example.com/1" },
        "fp-error" => { "branch" => "b2", "pr_url" => "https://example.com/2" }
      )
      configure_state(state)
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

  def test_open_pr_does_not_erase_publication_retry_states
    %w[reconciliation_pending review_handoff_failed].each do |retry_state|
      with_tmp_dir do |dir|
        state = Hive::Patrol::StateStore.new(dir)
        state.send(:raw_write_fingerprints,
          "fp1" => {
            "branch" => "hive-patrol/x",
            "pr_url" => "https://example.com/pr/1",
            "state" => retry_state
          }
        )
        configure_state(state)
        gh = FakeGh.new([ { "state" => "OPEN", "url" => "https://example.com/pr/1" } ])

        Hive::Patrol::Dismissals.new(dir, state: state, gh: gh).reconcile

        assert_equal retry_state, state.fingerprints.fetch("fp1").fetch("state"),
                     "dismissal reconciliation must not suppress #{retry_state} recovery"
      end
    end
  end

  def test_publication_retry_does_not_reconcile_a_different_pr_on_the_branch
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      state.send(:raw_write_fingerprints,
        "fp1" => {
          "branch" => "hive-patrol/x",
          "pr_url" => "https://example.com/pr/expected",
          "state" => "reconciliation_pending"
        }
      )
      configure_state(state)
      gh = FakeGh.new([ { "state" => "CLOSED", "url" => "https://example.com/pr/other" } ])

      dismissed = Hive::Patrol::Dismissals.new(dir, state: state, gh: gh).reconcile

      assert_empty dismissed
      assert_equal "reconciliation_pending", state.fingerprints.fetch("fp1").fetch("state")
    end
  end

  def configured_state(root)
    configure_state(Hive::Patrol::StateStore.new(root))
  end

  def configure_state(state)
    capture = Struct.new(:occurrence_id).new("occ-#{"a" * 64}")
    gateway = Object.new
    gateway.define_singleton_method(:perform!) do |**_attributes, &effect|
      effect.call
    end
    state.instance_variable_set(:@effect_capture, capture)
    state.instance_variable_set(:@state_effect_gateway, gateway)
    state
  end
end
