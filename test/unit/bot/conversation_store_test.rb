require "test_helper"
require "hive/bot/conversation_store"

class HiveBotConversationStoreTest < Minitest::Test
  def setup
    @now = Time.utc(2026, 5, 14, 12, 0, 0)
  end

  def store
    @store ||= Hive::Bot::ConversationStore.new(ttl_sec: 60, now: -> { @now })
  end

  def test_start_and_get_by_chat_and_slug
    state = store.start(chat_id: 123, slug: "slug", question_n: 2, mode: :path_b)

    assert_equal state, store.get(chat_id: 123, slug: "slug")
    assert_equal 2, state.question_n
    assert_equal :path_b, state.mode
  end

  def test_get_by_chat_returns_active_state
    store.start(chat_id: 123, slug: "slug", question_n: 1)

    assert_equal "slug", store.get(chat_id: 123).slug
  end

  def test_update_mutates_known_attrs_and_refreshes_timestamp
    store.start(chat_id: 123, slug: "slug", question_n: 1)
    @now += 10

    state = store.update(chat_id: 123, slug: "slug", draft: "draft", awaiting_confirm: true)

    assert_equal "draft", state.draft
    assert_equal true, state.awaiting_confirm
    assert_equal @now, state.updated_at
    assert_equal 1, store.pending_confirm_count(chat_id: 123)
  end

  def test_update_rejects_unknown_attrs
    store.start(chat_id: 123, slug: "slug", question_n: 1)

    assert_raises(ArgumentError) do
      store.update(chat_id: 123, slug: "slug", made_up: true)
    end
  end

  def test_update_ttl_changes_prune_window
    store.start(chat_id: 123, slug: "slug", question_n: 1)
    store.update_ttl(5)
    @now += 6

    assert_nil store.get(chat_id: 123, slug: "slug")
  end

  def test_start_rejects_unknown_mode
    error = assert_raises(ArgumentError) do
      store.start(chat_id: 123, slug: "slug", question_n: 1, mode: :surprise)
    end

    assert_match(/conversation mode must be one of/, error.message)
    assert_match(/:surprise/, error.message)
  end

  def test_ttl_prunes_old_state
    store.start(chat_id: 123, slug: "slug", question_n: 1)
    @now += 61

    assert_nil store.get(chat_id: 123, slug: "slug")
  end

  def test_clear_removes_state
    store.start(chat_id: 123, slug: "slug", question_n: 1)
    store.clear(chat_id: 123, slug: "slug")

    assert_nil store.get(chat_id: 123, slug: "slug")
  end

  def test_active_for_slug_tracks_any_chat_and_respects_ttl
    refute store.active_for_slug?("slug"), "no conversation yet"

    store.start(chat_id: 999, slug: "slug", question_n: 1)
    assert store.active_for_slug?("slug"), "active for any chat answering the slug"
    refute store.active_for_slug?("other-slug")

    # Past the TTL the abandoned conversation no longer suppresses.
    @now += 61
    refute store.active_for_slug?("slug"), "a TTL-expired conversation is not active"
  end
end
