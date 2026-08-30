require "test_helper"
require "json"
require "json_schemer"
require "hive/commands/answer"

class HiveCommandsAnswerTest < Minitest::Test
  include HiveTestHelper

  SLUG = "answer-task-260810-abcd"
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
          id: Digest::SHA256.hexdigest(File.expand_path(folder))[0, 12].to_i(16),
          slug: SLUG,
          display_name: "Answer Task",
          input_fingerprint: input_fingerprint,
          idempotency_key: "answer-task"
        )
        path = File.join(folder, "brainstorm.md")
        File.write(path, content)
        Hive::Config.register_project(name: "demo", path: project)
        prepare_test_task_lease_repository(folder)
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
      assert_equal %w[loading loading loading],
                   payload.fetch("slots").map { |slot| slot.dig("suggestion", "state") }
      assert payload.fetch("slots").all? { |slot| slot.dig("suggestion", "text").nil? }
      assert_equal before, File.binread(path)
      refute Hive::Lock.task_lock_held?(folder), "read-only inventory must not publish a task lease"
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
      assert_includes File.read(path),
                      "### Q1. Missing slot?\n#{Hive::BrainstormParser.encoded_answer_header(1)}\nRepaired\n### Q2."
      assert_nil Hive::BrainstormParser.parse(path).fetch(1).answer
    end
  end

  def test_unique_renumbered_question_relocates_using_only_unanswered_matches
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
      relocated = call_answer(binding: token, answer: "safe target")
      assert_equal "written", relocated.fetch("outcome")
      assert_equal true, relocated.fetch("relocated")
      assert_equal [ "Already answered", "safe target" ],
                   Hive::BrainstormParser.parse(path).map(&:answer)
      assert_schema(relocated)
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

  def test_unique_relocated_answered_question_is_idempotent_or_conflicting
    content = "## Round 1\n### Q1. Keep?\n### A1.\n<!-- WAITING -->\n"
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      File.write(path, "## Round 2\n### Q9. Keep?\n### A9.\nalready\n<!-- WAITING -->\n")

      same = call_answer(binding: token, answer: "already")
      different = call_answer(binding: token, answer: "different")

      assert_equal "idempotent", same.fetch("outcome")
      assert_equal true, same.fetch("relocated")
      assert_equal "conflict", different.fetch("outcome")
      assert_equal true, different.fetch("relocated")
    end
  end

  def test_duplicate_fingerprint_matches_are_ambiguous_and_never_write
    content = "## Round 1\n### Q1. Keep?\n### A1.\n<!-- WAITING -->\n"
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      File.write(path, <<~MARKDOWN)
        ## Round 2
        ### Q7. Keep?
        ### A7.
        ### Q8. Keep?
        ### A8.
        <!-- WAITING -->
      MARKDOWN
      before = File.binread(path)

      rejected = call_answer(binding: token, answer: "unsafe")

      assert_equal "ambiguous", rejected.fetch("outcome")
      assert_equal "multiple_matches", rejected.fetch("reason")
      assert_equal before, File.binread(path)
      assert_schema(rejected)
    end

    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      File.write(path, <<~MARKDOWN)
        ## Round 2
        ### Q7. Keep?
        ### A7.
        first
        ### Q8. Keep?
        ### A8.
        second
        <!-- WAITING -->
      MARKDOWN
      before = File.binread(path)

      rejected = call_answer(binding: token, answer: "unsafe")

      assert_equal "ambiguous", rejected.fetch("outcome")
      assert_equal "multiple_matches", rejected.fetch("reason")
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
        id: Hive::TaskMeta.read(folder).fetch(:id),
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

  def test_missing_task_returns_the_distinct_task_missing_reason
    with_project do |_project, folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      FileUtils.remove_entry(folder)

      rejected = call_answer(binding: token, answer: "too late")

      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "task_missing", rejected.fetch("reason")
      refute Dir.exist?(folder)
      assert_schema(rejected)
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

  def test_structural_answer_lines_are_persisted_safely_and_retry_idempotently
    content = "## Round 1\n### Q1. Literal markdown?\n### A1.\n<!-- WAITING -->\n"
    answer = <<~TEXT.rstrip
      ### Q999. Not a real question
      ### A999.
      ## Round 99
      <!-- COMPLETE -->
      \\### Q7. Keep my leading slash
    TEXT
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      written = call_answer(binding: token, answer: answer)
      retried = call_answer(binding: token, answer: answer)

      assert_equal "written", written.fetch("outcome")
      assert_equal "idempotent", retried.fetch("outcome")
      parsed = Hive::BrainstormParser.parse(path)
      assert_equal 1, parsed.length
      assert_equal answer, parsed.first.answer
      assert_equal :waiting, Hive::Markers.current(path).name
      assert_includes File.read(path), Hive::BrainstormParser::ANSWER_ESCAPE_PREFIX
      refute_includes File.read(path), "\n<!-- COMPLETE -->\n"
    end
  end

  def test_crlf_write_preserves_file_newlines
    content = "## Round 1\r\n### Q1. CRLF?\r\n### A1.\r\n<!-- WAITING -->\r\n"
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      payload = call_answer(binding: token, answer: "first\r\nsecond")

      assert_equal "written", payload.fetch("outcome")
      assert_equal "first\nsecond", Hive::BrainstormParser.parse(path).first.answer
      refute_match(/(?<!\r)\n/, File.binread(path))
    end
  end

  def test_binding_cannot_be_reused_for_another_invocation
    with_project do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      before = File.binread(path)

      rejected = call_answer(target: "another-task-260810-beef", binding: token, answer: "wrong task")

      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "identity_changed", rejected.fetch("reason")
      assert_equal before, File.binread(path)
      assert_schema(rejected)
    end
  end

  def test_reobserved_task_id_and_workflow_must_match_the_binding
    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      binding = JSON.parse(Base64.urlsafe_decode64(token)).merge("task_id" => nil)
      command = Hive::Commands::Answer.new(SLUG, project: "demo")
      task = command.send(:resolve_task, SLUG, "demo")
      task.define_singleton_method(:id) { 99 }
      command.define_singleton_method(:resolve_task) { |_target, _project| task }

      changed_id = command.send(:observe_bound_task, binding)

      assert_equal({ outcome: "stale", reason: "identity_changed" }, changed_id)

      task.define_singleton_method(:id) { nil }
      task.define_singleton_method(:workflow) { Struct.new(:id).new(:research) }
      changed_workflow = command.send(:observe_bound_task, binding)

      assert_equal({ outcome: "stale", reason: "identity_changed" }, changed_workflow)
    end
  end

  def test_inventory_reobservation_change_emits_stale_error_contract
    with_project do |_project, _folder, _path|
      output = StringIO.new
      command = Hive::Commands::Answer.new(SLUG, project: "demo", json: true, output: output)
      command.define_singleton_method(:same_task_path?) { |_left, _right| false }

      error = assert_raises(Hive::StaleOperationalObservation) { command.call }
      payload = JSON.parse(output.string)

      assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      assert_equal "stale", payload.fetch("error_kind")
      assert_schema(payload)
    end
  end

  def test_public_binding_shape_rejects_nonpositive_ids_rounds_and_empty_folders
    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      payload = JSON.parse(Base64.urlsafe_decode64(token))

      { "task_id" => 0, "round" => 0, "task_folder" => "" }.each do |key, value|
        invalid = payload.merge(key => value)
        invalid_token = Base64.urlsafe_encode64(JSON.generate(invalid), padding: false)
        output = StringIO.new
        assert_raises(Hive::Commands::Answer::InvalidBinding) do
          Hive::Commands::Answer.new(
            SLUG, project: "demo", binding: invalid_token, json: true,
            input: StringIO.new("answer"), output: output
          ).call
        end
        error_payload = JSON.parse(output.string)
        assert_equal "invalid_binding", error_payload.fetch("error_kind")
        assert_schema(error_payload)
      end
    end
  end

  def test_tampered_binding_is_rejected
    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      tampered = token.dup
      tampered[-1] = tampered[-1] == "A" ? "B" : "A"
      output = StringIO.new

      assert_raises(Hive::Commands::Answer::InvalidBinding) do
        Hive::Commands::Answer.new(
          SLUG, project: "demo", binding: tampered, json: true,
          input: StringIO.new("answer"), output: output
        ).call
      end
      assert_equal "invalid_binding", JSON.parse(output.string).fetch("error_kind")
    end
  end

  def test_corrupt_task_journal_is_an_invalid_task_path_not_generic_internal_error
    with_project do |_project, _folder, _path|
      failure = ->(*) { raise Hive::TaskProjection::InvalidJournal, "empty journal" }
      output = StringIO.new
      with_replaced_singleton_method(Hive::Attempts::Generation, :current_task_input_epoch, failure) do
        error = assert_raises(Hive::InvalidTaskPath) do
          Hive::Commands::Answer.new(SLUG, project: "demo", json: true, output: output).call
        end
        assert_equal Hive::ExitCodes::USAGE, error.exit_code
      end
      payload = JSON.parse(output.string)
      assert_equal "invalid_task_path", payload.fetch("error_kind")
      assert_schema(payload)
    end
  end

  def test_prelock_folder_disappearance_is_a_stale_task_moved_outcome
    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      command = Hive::Commands::Answer.new(
        SLUG, project: "demo", binding: token,
        input: StringIO.new("answer"), output: StringIO.new
      )
      command.define_singleton_method(:canonical_path) { |_path| raise Errno::ENOENT }

      payload = command.call
      assert_equal "stale", payload.fetch("outcome")
      assert_equal "task_moved", payload.fetch("reason")
      assert_schema(payload)
    end
  end

  def test_task_lock_enoent_and_under_lock_read_failure_are_closed_outcomes
    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      with_replaced_singleton_method(Hive::Lock, :with_task_lock, ->(*) { raise Errno::ENOENT }) do
        payload = call_answer(binding: token, answer: "answer")
        assert_equal "stale", payload.fetch("outcome")
        assert_equal "task_moved", payload.fetch("reason")
      end
    end

    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      command = Hive::Commands::Answer.new(
        SLUG, project: "demo", binding: token,
        input: StringIO.new("answer"), output: StringIO.new
      )
      command.define_singleton_method(:read_brainstorm!) do |_task|
        raise Hive::InvalidTaskPath, "state disappeared"
      end

      payload = command.call
      assert_equal "stale", payload.fetch("outcome")
      assert_equal "task_missing", payload.fetch("reason")
    end
  end

  def test_writer_closed_outcomes_are_preserved
    content = "## Round 1\n### Q1. Race?\n### A1.\n<!-- WAITING -->\n"
    with_project(content) do |_project, _folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      replacement = lambda do |**_kwargs|
        File.write(path, content.sub("### A1.\n", "### A1.\nsame\n"))
        :already_answered
      end
      with_replaced_singleton_method(
        Hive::Bot::BrainstormAnswerWriter, :write_at_ordinal_under_lock!, replacement
      ) do
        payload = call_answer(binding: token, answer: "same")
        assert_equal "idempotent", payload.fetch("outcome")
        assert_equal "already_answered_same", payload.fetch("reason")
      end
    end

    with_project(content) do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      replacement = ->(**_kwargs) { :question_not_found }
      with_replaced_singleton_method(
        Hive::Bot::BrainstormAnswerWriter, :write_at_ordinal_under_lock!, replacement
      ) do
        payload = call_answer(binding: token, answer: "same")
        assert_equal "stale", payload.fetch("outcome")
        assert_equal "question_missing", payload.fetch("reason")
        assert_schema(payload)
      end
    end


    with_project(content) do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      replacement = ->(**_kwargs) { :answer_slot_missing }
      with_replaced_singleton_method(
        Hive::Bot::BrainstormAnswerWriter, :write_at_ordinal_under_lock!, replacement
      ) do
        error = assert_raises(Hive::InternalError) do
          call_answer(binding: token, answer: "same")
        end
        assert_match(/brainstorm answer writer returned/, error.message)
      end
    end
  end

  def test_canonical_invocation_paths_accept_aliases_and_fail_closed
    with_project do |_project, folder, path|
      token = inventory.fetch("slots").first.fetch("binding")
      payload = call_answer(target: File.join(folder, "."), binding: token, answer: "path-bound")

      assert_equal "written", payload.fetch("outcome")
      assert_equal "path-bound", Hive::BrainstormParser.parse(path).first.answer
    end

    command = Hive::Commands::Answer.new("/definitely/missing/answer-task")
    assert_nil command.send(:canonical_invocation_path)
  end

  def test_answer_size_state_read_and_path_comparison_fail_closed
    with_project do |_project, _folder, _path|
      token = inventory.fetch("slots").first.fetch("binding")
      output = StringIO.new
      error = assert_raises(Hive::Commands::Answer::InvalidAnswer) do
        Hive::Commands::Answer.new(
          SLUG, project: "demo", binding: token, json: true,
          input: StringIO.new("x" * (Hive::Commands::Answer::MAX_ANSWER_BYTES + 1)),
          output: output
        ).call
      end
      assert_match(/exceeds/, error.message)
      assert_equal "invalid_answer", JSON.parse(output.string).fetch("error_kind")
    end

    command = Hive::Commands::Answer.new(SLUG)
    missing = Struct.new(:state_file, :slug).new("/definitely/missing/brainstorm.md", SLUG)
    assert_raises(Hive::InvalidTaskPath) { command.send(:read_brainstorm!, missing) }

    left = Struct.new(:folder).new("/definitely/missing/left")
    right = Struct.new(:folder).new("/definitely/missing/right")
    refute command.send(:same_task_path?, left, right)
  end

  def test_unexpected_errors_use_the_internal_error_envelope
    output = StringIO.new
    command = Hive::Commands::Answer.new(SLUG, json: true, output: output)
    command.define_singleton_method(:inventory_payload) { raise RuntimeError, "unexpected" }

    error = assert_raises(Hive::InternalError) { command.call }
    payload = JSON.parse(output.string)

    assert_match(/RuntimeError: unexpected/, error.message)
    assert_equal "internal", payload.fetch("error_kind")
    assert_schema(payload)
  end

  def test_programmatic_write_requires_a_nonempty_binding
    error = assert_raises(Hive::Commands::Answer::InvalidBinding) do
      Hive::Commands::Answer.write(SLUG, project: "demo", binding: "", answer: "unsafe")
    end

    assert_match(/binding is required/, error.message)
  end

  def test_text_mode_emits_inventory_and_write_acknowledgements
    with_project do |_project, _folder, _path|
      inventory_output = StringIO.new
      inventory_payload = Hive::Commands::Answer.new(
        SLUG, project: "demo", output: inventory_output
      ).call
      assert_equal "demo/#{SLUG}: 3/3 unanswered\n", inventory_output.string

      write_output = StringIO.new
      payload = Hive::Commands::Answer.new(
        SLUG, project: "demo", binding: inventory_payload.dig("slots", 0, "binding"),
        input: StringIO.new("plain text"), output: write_output
      ).call
      assert_equal "written", payload.fetch("outcome")
      assert_equal "#{payload.fetch('acknowledgement')}\n", write_output.string
    end
  end

  def test_error_kinds_flow_through_json_error_envelopes
    errors = {
      "ambiguous_slug" => Hive::AmbiguousSlug.new("ambiguous", slug: SLUG, candidates: []),
      "invalid_task_path" => Hive::InvalidTaskPath.new("invalid"),
      "config" => Hive::ConfigError.new("config")
    }

    errors.each do |kind, error|
      output = StringIO.new
      command = Hive::Commands::Answer.new(SLUG, json: true, output: output)
      command.define_singleton_method(:inventory_payload) { raise error }
      assert_raises(error.class) { command.call }
      payload = JSON.parse(output.string)
      assert_equal kind, payload.fetch("error_kind")
      assert_schema(payload)
    end
  end

  def test_wrong_stage_flows_end_to_end_through_the_error_schema
    with_project do |_project, folder, _path|
      destination = folder.sub("2-brainstorm", "3-plan")
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(folder, destination)
      output = StringIO.new

      error = assert_raises(Hive::WrongStage) do
        Hive::Commands::Answer.new(SLUG, project: "demo", json: true, output: output).call
      end
      payload = JSON.parse(output.string)
      assert_equal Hive::ExitCodes::WRONG_STAGE, error.exit_code
      assert_equal "wrong_stage", payload.fetch("error_kind")
      assert_schema(payload)
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
