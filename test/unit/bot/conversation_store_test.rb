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
    state = store.start(
      chat_id: 123, slug: "slug", question_n: 2,
      binding: "opaque-slot-binding", mode: :path_b
    )

    assert_equal state, store.get(chat_id: 123, slug: "slug")
    assert_equal 2, state.question_n
    assert_equal "opaque-slot-binding", state.binding
    assert_equal :path_b, state.mode
  end

  def test_get_by_chat_returns_active_state
    store.start(chat_id: 123, slug: "slug", question_n: 1)

    assert_equal "slug", store.get(chat_id: 123).slug
  end

  # Regression: starting a second answer conversation for the same chat must
  # supersede the first. Previously both entries coexisted under different
  # keys and `get(chat_id:)` returned whichever slug was started first, so a
  # free-text reply after opening task B was written to task A.
  def test_start_supersedes_previous_conversation_for_same_chat
    store.start(chat_id: 1, slug: "task-a", question_n: 1)
    store.start(chat_id: 1, slug: "task-b", question_n: 1)

    state = store.get(chat_id: 1)

    refute_nil state, "the newest conversation for the chat must remain active"
    assert_equal "task-b", state.slug,
                 "slug-less lookup must return the most recently started conversation"
    assert_equal 1, store.get(chat_id: 1, slug: "task-b").question_n
    assert_nil store.get(chat_id: 1, slug: "task-a"),
               "the superseded conversation must be removed, not left behind"
  end

  def test_start_in_one_chat_does_not_disturb_other_chats
    store.start(chat_id: 1, slug: "task-a", question_n: 1)
    store.start(chat_id: 2, slug: "task-b", question_n: 1)

    assert_equal "task-a", store.get(chat_id: 1).slug
    assert_equal "task-b", store.get(chat_id: 2).slug
  end

  def test_update_mutates_known_attrs_and_refreshes_timestamp
    store.start(chat_id: 123, slug: "slug", question_n: 1)
    @now += 10

    state = store.update(chat_id: 123, slug: "slug", question_n: 2)

    assert_equal 2, state.question_n
    assert_equal @now, state.updated_at
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

  def test_active_for_slug_stays_active_if_any_chat_is_fresh
    store.start(chat_id: 1, slug: "slug", question_n: 1)
    @now += 40
    store.start(chat_id: 2, slug: "slug", question_n: 1) # refreshes chat 2's clock
    @now += 30 # chat 1 now 70s old (expired), chat 2 30s old (live)

    assert store.active_for_slug?("slug"),
           "still active while at least one chat's conversation is within TTL"
  end

  def test_active_for_slug_optional_project_scoping
    store.start(chat_id: 1, project: "proj-a", slug: "slug", question_n: 1)

    assert store.active_for_slug?("slug"), "unscoped query matches"
    assert store.active_for_slug?("slug", project: "proj-a"), "matching project matches"
    refute store.active_for_slug?("slug", project: "proj-b"),
           "a different fully-resolved project does not cross-suppress"

    # A conversation with no project still suppresses any project (lenient).
    store.start(chat_id: 2, project: nil, slug: "slug2", question_n: 1)
    assert store.active_for_slug?("slug2", project: "proj-b"),
           "a project-less conversation suppresses leniently"
  end

  # Regression guard for the mutex: concurrent prune (reader) + mutation
  # (writer) on @states must not raise "can't add a new key during
  # iteration".
  def test_concurrent_access_does_not_raise
    s = Hive::Bot::ConversationStore.new(ttl_sec: 60, now: -> { Time.now })
    errors = []
    writers = Array.new(4) do |i|
      Thread.new do
        300.times { |j| s.start(chat_id: i, slug: "slug-#{j % 8}", question_n: 1) }
      rescue StandardError => e
        errors << e
      end
    end
    readers = Array.new(4) do
      Thread.new do
        300.times { s.active_for_slug?("slug-3") }
      rescue StandardError => e
        errors << e
      end
    end
    (writers + readers).each(&:join)

    assert_empty errors, "mutex-guarded @states must tolerate concurrent read/prune + write"
  end
end
