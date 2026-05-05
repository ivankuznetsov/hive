require "test_helper"
require "hive/tui/input_decoder"

class HiveTuiInputDecoderTest < Minitest::Test
  include HiveTestHelper

  def decoder
    @decoder ||= Hive::Tui::InputDecoder.new
  end

  def test_plain_multi_character_chunk_becomes_raw_text
    messages = decoder.drain("hello")
    assert_equal 1, messages.size
    assert_kind_of Hive::Tui::Messages::RawTextInput, messages.first
    assert_equal "hello", messages.first.text
    assert_equal false, messages.first.paste
  end

  def test_single_printable_byte_stays_key_message
    messages = decoder.drain("p")
    assert_equal 1, messages.size
    assert_kind_of Bubbletea::KeyMessage, messages.first
    assert_equal Bubbletea::KeyMessage::KEY_RUNES, messages.first.key_type
    assert_equal "p", messages.first.char
  end

  def test_single_space_uses_space_key_message
    msg = decoder.drain(" ").first
    assert_kind_of Bubbletea::KeyMessage, msg
    assert_equal Bubbletea::KeyMessage::KEY_SPACE, msg.key_type
  end

  def test_bracketed_paste_becomes_one_raw_text_message
    messages = decoder.drain("\e[200~hello world\e[201~")
    assert_equal 1, messages.size
    assert_kind_of Hive::Tui::Messages::RawTextInput, messages.first
    assert_equal "hello world", messages.first.text
    assert_equal true, messages.first.paste
  end

  def test_bracketed_paste_start_marker_can_split_across_chunks
    assert_empty decoder.drain("\e[20")
    messages = decoder.drain("0~hello\e[201~")
    assert_equal 1, messages.size
    assert_equal "hello", messages.first.text
  end

  def test_bracketed_paste_payload_can_split_across_chunks
    assert_empty decoder.drain("\e[200~hel")
    assert_empty decoder.drain("lo ")
    messages = decoder.drain("world\e[201~")
    assert_equal 1, messages.size
    assert_equal "hello world", messages.first.text
  end

  def test_bracketed_paste_end_marker_can_split_across_chunks
    assert_empty decoder.drain("\e[200~hello\e[20")
    messages = decoder.drain("1~")
    assert_equal 1, messages.size
    assert_equal "hello", messages.first.text
  end

  def test_bracketed_paste_normalizes_newlines_and_tabs
    msg = decoder.drain("\e[200~hello\n\tworld\ragain\e[201~").first
    assert_equal "hello world again", msg.text
  end

  def test_arrow_home_end_delete_sequences_decode_to_key_messages
    expected = {
      "\e[A" => Bubbletea::KeyMessage::KEY_UP,
      "\e[B" => Bubbletea::KeyMessage::KEY_DOWN,
      "\e[C" => Bubbletea::KeyMessage::KEY_RIGHT,
      "\e[D" => Bubbletea::KeyMessage::KEY_LEFT,
      "\eOA" => Bubbletea::KeyMessage::KEY_UP,
      "\eOB" => Bubbletea::KeyMessage::KEY_DOWN,
      "\eOC" => Bubbletea::KeyMessage::KEY_RIGHT,
      "\eOD" => Bubbletea::KeyMessage::KEY_LEFT,
      "\e[H" => Bubbletea::KeyMessage::KEY_HOME,
      "\e[F" => Bubbletea::KeyMessage::KEY_END,
      "\eOH" => Bubbletea::KeyMessage::KEY_HOME,
      "\eOF" => Bubbletea::KeyMessage::KEY_END,
      "\e[3~" => Bubbletea::KeyMessage::KEY_DELETE
    }
    expected.each do |bytes, key_type|
      msg = Hive::Tui::InputDecoder.new.drain(bytes).first
      assert_kind_of Bubbletea::KeyMessage, msg
      assert_equal key_type, msg.key_type
    end
  end

  def test_control_shortcuts_decode_to_key_messages
    assert_equal Bubbletea::KeyMessage::KEY_CTRL_A, decoder.drain("\x01").first.key_type
    assert_equal Bubbletea::KeyMessage::KEY_CTRL_E, decoder.drain("\x05").first.key_type
  end

  def test_lone_escape_flushes_after_timeout
    assert_empty decoder.drain("\e")
    msg = decoder.flush.first
    assert_kind_of Bubbletea::KeyMessage, msg
    assert_equal Bubbletea::KeyMessage::KEY_ESC, msg.key_type
  end

  def test_incomplete_escape_sequence_does_not_insert_marker_bytes
    assert_empty decoder.drain("\e[20")
    assert_empty decoder.flush
  end

  # ---- Fix 1: unmapped control bytes must not wedge the decoder ----

  def test_unmapped_control_byte_does_not_stall_decoder
    messages = decoder.drain("\x02hello")
    text_messages = messages.select { |m| m.is_a?(Hive::Tui::Messages::RawTextInput) }
    assert_equal 1, text_messages.size, "decoder must drop \\x02 and decode the trailing text"
    assert_equal "hello", text_messages.first.text
  end

  def test_ctrl_c_emits_key_ctrl_c_keymessage
    messages = decoder.drain("\x03")
    assert_equal 1, messages.size
    assert_kind_of Bubbletea::KeyMessage, messages.first
    assert_equal Bubbletea::KeyMessage::KEY_CTRL_C, messages.first.key_type
  end

  def test_unmapped_control_byte_followed_by_more_input_continues_decoding
    messages = decoder.drain("\x04abc")
    text_messages = messages.select { |m| m.is_a?(Hive::Tui::Messages::RawTextInput) }
    assert_equal 1, text_messages.size
    assert_equal "abc", text_messages.first.text
  end

  # ---- Fix 2: paste buffer cap ----

  def test_unbounded_paste_buffer_is_capped_with_flash
    # Open a paste, then feed chunks small enough to slip past the
    # @pending overflow cap (each drain dumps its bytes straight into
    # @paste_buffer). The cumulative paste content must trip
    # MAX_PASTE_BYTES, not MAX_PENDING_BYTES.
    decoder.drain("\e[200~")
    chunk = "x" * 2048 # well under MAX_PENDING_BYTES per drain
    flash = nil
    700.times do
      messages = decoder.drain(chunk)
      flash = messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
      break if flash
    end
    refute_nil flash, "expected a Flash message announcing the truncation"
    assert_match(/paste truncated/i, flash.text)
    # And subsequent input should make forward progress (the cap reset
    # paste state, so plain text is decoded normally afterward).
    follow_up = decoder.drain("hello")
    text = follow_up.find { |m| m.is_a?(Hive::Tui::Messages::RawTextInput) }
    refute_nil text
    assert_equal "hello", text.text
  end

  # ---- Fix 3: reset! clears paste state, paste timeout force-flushes ----

  def test_reset_clears_pending_paste_buffer_and_in_paste
    decoder.drain("\e[200~partial-paste-without-close")
    decoder.reset!
    # After reset, a fresh char decodes as a normal key — proves both
    # @pending and @in_paste were cleared.
    msg = decoder.drain("a").first
    assert_kind_of Bubbletea::KeyMessage, msg
    assert_equal "a", msg.char
  end

  def test_paste_timeout_force_exits_paste_mode_after_threshold
    decoder.drain("\e[200~hello world")
    # First flush within the window: paste held, no messages.
    assert_empty decoder.flush
    # Backdate `@paste_started_at` so paste_timed_out? trips. This
    # avoids depending on Minitest::Mock (not bundled by default) and
    # keeps the timing test deterministic.
    decoder.instance_variable_set(
      :@paste_started_at,
      Time.now - Hive::Tui::InputDecoder::PASTE_TIMEOUT_SECONDS - 1
    )
    messages = decoder.flush
    raw = messages.find { |m| m.is_a?(Hive::Tui::Messages::RawTextInput) }
    flash = messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
    refute_nil raw, "timeout must emit any buffered paste content"
    assert_equal "hello world", raw.text
    refute_nil flash, "timeout must surface a Flash so the user notices"
    assert_match(/paste timed out/i, flash.text)
  end

  # ---- Fix 4: pending overflow safety net ----

  def test_pending_buffer_capped_against_runaway_growth
    # Stage a large slug of bytes into @pending without a paste marker.
    # The cap kicks on the *next* drain so we hit guard_pending_overflow
    # at the top of the loop.
    huge = "\e[" * 5000 # 10_000 bytes; well over MAX_PENDING_BYTES
    messages = decoder.drain(huge)
    flash = messages.find { |m| m.is_a?(Hive::Tui::Messages::Flash) }
    refute_nil flash
    assert_match(/overflow/i, flash.text)
    # Subsequent input decodes cleanly (proves @pending was reset).
    follow = decoder.drain("ok")
    text = follow.find { |m| m.is_a?(Hive::Tui::Messages::RawTextInput) }
    refute_nil text
    assert_equal "ok", text.text
  end

  # ---- Fix 9: stray PASTE_END is silently consumed ----

  def test_stray_paste_end_marker_is_silently_consumed
    messages = decoder.drain("\e[201~hi")
    # The stray close marker emits nothing. The trailing "hi" comes
    # through as a normal RawTextInput.
    text = messages.find { |m| m.is_a?(Hive::Tui::Messages::RawTextInput) }
    refute_nil text
    assert_equal "hi", text.text
    assert_nil messages.find { |m| m.is_a?(Bubbletea::KeyMessage) && m.key_type == Bubbletea::KeyMessage::KEY_ESC }
  end

  # ---- Fix 10: paste content has C0 control bytes stripped ----

  def test_normalize_paste_strips_embedded_escape_sequences
    msg = decoder.drain("\e[200~hi\x07the\x00re\e[201~").first
    assert_kind_of Hive::Tui::Messages::RawTextInput, msg
    assert_equal "hithere", msg.text
    assert_equal true, msg.paste
  end

  # ---- Fix 11: ESC-then-Enter cancel gesture absorbs the trailing CR/LF ----

  def test_esc_followed_by_enter_emits_only_esc_not_enter
    # Send ESC then a non-recognized escape continuation that flushes
    # the lone ESC + a trailing CR/LF, all in one read.
    messages = decoder.drain("\e\r")
    esc_messages = messages.select { |m| m.is_a?(Bubbletea::KeyMessage) && m.key_type == Bubbletea::KeyMessage::KEY_ESC }
    enter_messages = messages.select { |m| m.is_a?(Bubbletea::KeyMessage) && m.key_type == Bubbletea::KeyMessage::KEY_ENTER }
    assert_equal 1, esc_messages.size, "expected exactly one KEY_ESC"
    assert_empty enter_messages, "trailing CR must be absorbed, not promoted to KEY_ENTER"
  end
end
