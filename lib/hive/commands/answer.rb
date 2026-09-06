# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "stringio"
require "hive/attempts/generation"
require "hive/bot/brainstorm_answer_writer"
require "hive/brainstorm_parser"
require "hive/brainstorm_suggestions/projection"
require "hive/config"
require "hive/lock"
require "hive/task_meta"
require "hive/task_resolver"
require "hive/task_activity"
require "hive/workflows"

module Hive
  module Commands
    # Inventory and atomically answer one exact brainstorm slot. Recommendation
    # policy deliberately lives outside this literal boundary; callers supply a
    # final answer through stdin only after choosing it.
    class Answer
      SCHEMA = "hive-answer"
      STAGE_DIR = "2-brainstorm" # coding-scoped: literal answer boundary only accepts coding brainstorm tasks
      BINDING_VERSION = 1
      MAX_BINDING_BYTES = 8 * 1024
      MAX_ANSWER_BYTES = 64 * 1024
      BINDING_KEYS = %w[
        version project task_id task_slug task_folder stage task_generation
        ordinal round question_number question_fingerprint
      ].freeze

      class InvalidBinding < Hive::UsageError; end
      class InvalidAnswer < Hive::UsageError; end

      def self.inventory(target, project: nil)
        new(target, project: project, output: StringIO.new).call
      end

      def self.write(target, project: nil, binding:, answer:)
        if binding.to_s.empty?
          raise InvalidBinding, "brainstorm answer binding is required for writes"
        end

        new(
          target,
          project: project,
          binding: binding,
          input: StringIO.new(answer.to_s),
          output: StringIO.new
        ).call
      end

      def initialize(target, project: nil, binding: nil, json: false,
                     input: $stdin, output: $stdout)
        @target = target.to_s
        @project_filter = project
        @binding_token = binding.to_s
        @json = json
        @input = input
        @output = output
      end

      def call
        payload = @binding_token.empty? ? inventory_payload : mutation_payload
        emit(payload)
        payload
      rescue Hive::Error => e
        emit_error(e) if @json
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error(wrapped) if @json
        raise wrapped
      end

      private

      def inventory_payload
        task = resolve_task(@target, @project_filter)
        validate_brainstorm_stage!(task)
        project = registered_project_name!(task)
        generation = task_generation(task, project)
        content = read_brainstorm!(task)
        questions = Hive::BrainstormParser.parse_text(content)
        suggestion_config = Hive::Config.load(task.project_root).dig("brainstorm", "suggestions")
        suggestions = if suggestion_config&.fetch("enabled", false)
          Hive::BrainstormSuggestions::Projection.call(
            task_root: task.folder,
            project_root: task.project_root,
            questions: questions,
            task_generation: generation,
            enabled: true
          )
        else
          {}
        end

        # A second identity observation catches a stage move or task replacement
        # during the lock-free, strictly read-only inventory path. A concurrent
        # answer may still make one slot stale after this point; mutation always
        # revalidates it under the lock.
        observed = resolve_task((task.id || task.slug).to_s, project)
        validate_brainstorm_stage!(observed)
        unless same_task_path?(task, observed) && task_generation(observed, project) == generation
          raise Hive::StaleOperationalObservation,
                "task changed while brainstorm answers were inventoried; retry"
        end

        slots = questions.each_with_index.map do |question, index|
          slot_payload(
            question,
            ordinal: index + 1,
            suggestion: suggestions[index + 1],
            binding: encode_binding(binding_payload(
              task: task, project: project, generation: generation,
              question: question, ordinal: index + 1
            ))
          )
        end
        unanswered = questions.count { |question| !question.answered? }
        {
          "schema" => SCHEMA,
          "schema_version" => schema_version,
          "ok" => true,
          "operation" => "inventory",
          "task" => task_payload(task, project, generation),
          "slot_count" => slots.length,
          "unanswered_count" => unanswered,
          "complete" => !slots.empty? && unanswered.zero?,
          "slots" => slots
        }
      end

      def mutation_payload
        binding = decode_binding(@binding_token)
        answer_text = read_answer!
        return write_outcome(binding, outcome: "stale", reason: "identity_changed") unless
          invocation_matches_binding?(binding)

        observation = observe_bound_task(binding)
        return write_outcome(binding, **observation) unless observation.fetch(:task, nil)

        task = observation.fetch(:task)
        @answer_activity = Hive::TaskActivity.for_task(task)
        reconcile_answer_operations(@answer_activity, task)
        begin
          Hive::Lock.with_task_lock(
            task.folder,
            { slug: task.slug, stage: STAGE_DIR, op: "brainstorm_answer" },
            create: false
          ) do
            mutate_under_lock(binding, answer_text, task)
          end
        rescue Hive::ConcurrentRunError
          write_outcome(binding, outcome: "lock_busy", reason: "task_lock_busy")
        rescue Errno::ENOENT
          write_outcome(binding, outcome: "stale", reason: "task_moved")
        end
      end

      def mutate_under_lock(binding, answer_text, observed_task)
        current = observe_bound_task(binding)
        return write_outcome(binding, **current) unless current.fetch(:task, nil)

        task = current.fetch(:task)
        return write_outcome(binding, outcome: "stale", reason: "task_moved") unless
          same_task_path?(observed_task, task)

        generation = task_generation(task, binding.fetch("project"))
        unless generation == binding.fetch("task_generation")
          return write_outcome(binding, outcome: "stale", reason: "generation_changed")
        end

        questions = Hive::BrainstormParser.parse_text(read_brainstorm!(task))
        resolution = resolve_bound_slot(binding, questions, answer_text)
        unless resolution.fetch(:write, false)
          return write_outcome(
            binding,
            outcome: resolution.fetch(:outcome),
            reason: resolution.fetch(:reason),
            task: task,
            generation: generation,
            questions: questions,
            slot: resolution[:slot],
            ordinal: resolution[:ordinal],
            relocated: resolution.fetch(:relocated, false),
            answer_text: answer_text
          )
        end

        @answer_operation = begin_answer_operation(
          task, binding, resolution.fetch(:ordinal), answer_text
        )
        result = Hive::Bot::BrainstormAnswerWriter.write_at_ordinal_under_lock!(
          brainstorm_path: task.state_file,
          ordinal: resolution.fetch(:ordinal),
          answer_text: answer_text
        )
        unless result == :written
          return writer_no_write_outcome(
            binding, result, task, generation, resolution, answer_text
          )
        end

        updated = Hive::BrainstormParser.parse_text(read_brainstorm!(task))
        slot = updated.fetch(resolution.fetch(:ordinal) - 1)
        complete_answer_operation(
          @answer_operation, task, binding, resolution.fetch(:ordinal), answer_text
        )
        write_outcome(
          binding,
          outcome: "written",
          reason: resolution.fetch(:relocated) ? "unique_relocation" : "exact_match",
          task: task,
          generation: generation,
          questions: updated,
          slot: slot,
          ordinal: resolution.fetch(:ordinal),
          relocated: resolution.fetch(:relocated),
          answer_text: answer_text
        )
      rescue Hive::InvalidTaskPath
        write_outcome(binding, outcome: "stale", reason: "task_missing")
      end

      def begin_answer_operation(task, binding, ordinal, answer_text)
        return nil unless @answer_activity

        @answer_activity.begin_operation(
          kind: "answer_recorded",
          operation_id: "answer:#{binding.fetch('question_fingerprint')}:#{ordinal}",
          source: "command_service", reason: "brainstorm answer recorded",
          precondition: answer_precondition(binding),
          expected_postcondition: answer_postcondition(binding, answer_text)
        )
      end

      def complete_answer_operation(operation, task, binding, ordinal, answer_text)
        return unless operation

        result = answer_postcondition(binding, answer_text)
        operation.complete!(
          result: result,
          payload: {
            "question_id" => "Q#{ordinal}",
            "answer_id" => result.fetch("answer_fingerprint")[0, 16]
          }
        )
      end

      def reconcile_answer_operations(activity, task)
        return unless activity

        questions = Hive::BrainstormParser.parse_text(read_brainstorm!(task))
        postconditions = questions.filter_map do |question|
          next unless question.answered?

          value = {
            "question_fingerprint" => question_fingerprint(question),
            "answer_fingerprint" => answer_fingerprint(question.answer)
          }
          [ Hive::TaskActivity.fingerprint(value), value ]
        end.to_h
        preconditions = questions.reject(&:answered?).map do |question|
          Hive::TaskActivity.fingerprint(
            "question_fingerprint" => question_fingerprint(question),
            "answered" => false
          )
        end
        activity.reconcile_operations! do |receipt|
          next :defer unless receipt["activity_kind"] == "answer_recorded" &&
            receipt["source"] == "command_service"

          if (value = postconditions[receipt["expected_postcondition_fingerprint"]])
            { status: :committed, result: value }
          elsif preconditions.include?(receipt["precondition_fingerprint"])
            :not_committed
          else
            :ambiguous
          end
        end
      rescue Hive::TaskActivity::Error, Hive::InvalidTaskPath, SystemCallError, IOError
        nil
      end

      def answer_precondition(binding)
        {
          "question_fingerprint" => binding.fetch("question_fingerprint"),
          "answered" => false
        }
      end

      def answer_postcondition(binding, answer_text)
        {
          "question_fingerprint" => binding.fetch("question_fingerprint"),
          "answer_fingerprint" => answer_fingerprint(answer_text)
        }
      end

      def answer_fingerprint(answer)
        Digest::SHA256.hexdigest(canonical_answer(answer))
      end

      def resolve_bound_slot(binding, questions, answer_text)
        ordinal = binding.fetch("ordinal")
        direct = questions[ordinal - 1]
        if exact_bound_slot?(direct, binding)
          return occupied_resolution(direct, ordinal, answer_text, relocated: false) if direct.answered?

          return { write: true, slot: direct, ordinal: ordinal, relocated: false }
        end

        matches = questions.each_with_index.select do |question, _index|
          question_fingerprint(question) == binding.fetch("question_fingerprint")
        end
        unanswered_matches = matches.reject { |question, _index| question.answered? }
        if unanswered_matches.length > 1
          return { outcome: "ambiguous", reason: "multiple_matches", relocated: false }
        end
        if unanswered_matches.one?
          question, index = unanswered_matches.first
          return { write: true, slot: question, ordinal: index + 1, relocated: true }
        end
        if matches.one?
          question, index = matches.first
          return occupied_resolution(question, index + 1, answer_text, relocated: true)
        end
        if matches.length > 1
          return { outcome: "ambiguous", reason: "multiple_matches", relocated: false }
        end

        reason = direct ? "question_changed" : "question_missing"
        { outcome: "stale", reason: reason, relocated: false }
      end

      def occupied_resolution(question, ordinal, answer_text, relocated:)
        if canonical_answer(question.answer) == canonical_answer(answer_text)
          {
            outcome: "idempotent", reason: "already_answered_same",
            slot: question, ordinal: ordinal, relocated: relocated
          }
        else
          {
            outcome: "conflict", reason: "already_answered_different",
            slot: question, ordinal: ordinal, relocated: relocated
          }
        end
      end

      def writer_no_write_outcome(binding, result, task, generation, resolution, answer_text)
        questions = Hive::BrainstormParser.parse_text(read_brainstorm!(task))
        ordinal = resolution.fetch(:ordinal)
        slot = questions[ordinal - 1]
        if result == :already_answered && slot&.answered?
          occupied = occupied_resolution(slot, ordinal, answer_text, relocated: resolution.fetch(:relocated))
          return write_outcome(
            binding,
            outcome: occupied.fetch(:outcome),
            reason: occupied.fetch(:reason),
            task: task,
            generation: generation,
            questions: questions,
            slot: slot,
            ordinal: ordinal,
            relocated: resolution.fetch(:relocated),
            answer_text: answer_text
          )
        end

        return write_outcome(
          binding,
          outcome: "stale",
          reason: "question_missing",
          task: task,
          generation: generation,
          questions: questions,
          relocated: resolution.fetch(:relocated),
          answer_text: answer_text
        ) if result == :question_not_found

        raise Hive::InternalError, "brainstorm answer writer returned #{result.inspect}"
      end

      def exact_bound_slot?(question, binding)
        question &&
          question.round == binding.fetch("round") &&
          question.n == binding.fetch("question_number") &&
          question_fingerprint(question) == binding.fetch("question_fingerprint")
      end

      def observe_bound_task(binding)
        target = binding["task_id"] || binding.fetch("task_slug")
        task = resolve_task(target.to_s, binding.fetch("project"))
        return { outcome: "stale", reason: "identity_changed" } unless
          task.slug == binding.fetch("task_slug") && task.id == binding["task_id"]
        return { outcome: "stale", reason: "task_moved" } unless task_stage(task) == STAGE_DIR
        return { outcome: "stale", reason: "identity_changed" } unless coding_task?(task)
        return { outcome: "stale", reason: "task_moved" } unless
          canonical_path(task.folder) == binding.fetch("task_folder")

        { task: task }
      rescue Hive::InvalidTaskPath, Hive::AmbiguousSlug
        { outcome: "stale", reason: "task_missing" }
      rescue Errno::ENOENT, Errno::ENOTDIR
        { outcome: "stale", reason: "task_moved" }
      end

      def invocation_matches_binding?(binding)
        return false if @project_filter && @project_filter != binding.fetch("project")

        [
          binding.fetch("task_slug"),
          binding["task_id"]&.to_s,
          binding.fetch("task_folder")
        ].compact.include?(@target) || canonical_invocation_path == binding.fetch("task_folder")
      end

      def canonical_invocation_path
        return unless @target.include?("/") || @target.start_with?("~", ".")

        canonical_path(@target)
      rescue SystemCallError
        nil
      end

      def binding_payload(task:, project:, generation:, question:, ordinal:)
        {
          "version" => BINDING_VERSION,
          "project" => project,
          "task_id" => task.id,
          "task_slug" => task.slug,
          "task_folder" => canonical_path(task.folder),
          "stage" => STAGE_DIR,
          "task_generation" => generation,
          "ordinal" => ordinal,
          "round" => question.round,
          "question_number" => question.n,
          "question_fingerprint" => question_fingerprint(question)
        }
      end

      def encode_binding(payload)
        Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
      end

      def decode_binding(token)
        unless token.bytesize.between?(1, MAX_BINDING_BYTES) && token.match?(/\A[A-Za-z0-9_-]+\z/)
          raise InvalidBinding, "brainstorm answer binding is malformed"
        end

        decoded = Base64.urlsafe_decode64(token)
        payload = JSON.parse(decoded)
        unless payload.is_a?(Hash) && payload.keys.sort == BINDING_KEYS.sort &&
               payload["version"] == BINDING_VERSION &&
               payload["stage"] == STAGE_DIR &&
               payload["project"].is_a?(String) && !payload["project"].empty? &&
               payload["task_slug"].is_a?(String) && !payload["task_slug"].empty? &&
               (payload["task_id"].nil? ||
                 (payload["task_id"].is_a?(Integer) && payload["task_id"].positive?)) &&
               payload["task_folder"].is_a?(String) && !payload["task_folder"].empty? &&
               payload["task_generation"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               payload["ordinal"].is_a?(Integer) && payload["ordinal"].positive? &&
               (payload["round"].nil? ||
                 (payload["round"].is_a?(Integer) && payload["round"].positive?)) &&
               payload["question_number"].is_a?(Integer) && payload["question_number"].positive? &&
               payload["question_fingerprint"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               encode_binding(payload) == token
          raise InvalidBinding, "brainstorm answer binding has an unsupported shape"
        end

        payload
      rescue JSON::ParserError, ArgumentError
        raise InvalidBinding, "brainstorm answer binding is malformed"
      end

      # Attempts::Generation normally hashes the mutable state artifact. That is
      # correct for stage execution, but an answer binding must survive its own
      # successful write and harmless Q/A renumbering. Feed the shared generation
      # resolver a stable incarnation token instead: task identity, immutable
      # input fingerprint when present, directory inode, and task-input epoch.
      # A replacement folder/input epoch therefore changes generation while
      # answer bodies and headings do not.
      def task_generation(task, project)
        metadata = Hive::TaskMeta.read(task.folder)
        stat = File.stat(task.folder)
        input_epoch = Hive::Attempts::Generation.current_task_input_epoch(task)
        incarnation = Digest::SHA256.hexdigest(
          [
            "hive-brainstorm-answer-incarnation-v1",
            task.id, task.slug, metadata[:input_fingerprint],
            stat.dev, stat.ino, input_epoch
          ].join("\0")
        )
        Hive::Attempts::Generation.resolve(
          task: task,
          project: project,
          intended_stage: STAGE_DIR,
          progress_token: incarnation,
          task_input_epoch: input_epoch
        ).ownership_generation
      rescue Hive::TaskProjection::InvalidJournal, SystemCallError, IOError => e
        raise Hive::InvalidTaskPath,
              "cannot establish stable brainstorm task generation: #{e.class}: #{e.message}"
      end

      def read_answer!
        answer = @input.read(MAX_ANSWER_BYTES + 1).to_s
        if answer.bytesize > MAX_ANSWER_BYTES
          raise InvalidAnswer, "brainstorm answer exceeds #{MAX_ANSWER_BYTES} bytes"
        end
        answer = answer.dup.force_encoding(Encoding::UTF_8)
        unless answer.valid_encoding?
          raise InvalidAnswer, "brainstorm answer must be valid UTF-8"
        end
        if canonical_answer(answer).empty?
          raise InvalidAnswer, "brainstorm answer must not be empty"
        end

        answer.gsub("\r\n", "\n").gsub("\r", "\n").rstrip
      end

      def canonical_answer(answer)
        answer.to_s.scrub.gsub("\r\n", "\n").gsub("\r", "\n").strip
      end

      def read_brainstorm!(task)
        File.read(task.state_file, encoding: "UTF-8").scrub
      rescue Errno::ENOENT, Errno::EACCES, IOError => e
        raise Hive::InvalidTaskPath,
              "cannot read brainstorm state for #{task.slug}: #{e.class}: #{e.message}"
      end

      def resolve_task(target, project)
        Hive::TaskResolver.new(target, project_filter: project).resolve
      end

      def registered_project_name!(task)
        entry = Hive::Config.registered_projects.find do |project|
          canonical_path(project.fetch("path")) == canonical_path(task.project_root)
        end
        raise Hive::InvalidTaskPath, "task is not in a registered project" unless entry

        entry.fetch("name")
      end

      def validate_brainstorm_stage!(task)
        if !coding_task?(task)
          raise Hive::WrongStage.new(
            "brainstorm answers require the coding workflow; task uses #{task.workflow.id}",
            current_stage: task_stage(task), target_stage: STAGE_DIR
          )
        end
        return if task_stage(task) == STAGE_DIR

        raise Hive::WrongStage.new(
          "brainstorm answers require #{STAGE_DIR}; task is at #{task_stage(task)}",
          current_stage: task_stage(task), target_stage: STAGE_DIR
        )
      end

      def task_stage(task)
        "#{task.stage_index}-#{task.stage_name}"
      end

      def coding_task?(task)
        Hive::Workflows.coding_id?(task.workflow.id)
      end

      def task_payload(task, project, generation)
        {
          "project" => project,
          "id" => task.id,
          "slug" => task.slug,
          "stage" => task_stage(task),
          "folder" => canonical_path(task.folder),
          "generation" => generation
        }
      end

      def task_payload_from_binding(binding)
        {
          "project" => binding.fetch("project"),
          "id" => binding["task_id"],
          "slug" => binding.fetch("task_slug"),
          "stage" => binding.fetch("stage"),
          "folder" => binding.fetch("task_folder"),
          "generation" => binding.fetch("task_generation")
        }
      end

      def slot_payload(question, ordinal:, binding: nil, suggestion: nil)
        {
          "ordinal" => ordinal,
          "round" => question.round,
          "question_number" => question.n,
          "text" => question.text,
          "answered" => question.answered?,
          "answer" => question.answer,
          "fingerprint" => question_fingerprint(question),
          "binding" => binding,
          "suggestion" => suggestion
        }
      end

      def write_outcome(binding, outcome:, reason:, task: nil, generation: nil,
                        questions: nil, slot: nil, ordinal: nil, relocated: false,
                        answer_text: nil)
        unanswered = questions&.count { |question| !question.answered? }
        slot_binding = if task && slot && generation
          encode_binding(binding_payload(
            task: task,
            project: binding.fetch("project"),
            generation: generation,
            question: slot,
            ordinal: ordinal
          ))
        end
        {
          "schema" => SCHEMA,
          "schema_version" => schema_version,
          "ok" => true,
          "operation" => "write",
          "outcome" => outcome,
          "reason" => reason,
          "written" => outcome == "written",
          "relocated" => relocated,
          "task" => task ? task_payload(task, binding.fetch("project"), generation) :
                           task_payload_from_binding(binding),
          "slot" => slot && ordinal ? slot_payload(slot, ordinal: ordinal, binding: slot_binding) : nil,
          "unanswered_count" => unanswered,
          "complete" => questions ? (!questions.empty? && unanswered.zero?) : nil,
          "acknowledgement" => acknowledgement(
            outcome, ordinal: ordinal || binding.fetch("ordinal"),
            total: questions&.length, answer_text: answer_text
          )
        }
      end

      def acknowledgement(outcome, ordinal:, total:, answer_text:)
        label = total ? "Q#{ordinal}/#{total}" : "Q#{ordinal}"
        case outcome
        when "written"
          summary = Hive::BrainstormParser.normalize_question_text(answer_text)[0, 120]
          "Recorded #{label}: #{summary}"
        when "idempotent" then "#{label} already records that answer."
        when "conflict" then "#{label} already has a different answer; nothing changed."
        when "ambiguous" then "Multiple unanswered questions match #{label}; nothing changed."
        when "lock_busy" then "#{label} is locked by another Hive operation; retry later."
        else "#{label} is stale; refresh the brainstorm inventory."
        end
      end

      def question_fingerprint(question)
        Hive::BrainstormParser.question_fingerprint(question.text)
      end

      def canonical_path(path)
        File.realpath(File.expand_path(path))
      end

      def same_task_path?(left, right)
        canonical_path(left.folder) == canonical_path(right.folder)
      rescue SystemCallError
        false
      end

      def schema_version
        Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA)
      end

      def emit(payload)
        if @json
          @output.puts JSON.generate(payload)
        elsif payload.fetch("operation") == "inventory"
          @output.puts "#{payload.dig('task', 'project')}/#{payload.dig('task', 'slug')}: " \
                       "#{payload.fetch('unanswered_count')}/#{payload.fetch('slot_count')} unanswered"
        else
          @output.puts payload.fetch("acknowledgement")
        end
      end

      def emit_error(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: SCHEMA,
          error: error,
          error_kind: error_kind(error)
        )
        @output.puts JSON.generate(payload)
      end

      def error_kind(error)
        case error
        when InvalidBinding then "invalid_binding"
        when InvalidAnswer then "invalid_answer"
        when Hive::WrongStage then "wrong_stage"
        when Hive::StaleOperationalObservation then "stale"
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConfigError then "config"
        else "internal"
        end
      end
    end
  end
end
