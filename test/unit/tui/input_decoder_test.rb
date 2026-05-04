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
end
