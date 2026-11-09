# frozen_string_literal: true

module Api
  module V1
    class AnswersController < MutationsController
      def create
        project = authorized_project!("answer")
        input = mutation_input!(allowed: %w[handle answer], required: %w[handle answer])
        if input.fetch("answer").bytesize > Hive::Commands::Answer::MAX_ANSWER_BYTES
          raise Hive::Remote::Error.new(code: "too_large", status: 413, message: "answer exceeds the remote limit")
        end
        existing = existing_operation(project)
        _, task = resolve_target!(validate_state: !existing)
        handle = input.fetch("handle")
        binding = existing && operation_projection.answer_binding(existing, handle: handle)
        remote_handle = handle if binding || !existing
        unless binding
          record = handles.resolve(handle: handle, project: project, task: task)
          unless existing
            inventory = read_service.questions(project: project, task: task)
            handles.current!(record: record, inventory: inventory)
          end
          binding = record.fetch("binding")
        end
        result = command_service.answer(project: project, task: task, binding: binding,
          answer: input.fetch("answer"), remote_handle: remote_handle, **command_authority,
          state_reader: ->(current) { Hive::Remote::ReadService.validate_state!(current, allow_missing: false, strict_text: true) })
        case result["outcome"]
        when "stale", "conflict"
          raise Hive::Remote::Error.new(code: "stale", status: 409, message: "resource changed; refresh its inventory")
        when "ambiguous"
          raise Hive::Remote::Error.new(code: "validation", status: 422, message: "remote operation could not be completed")
        when "lock_busy"
          raise Hive::Remote::Error.new(code: "unavailable", status: 503, message: "remote operation could not be completed")
        end
        render_acknowledgement(result)
      end
    end
  end
end
