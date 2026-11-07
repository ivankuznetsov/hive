require "test_helper"
require "hive/remote/serializers"

class RemoteSerializersTest < Minitest::Test
  def test_task_and_question_dtos_keep_schema_provenance_without_native_paths_or_bindings
    serializer = Hive::Remote::Serializers.new(project_names: [ "demo" ])
    native_task = { "project" => "demo", "id" => 42, "slug" => "task", "stage" => "2-brainstorm",
                   "generation" => "generation", "folder" => "/private/server/task" }
    document = { "schema" => "hive-task-workspace", "schema_version" => 2,
                "task" => native_task, "status" => { "state" => "waiting", "internal" => "/private/status" },
                "headline" => { "state" => "waiting", "label" => "Needs an answer", "command" => "/private/command" },
                "actions" => [ { "command" => "/private/action" } ] }
    task = serializer.task(document)
    assert_equal "hive-task-workspace", task.fetch("source_schema")
    assert_equal 2, task.fetch("source_schema_version")
    assert_equal 42, task.dig("task", "id")
    assert_empty task.fetch("actions")
    refute_includes JSON.generate(task), "/private"

    inventory = { "schema" => "hive-answer", "schema_version" => 1, "task" => native_task,
                 "slot_count" => 1, "unanswered_count" => 1, "complete" => false,
                 "slots" => [ { "binding" => "/private/native-binding" } ] }
    slots = [ { "handle" => "opaque-question", "text" => "Which color?" } ]
    questions = serializer.questions(inventory, slots)
    assert_equal "hive-answer", questions.fetch("source_schema")
    assert_equal slots, questions.fetch("slots")
    assert_equal 1, questions.fetch("unanswered_count")
    refute_includes JSON.generate(questions), "/private"
    log = serializer.log("state" => "available", "content" => "tail", "truncated" => true,
      "continuation" => nil, "path" => "/private/log", "command" => "private command")
    assert_equal({ "state" => "available", "content" => "tail", "truncated" => true, "continuation" => nil }, log)
  end

  def test_status_explicit_fields_redact_other_project_dependencies
    dto = Hive::Remote::Serializers.new(project_names: [ "demo" ]).status_row(
      { "slug" => "task", "id" => 1, "stage" => "1-inbox", "folder" => "/secret/path",
        "depends_on" => "private:secret", "blocked" => true, "suggested_command" => "secret-command",
        "unmet_dependencies" => [ { "reference" => "private:secret", "blocked_by" => "private:secret" },
                                    { "reference" => "local-task", "required_gate" => "9-done" } ] }, project: "demo")
    refute_includes JSON.generate(dto), "secret"
    assert_equal true, dto.fetch("blocked")
    assert_nil dto["depends_on"]
    assert_equal [ { "reference" => "local-task", "required_gate" => "9-done" } ], dto.fetch("unmet_dependencies")
  end

  def test_bounded_content_measures_serialized_envelope_including_escaping
    dto = { "state" => "available", "content" => "\"\\\n" * 1000, "truncated" => false }
    Hive::Remote::Serializers.bound!(dto, max_bytes: 1024, instance_id: "installation")
    assert_operator JSON.generate(Hive::Remote::Protocol.envelope(instance_id: "installation", data: dto)).bytesize, :<=, 1024
    assert dto.fetch("truncated")
  end
  def test_diff_preserves_committed_content_and_bounds_escaped_bytes
    dto = Hive::Remote::Serializers.new(project_names: []).diff(
      { "state" => "available", "sections" => { "committed" => "\"\\\n" * 1000, "diagnostic" => "/private/path" }, "truncated" => false })
    assert_includes dto.fetch("sections"), "committed"
    refute_includes JSON.generate(dto), "/private/path"
    Hive::Remote::Serializers.bound!(dto, max_bytes: 1024, instance_id: "installation")
    assert_operator JSON.generate(Hive::Remote::Protocol.envelope(instance_id: "installation", data: dto)).bytesize, :<=, 1024
    assert dto.fetch("truncated")
  end
  def test_bounded_arrays_preserve_utf8_and_refuse_unrepresentable_control_fields
    dto = { "slots" => [ { "text" => "é" * 2000, "answer" => "reply" * 1000 } ] }
    Hive::Remote::Serializers.bound!(dto, max_bytes: 1024, instance_id: "installation")
    assert dto.fetch("slots").all? { |slot| slot.values.all?(&:valid_encoding?) }
    assert_operator JSON.generate(Hive::Remote::Protocol.envelope(instance_id: "installation", data: dto)).bytesize, :<=, 1024
    error = assert_raises(Hive::Remote::Error) do
      Hive::Remote::Serializers.bound!({ "id" => "a" * 2000 }, max_bytes: 512, instance_id: "installation")
    end
    assert_equal 413, error.status
  end
end
