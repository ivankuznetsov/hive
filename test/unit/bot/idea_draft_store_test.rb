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
end
