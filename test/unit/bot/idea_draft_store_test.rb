require "test_helper"
require "hive/bot/idea_draft_store"

class HiveBotIdeaDraftStoreTest < Minitest::Test
  include HiveTestHelper

  def setup
    @now = Time.utc(2026, 6, 3, 12, 0, 0)
    @store = Hive::Bot::IdeaDraftStore.new(ttl_sec: 900, now: -> { @now })
  end

  def test_start_and_get_round_trip
    draft = @store.start(chat_id: 1, phase: :awaiting_text, text: nil, token: "tok", origin: :voice)

    assert_equal draft, @store.get(chat_id: 1)
    assert_equal :awaiting_text, draft.phase
    assert_equal "tok", draft.token
    assert_equal :voice, draft.origin
    assert_equal [], draft.attachments
  end

  def test_start_rejects_unknown_phase
    assert_raises(ArgumentError, "an unknown phase must be rejected at start") do
      @store.start(chat_id: 1, phase: :bogus_phase)
    end
  end

  def test_start_rejects_unknown_origin
    assert_raises(ArgumentError, "an unknown origin must be rejected at start") do
      @store.start(chat_id: 1, phase: :awaiting_text, origin: :sms)
    end
  end

  def test_start_rejects_transcript_confirm_phase_with_non_voice_origin
    assert_raises(ArgumentError,
                  ":awaiting_transcript_confirm must require origin :voice") do
      @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, origin: nil)
    end
  end

  def test_set_transcript_and_confirm_transcript
    @store.start(chat_id: 1, phase: :awaiting_text, token: "tok", origin: :voice)

    @store.set_transcript(chat_id: 1, text: "capture this")
    draft = @store.get(chat_id: 1)

    assert_equal "capture this", draft.text
    assert_equal :awaiting_transcript_confirm, draft.phase

    @store.confirm_transcript(chat_id: 1)
    assert_equal :awaiting_project, @store.get(chat_id: 1).phase
    assert_equal :voice, @store.get(chat_id: 1).origin
  end

  def test_await_text_clears_text_and_moves_phase
    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm,
                 text: "transcript", token: "tok", origin: :voice)

    @store.await_text(chat_id: 1)
    draft = @store.get(chat_id: 1)

    assert_nil draft.text
    assert_equal :awaiting_text, draft.phase
    assert_equal :voice, draft.origin
  end

  def test_set_text_and_project_advance_phase
    @store.start(chat_id: 1, phase: :awaiting_text, token: "tok")

    @store.set_text(chat_id: 1, text: "fix login")
    @store.set_project(chat_id: 1, project: "hive")
    @store.enter_collecting(chat_id: 1)
    draft = @store.get(chat_id: 1)

    assert_equal "fix login", draft.text
    assert_equal "hive", draft.project
    assert_equal :collecting_files, draft.phase
  end

  def test_append_attachments_keeps_monotonic_counter
    @store.start(chat_id: 1, phase: :collecting_files, token: "tok")

    @store.append_attachment(chat_id: 1, label: "image1", dest_name: "bug-1.jpg",
                             staging_path: "/tmp/one", ext: "jpg")
    @store.append_attachment(chat_id: 1, label: "image2", dest_name: "bug-2.pdf",
                             staging_path: "/tmp/two", ext: "pdf")
    draft = @store.get(chat_id: 1)

    assert_equal 2, draft.counter
    assert_equal %w[image1 image2], draft.attachments.map { |a| a.fetch(:label) }
    assert_equal 3, @store.next_attachment_number(chat_id: 1)
  end

  def test_ttl_prune_removes_stale_draft
    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, text: "fix", token: "tok", origin: :voice)

    @now += 901
    @store.prune!

    assert_nil @store.get(chat_id: 1)
  end

  def test_second_start_replaces_first_and_cleans_staging_dir
    with_tmp_dir do
      @store.start(chat_id: 1, phase: :collecting_files, text: "old", token: "old")
      dir = @store.ensure_staging_dir(chat_id: 1)
      File.write(File.join(dir, "file.txt"), "bytes")
      assert_path_exists dir

      @store.start(chat_id: 1, phase: :awaiting_text, token: "new")

      refute_path_exists dir
      assert_equal "new", @store.get(chat_id: 1).token
    end
  end

  def test_find_by_token_ignores_expired_drafts
    @store.start(chat_id: 1, phase: :awaiting_project, text: "fix", token: "tok")

    assert_equal 1, @store.find_by_token("tok").chat_id
    @now += 901

    assert_nil @store.find_by_token("tok")
  end

  def test_get_clears_expired_draft_and_staging_dir
    with_tmp_dir do
      @store.start(chat_id: 1, phase: :collecting_files, text: "fix", token: "tok")
      dir = @store.ensure_staging_dir(chat_id: 1)
      File.write(File.join(dir, "file.txt"), "bytes")

      @now += 901

      assert_nil @store.get(chat_id: 1)
      refute_path_exists dir
    end
  end

  def test_clear_swallows_staging_cleanup_failure
    @store.start(chat_id: 1, phase: :collecting_files, text: "fix", token: "tok")
    @store.ensure_staging_dir(chat_id: 1)

    with_replaced_singleton_method(Hive::Tui::ComposerStaging, :cleanup!, ->(*_args, **_kwargs) { raise IOError, "blocked" }) do
      draft = @store.clear(chat_id: 1)

      refute_nil draft
      assert_nil @store.get(chat_id: 1)
    end
  end

  # ---- State-decision API regression (encapsulated phase/origin decisions) ----

  def test_awaiting_transcript_confirmation_is_true_only_for_voice_confirm_phase
    @store.start(chat_id: 1, phase: :awaiting_text, token: "tok")
    refute @store.awaiting_transcript_confirmation?(chat_id: 1),
           "a plain typed draft must not route to the voice confirm flow"

    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, token: "tok", origin: :voice)
    assert @store.awaiting_transcript_confirmation?(chat_id: 1)

    @now += 901
    refute @store.awaiting_transcript_confirmation?(chat_id: 1),
           "an expired draft must not route to the voice confirm flow"
  end

  def test_voice_and_non_voice_draft_predicates_split_on_origin
    @store.start(chat_id: 1, phase: :awaiting_text, token: "tok")
    assert @store.non_voice_draft?(chat_id: 1)
    refute @store.voice_draft?(chat_id: 1)

    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, token: "tok2", origin: :voice)
    assert @store.voice_draft?(chat_id: 1)
    refute @store.non_voice_draft?(chat_id: 1)

    @now += 901
    refute @store.voice_draft?(chat_id: 1), "expired drafts must count as absent"
    refute @store.non_voice_draft?(chat_id: 1)
  end

  def test_awaiting_text_draft_is_true_only_in_awaiting_text_phase
    @store.start(chat_id: 1, phase: :awaiting_text, token: "tok")
    assert @store.awaiting_text_draft?(chat_id: 1)

    @store.set_text(chat_id: 1, text: "fix login")
    refute @store.awaiting_text_draft?(chat_id: 1)
  end

  def test_transcript_only_voice_draft_requires_voice_origin_and_no_audio
    @store.start(chat_id: 1, phase: :awaiting_project, text: "idea", token: "tok")
    refute @store.transcript_only_voice_draft?(token: "tok"),
           "a typed draft must enter file collection, not commit immediately"

    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, token: "tok2", origin: :voice)
    @store.confirm_transcript(chat_id: 1)
    assert @store.transcript_only_voice_draft?(token: "tok2")

    @store.append_attachment(chat_id: 1, label: "voice-1", dest_name: "voice-1.oga",
                             staging_path: "/tmp/voice-1.oga", ext: "oga")
    refute @store.transcript_only_voice_draft?(token: "tok2"),
           "staged fallback audio must divert the draft into file collection"
  end

  def test_ensure_voice_draft_reuses_only_voice_and_never_clobbers_non_voice
    @store.start(chat_id: 1, phase: :awaiting_project, text: "typed idea", token: "tok")
    assert_nil @store.ensure_voice_draft(chat_id: 1, token: "vtok"),
               "a non-voice draft must not be reused or replaced by a voice note"
    assert_equal "tok", @store.get(chat_id: 1).token

    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, token: "tok2", origin: :voice)
    reused = @store.ensure_voice_draft(chat_id: 1, token: "tok3")
    assert_equal "tok2", reused.token, "a live voice draft must be reused"

    @store.clear(chat_id: 1)
    fresh = @store.ensure_voice_draft(chat_id: 1, token: "tok4")
    assert_equal "tok4", @store.get(chat_id: 1).token
    assert_equal :awaiting_transcript_confirm, fresh.phase
    assert_equal :voice, fresh.origin
  end

  def test_clear_voice_draft_leaves_non_voice_drafts_alone
    @store.start(chat_id: 1, phase: :collecting_files, text: "typed", token: "tok")
    @store.clear_voice_draft(chat_id: 1)
    refute_nil @store.get(chat_id: 1), "a text/media draft must survive a rejected voice note"

    @store.start(chat_id: 1, phase: :awaiting_transcript_confirm, token: "tok2", origin: :voice)
    @store.clear_voice_draft(chat_id: 1)
    assert_nil @store.get(chat_id: 1)
  end

  def test_commit_blocker_reports_each_missing_requirement
    assert_equal :draft_expired, @store.commit_blocker(chat_id: 1)

    @store.start(chat_id: 1, phase: :awaiting_project, text: "idea", token: "tok")
    assert_equal :project_missing, @store.commit_blocker(chat_id: 1)

    @store.set_project(chat_id: 1, project: "hive")
    assert_nil @store.commit_blocker(chat_id: 1)

    @store.start(chat_id: 2, phase: :awaiting_project, text: "   ", token: "tok2")
    @store.set_project(chat_id: 2, project: "hive")
    assert_equal :text_missing, @store.commit_blocker(chat_id: 2),
                 "whitespace-only text must block commit"
  end

  def test_commit_snapshot_returns_frozen_view_independent_of_live_draft
    @store.start(chat_id: 1, phase: :awaiting_project, text: "idea", token: "tok")
    @store.set_project(chat_id: 1, project: "hive")
    @store.append_attachment(chat_id: 1, label: "bug-1", dest_name: "bug-1.jpg",
                             staging_path: "/tmp/bug-1.jpg", ext: "jpg")

    snapshot = @store.commit_snapshot(chat_id: 1)
    assert_equal "hive", snapshot.project
    assert_equal "idea", snapshot.text
    assert_equal [ { staging_path: "/tmp/bug-1.jpg", dest_name: "bug-1.jpg", ext: "jpg" } ], snapshot.attachments

    # The snapshot is a frozen execution view: mutating the live draft (or the
    # snapshot) afterwards must not change what was already handed to commit.
    @store.append_attachment(chat_id: 1, label: "bug-2", dest_name: "bug-2.pdf",
                             staging_path: "/tmp/bug-2.pdf", ext: "pdf")
    assert_equal 1, snapshot.attachments.size

    assert_raises(FrozenError) { snapshot.attachments << {} }
    assert_raises(FrozenError) { snapshot.project = "other" }

    assert_nil @store.commit_snapshot(chat_id: 999), "no draft means no snapshot"
  end

  def test_commit_snapshot_string_leaves_survive_live_draft_mutation
    @store.start(chat_id: 1, phase: :awaiting_project, text: "idea", token: "tok", origin: :voice)
    @store.set_project(chat_id: 1, project: "hive")
    @store.append_attachment(chat_id: 1, label: "bug-1", dest_name: "bug-1.jpg",
                             staging_path: "/tmp/bug-1.jpg", ext: "jpg")

    snapshot = @store.commit_snapshot(chat_id: 1)

    # Frozen containers alone are not an independent view: freeze does not
    # deep-freeze, so the String leaves must each be duplicated and frozen,
    # or in-place edits on the live draft rewrite what execution received.
    draft = @store.get(chat_id: 1)
    draft.text << "-mutated"
    draft.project.replace("hive-mutated")
    attachment = draft.attachments.first
    attachment[:staging_path] << "-moved"
    attachment[:dest_name].replace("evil.jpg")

    assert_equal "idea", snapshot.text, "snapshot text must not alias the live draft's text"
    assert snapshot.text.frozen?
    assert_equal "hive", snapshot.project, "snapshot project must not alias the live draft's project"
    assert snapshot.project.frozen?
    attachment_view = snapshot.attachments.first
    assert_equal "/tmp/bug-1.jpg", attachment_view[:staging_path]
    assert attachment_view[:staging_path].frozen?
    assert_equal "bug-1.jpg", attachment_view[:dest_name]
    assert attachment_view[:dest_name].frozen?
    assert_equal "jpg", attachment_view[:ext]
    assert attachment_view[:ext].frozen?
  end

  def test_commit_snapshot_passes_nil_text_and_project_through
    @store.start(chat_id: 1, phase: :awaiting_text, token: "tok")

    snapshot = @store.commit_snapshot(chat_id: 1)

    assert_nil snapshot.text
    assert_nil snapshot.project
  end
end
