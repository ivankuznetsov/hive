require "test_helper"
require "hive/runtime_control_plane"

class RuntimeControlPlaneCodecTest < Minitest::Test
  def test_invalid_json_values_and_normalized_keys_are_typed
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::RuntimeControlPlane::Codec.dump_json(Object.new)
    end
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::RuntimeControlPlane::Codec.dump_json("e\u0301" => 1, "é" => 2)
    end
  end

  def test_invalid_and_noncanonical_times_are_typed
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::RuntimeControlPlane::Codec.dump_time(Object.new)
    end
    broken = Object.new
    broken.define_singleton_method(:utc) { self }
    broken.define_singleton_method(:iso8601) { |_| raise ArgumentError, "bad" }
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::RuntimeControlPlane::Codec.dump_time(broken)
    end
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::RuntimeControlPlane::Codec.load_time("not-a-time")
    end
    assert_raises(Hive::RuntimeControlPlane::CodecError) do
      Hive::RuntimeControlPlane::Codec.load_time("2026-08-31T12:00:00Z")
    end
  end

  def test_invalid_utf8_is_rejected_before_persistence
    valid_binary = "Claude stopped · retry the review".b
    assert_equal "Claude stopped · retry the review",
                 Hive::RuntimeControlPlane::Codec.normalize_string(valid_binary)
    assert_equal "café", Hive::RuntimeControlPlane::Codec.normalize_string("cafe\u0301".b)

    invalid = "\xFF".b.force_encoding(Encoding::UTF_8)
    assert_raises(ArgumentError) { Hive::RuntimeControlPlane::Codec.normalize_string(invalid) }
    assert_raises(ArgumentError) do
      Hive::RuntimeControlPlane::Codec.normalize_string("\xFF".b)
    end
    assert_raises(ArgumentError) do
      Hive::RuntimeControlPlane::Codec.normalize_string("\xFF".b.force_encoding(Encoding::US_ASCII))
    end
  end
end
