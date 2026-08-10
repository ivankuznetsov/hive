require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/answer"

class HiveCommandsAnswerTest < Minitest::Test
  include HiveTestHelper

  SLUG = "answer-task-260810-abcd"
  TASK_ID = 41

  def sample
    <<~MARKDOWN
      ## Round 1

      ### Q2. Physically first?
      ### A2.

      ### Q1. Physically second?
      ### A1.

      ## Round 2

      ### Q1. Later same-number question?
      ### A1.

      <!-- WAITING -->
    MARKDOWN
  end

  def with_project(content = sample, input_fingerprint: "a" * 64)
    with_tmp_global_config do
      with_tmp_dir do |root|
        project = File.join(root, "demo-project")
        hive_state = File.join(project, ".hive-state")
        folder = File.join(hive_state, "stages", "2-brainstorm", SLUG)
        FileUtils.mkdir_p(folder)
        File.write(File.join(hive_state, "config.yml"), {}.to_yaml)
        Hive::TaskMeta.write(
          folder,
          id: TASK_ID,
          slug: SLUG,
          display_name: "Answer Task",
          input_fingerprint: input_fingerprint,
          idempotency_key: "answer-task"
        )
        path = File.join(folder, "brainstorm.md")
        File.write(path, content)
        Hive::Config.register_project(name: "demo", path: project)
        yield(project, folder, path)
      end
    end
  end

  def call_answer(target: SLUG, project: "demo", binding: nil, answer: "", json: true)
    output = StringIO.new
    Hive::Commands::Answer.new(
      target,
      project: project,
      binding: binding,
      json: json,
      input: StringIO.new(answer),
      output: output
    ).call
    JSON.parse(output.string)
  end

  def inventory
    call_answer
  end

  def schema
    @schema ||= JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-answer"))))
  end

  def assert_schema(payload)
    assert_empty schema.validate(payload).to_a, payload.inspect
  end

  def test_inventory_is_read_only_and_lists_physical_document_order
    with_project do |_project, folder, path|
      before = File.binread(path)
      payload = inventory

      assert_equal "inventory", payload.fetch("operation")
      assert_equal [ 2, 1, 1 ], payload.fetch("slots").map { |slot| slot.fetch("question_number") }
      assert_equal [ 1, 2, 3 ], payload.fetch("slots").map { |slot| slot.fetch("ordinal") }
      assert_equal 3, payload.fetch("unanswered_count")
      assert_equal false, payload.fetch("complete")
      assert payload.fetch("slots").all? { |slot| slot.fetch("binding").match?(/\A[A-Za-z0-9_-]+\z/) }
      assert_equal before, File.binread(path)
      refute File.exist?(File.join(folder, ".lock")), "read-only inventory must not publish a task lock"
      assert_schema(payload)
    end
  end

  def test_binding_writes_the_later_same_number_slot_by_document_ordinal
    with_project do |_project, _folder, path|
      token = inventory.fetch("slots").fetch(2).fetch("binding")
      payload = call_answer(binding: token, answer: "Round two only")

      assert_equal "written", payload.fetch("outcome")
      assert_equal false, payload.fetch("relocated")
      questions = Hive::BrainstormParser.parse(path)
      assert_nil questions.fetch(0).answer
      assert_nil questions.fetch(1).answer
      assert_equal "Round two only", questions.fetch(2).answer
      assert_schema(payload)
    end
  end

  def test_missing_answer_header_is_repaired_within_the_bound_question
    content = <<~MARKDOWN
      ## Round 1
      ### Q1. Missing slot?
      ### Q2. Keep this empty too?
      ### A2.
      <!-- WAITING -->
    MARKDOWN
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      payload = call_answer(binding: token, answer: "Repaired")

      assert_equal "written", payload.fetch("outcome")
      assert_includes File.read(path), "### Q1. Missing slot?\n### A1.\nRepaired\n### Q2."
      assert_nil Hive::BrainstormParser.parse(path).fetch(1).answer
    end
  end

  def test_unique_renumbered_question_relocates_but_duplicate_and_missing_matches_reject
    content = "## Round 1\n### Q1. Keep?\n### A1.\n<!-- WAITING -->\n"
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      File.write(path, content.sub("Q1", "Q9").sub("A1", "A9"))

      relocated = call_answer(binding: token, answer: "yes")
      assert_equal "written", relocated.fetch("outcome")
      assert_equal true, relocated.fetch("relocated")
      assert_equal 9, relocated.dig("slot", "question_number")
      assert_equal "yes", Hive::BrainstormParser.parse(path).first.answer
    end

    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      duplicate = <<~MARKDOWN
        ## Round 1
        ### Q7. Keep?
        ### A7.
        Already answered
        ### Q8. Keep?
        ### A8.
        <!-- WAITING -->
      MARKDOWN
      File.write(path, duplicate)
      before = File.binread(path)

      rejected = call_answer(binding: token, answer: "unsafe")
      assert_equal "ambiguous", rejected.fetch("outcome")
      assert_equal "multiple_matches", rejected.fetch("reason")
      assert_equal before, File.binread(path)
      assert_schema(rejected)
    end

    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      File.write(path, content.sub("Keep?", "Changed materially?"))
      before = File.binread(path)

      rejected = call_answer(binding: token, answer: "unsafe")
      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "question_changed", rejected.fetch("reason")
      assert_equal before, File.binread(path)
      assert_schema(rejected)
    end
  end

  def test_identical_retry_is_idempotent_and_different_retry_conflicts
    with_project do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      first = call_answer(binding: token, answer: "same answer")
      after_first = File.binread(path)
      repeated = call_answer(binding: token, answer: "same answer\n")
      conflict = call_answer(binding: token, answer: "different")

      assert_equal "written", first.fetch("outcome")
      assert_equal "idempotent", repeated.fetch("outcome")
      assert_equal "conflict", conflict.fetch("outcome")
      assert_equal "already_answered_different", conflict.fetch("reason")
      assert_equal after_first, File.binread(path)
      assert_schema(repeated)
      assert_schema(conflict)
    end
  end

  def test_moved_task_and_changed_generation_fail_closed_without_recreating_source
    with_project do |_project, folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      destination = folder.sub("2-brainstorm", "3-plan")
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(folder, destination)

      rejected = call_answer(binding: token, answer: "too late")
      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "task_moved", rejected.fetch("reason")
      refute Dir.exist?(folder), "create:false locking must not recreate the old stage folder"
      assert_nil Hive::BrainstormParser.parse(File.join(destination, "brainstorm.md")).first.answer
      assert_schema(rejected)
    end

    with_project do |_project, folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      Hive::TaskMeta.write(
        folder,
        id: TASK_ID,
        slug: SLUG,
        display_name: "Replacement task",
        input_fingerprint: "b" * 64,
        idempotency_key: "replacement-task"
      )
      before = File.binread(path)

      rejected = call_answer(binding: token, answer: "wrong generation")
      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "generation_changed", rejected.fetch("reason")
      assert_equal before, File.binread(path)
      assert_schema(rejected)
    end

    with_project do |project, folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      old_incarnation = File.join(project, "old-incarnation")
      File.rename(folder, old_incarnation)
      FileUtils.mkdir_p(folder)
      FileUtils.cp(File.join(old_incarnation, "meta.yml"), File.join(folder, "meta.yml"))
      FileUtils.cp(File.join(old_incarnation, "brainstorm.md"), path)
      before = File.binread(path)

      rejected = call_answer(binding: token, answer: "replacement folder")
      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "generation_changed", rejected.fetch("reason")
      assert_equal before, File.binread(path)
    end
  end

  def test_task_input_epoch_change_invalidates_the_binding
    with_project do |_project, _folder, path|
      epoch = 0
      resolver = ->(*, **) { epoch }
      with_replaced_singleton_method(Hive::Attempts::Generation, :current_task_input_epoch, resolver) do
        token = inventory.fetch("slots").first.fetch("binding")
        epoch = 1
        before = File.binread(path)

        rejected = call_answer(binding: token, answer: "new epoch")
        assert_equal "stale", rejected.fetch("outcome")
        assert_equal "generation_changed", rejected.fetch("reason")
        assert_equal before, File.binread(path)
      end
    end
  end

  def test_inventory_rejects_a_non_coding_workflow_even_at_the_same_stage
    workflow = Struct.new(:id).new(:custom)
    task = Struct.new(:stage_index, :stage_name, :workflow).new(2, "brainstorm", workflow)
    command = Hive::Commands::Answer.new(SLUG)

    error = assert_raises(Hive::WrongStage) do
      command.send(:validate_brainstorm_stage!, task)
    end
    assert_match(/coding workflow/, error.message)
  end

  def test_lock_contention_is_closed_and_final_write_does_not_dispatch
    content = "## Round 1\n### Q1. Final?\n### A1.\n<!-- WAITING -->\n"
    with_project(content) do |_project, folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      held = Hive::Lock.acquire_task_lock(folder, op: "test_holder", create: false)
      begin
        rejected = call_answer(binding: token, answer: "blocked")
        assert_equal "lock_busy", rejected.fetch("outcome")
        assert_equal "task_lock_busy", rejected.fetch("reason")
        assert_nil Hive::BrainstormParser.parse(path).first.answer
        assert_schema(rejected)
      ensure
        Hive::Lock.release_task_lock(folder, lock_id: held.fetch("lock_id"))
      end

      written = call_answer(binding: token, answer: "done")
      assert_equal "written", written.fetch("outcome")
      assert_equal 0, written.fetch("unanswered_count")
      assert_equal true, written.fetch("complete")
      assert Dir.exist?(folder), "answering the final slot must not dispatch or move the task"
    end
  end

  def test_multiline_shell_metacharacters_are_read_from_stdin_literally
    with_project do |_project, folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      side_effect = File.join(folder, "not-run")
      answer = "Use $(touch #{side_effect}) and `echo nope`.\nSecond line."
      payload = call_answer(binding: token, answer: answer)

      assert_equal "written", payload.fetch("outcome")
      assert_equal answer, Hive::BrainstormParser.parse(path).first.answer
      refute File.exist?(side_effect)
    end
  end

  def test_malformed_binding_and_blank_answer_emit_schema_valid_errors_without_writes
    with_project do |_project, _folder, path|
      before = File.binread(path)
      output = StringIO.new
      error = assert_raises(Hive::Commands::Answer::InvalidBinding) do
        Hive::Commands::Answer.new(
          SLUG,
          project: "demo",
          binding: "not+a+binding",
          json: true,
          input: StringIO.new("answer"),
          output: output
        ).call
      end
      assert_match(/malformed/, error.message)
      assert_schema(JSON.parse(output.string))
      assert_equal before, File.binread(path)

      token = inventory.fetch("slots").first.fetch("binding")
      output = StringIO.new
      assert_raises(Hive::Commands::Answer::InvalidAnswer) do
        Hive::Commands::Answer.new(
          SLUG,
          project: "demo",
          binding: token,
          json: true,
          input: StringIO.new(" \n\t"),
          output: output
        ).call
      end
      payload = JSON.parse(output.string)
      assert_equal "invalid_answer", payload.fetch("error_kind")
      assert_schema(payload)
      assert_equal before, File.binread(path)

      output = StringIO.new
      assert_raises(Hive::Commands::Answer::InvalidAnswer) do
        Hive::Commands::Answer.new(
          SLUG,
          project: "demo",
          binding: token,
          json: true,
          input: StringIO.new("\xFF".b),
          output: output
        ).call
      end
      payload = JSON.parse(output.string)
      assert_equal "invalid_answer", payload.fetch("error_kind")
      assert_schema(payload)
      assert_equal before, File.binread(path)
    end
  end
end
