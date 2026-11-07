require "test_helper"
require "hive/remote/serializers"

class RemoteSerializersTest < Minitest::Test
  def test_status_explicit_fields_redact_other_project_dependencies
    dto = Hive::Remote::Serializers.new(project_names: ["demo"]).status_row(
      { "slug" => "task", "id" => 1, "stage" => "1-inbox", "folder" => "/secret/path",
        "depends_on" => "private:secret", "blocked" => true, "suggested_command" => "secret-command",
        "unmet_dependencies" => [{"reference" => "private:secret", "blocked_by" => "private:secret"},
                                    {"reference" => "local-task", "required_gate" => "9-done"}] }, project: "demo")
    refute_includes JSON.generate(dto), "secret"
    assert_equal true, dto.fetch("blocked")
    assert_nil dto["depends_on"]
    assert_equal [ {"reference" => "local-task", "required_gate" => "9-done"} ], dto.fetch("unmet_dependencies")
  end

  def test_bounded_content_measures_serialized_envelope_including_escaping
    dto = { "state" => "available", "content" => "\"\\\n" * 1000, "truncated" => false }
    Hive::Remote::Serializers.bound!(dto, max_bytes: 1024, instance_id: "installation")
    assert_operator JSON.generate(Hive::Remote::Protocol.envelope(instance_id: "installation", data: dto)).bytesize, :<=, 1024
    assert dto.fetch("truncated")
  end
  def test_diff_preserves_committed_content_and_bounds_escaped_bytes
    dto = Hive::Remote::Serializers.new(project_names: []).diff(
      {"state" => "available", "sections" => {"committed" => "\"\\\n" * 1000, "diagnostic" => "/private/path"}, "truncated" => false})
    assert_includes dto.fetch("sections"), "committed"
    refute_includes JSON.generate(dto), "/private/path"
    Hive::Remote::Serializers.bound!(dto, max_bytes: 1024, instance_id: "installation")
    assert_operator JSON.generate(Hive::Remote::Protocol.envelope(instance_id: "installation", data: dto)).bytesize, :<=, 1024
    assert dto.fetch("truncated")
  end
  def test_bounded_arrays_preserve_utf8_and_refuse_unrepresentable_control_fields
    dto = {"slots" => [{"text" => "é" * 2000, "answer" => "reply" * 1000}]}
    Hive::Remote::Serializers.bound!(dto, max_bytes: 1024, instance_id: "installation")
    assert dto.fetch("slots").all? { |slot| slot.values.all?(&:valid_encoding?) }
    assert_operator JSON.generate(Hive::Remote::Protocol.envelope(instance_id: "installation", data: dto)).bytesize, :<=, 1024
    error = assert_raises(Hive::Remote::Error) do
      Hive::Remote::Serializers.bound!({"id" => "a" * 2000}, max_bytes: 512, instance_id: "installation")
    end
    assert_equal 413, error.status
  end
end
