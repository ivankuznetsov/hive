require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "hive/context_provenance/context_receipt"
require "hive/context_provenance/repository_snapshot"
require "hive/context_provenance/wiki_snapshot"
require "hive/task_activity"

module Hive
  # Forward-only capture of the repository, managed-Wiki, and selected-context
  # identity associated with one durable attempt. Historical receipts are
  # immutable; current observations are returned separately and never backfill
  # old attempts.
  module ContextProvenance
    MAX_RECEIPT_BYTES = 64 * 1024
    MAX_PROMPT_APPENDIX_BYTES = 4 * 1024
    RECEIPT_DIRECTORY = "context-receipts".freeze
    PromotionResult = Data.define(:status, :receipt, :reason, :diagnostics)

    module_function

    def capture_launch(task:, attempt:, generation: nil, activity: nil,
                       attempt_store: nil, clock: -> { Time.now.utc })
      existing_reference = launch_reference(attempt.attempt_id)
      if safe_file?(task.folder, existing_reference)
        return read_json_nofollow(
          task.folder, existing_reference, max_bytes: MAX_RECEIPT_BYTES
        )
      end
      captured_at = normalize_time(clock.call)
      receipt = launch_receipt(
        task: task, attempt: attempt, generation: generation,
        captured_at: captured_at
      )
      persisted = write_immutable(
        task.folder, launch_reference(attempt.attempt_id), receipt
      )
      record_activity(
        activity || activity_for(task, attempt, attempt_store: attempt_store, clock: clock),
        kind: "context_launch_captured",
        operation_id: "context-launch:#{attempt.attempt_id}",
        reason: "controller captured launch context",
        occurred_at: persisted.fetch("captured_at"),
        evidence: [
          { "kind" => "controller_receipt", "reference" => launch_reference(attempt.attempt_id) }
        ],
        payload: {
          "quality" => "observed_at_launch",
          "repository_state" => persisted.dig("repository", "state"),
          "wiki_state" => persisted.dig("wiki", "state")
        }
      )
      persisted
    rescue StandardError => e
      # Provenance is advisory evidence. Attempt handoff remains authoritative
      # and must not be stranded by a capture or journal failure.
      partial_launch_receipt(task: task, attempt: attempt, generation: generation,
                             captured_at: captured_at || normalize_time(clock.call), error: e)
    end

    def observe_current(task:, clock: -> { Time.now.utc })
      {
        "observed_at" => normalize_time(clock.call),
        "repository" => RepositorySnapshot.capture(task.project_root),
        "wiki" => WikiSnapshot.capture(task.project_root)
      }
    end

    def decorate_prompt(task:, prompt:, context:)
      return prompt unless compatible_context?(task, context)

      appendix = prompt_appendix(task, context)
      raise ArgumentError, "context receipt prompt appendix exceeds byte budget" if
        appendix.bytesize > MAX_PROMPT_APPENDIX_BYTES

      "#{prompt.rstrip}\n\n#{appendix}"
    rescue ArgumentError
      prompt
    end

    def promote_agent_receipt(task:, context:, activity: nil,
                              clock: -> { Time.now.utc })
      return result(:unavailable, reason: "attempt_context_unavailable") unless
        compatible_context?(task, context)

      final_ref = promoted_reference(context.attempt_id)
      candidate_ref = candidate_reference(context.attempt_id)
      if safe_file?(task.folder, final_ref) && !safe_file?(task.folder, candidate_ref)
        receipt = read_json_nofollow(task.folder, final_ref, max_bytes: MAX_RECEIPT_BYTES)
        return result(:already_promoted, receipt: receipt)
      end
      return result(:missing, reason: "receipt_not_provided") unless
        safe_file?(task.folder, candidate_ref)

      candidate = read_json_nofollow(task.folder, candidate_ref, max_bytes: MAX_RECEIPT_BYTES)
      receipt = ContextReceipt.validate_agent!(candidate, task: task, context: context)
      persisted = write_immutable(task.folder, final_ref, receipt)
      remove_candidate(task.folder, candidate_ref)
      record_activity(
        activity || activity_for_context(task, context, clock: clock),
        kind: "context_selection_reported",
        operation_id: "context-selection:#{context.attempt_id}",
        reason: "agent asserted selected context",
        occurred_at: persisted.fetch("captured_at"),
        evidence: [ { "kind" => "agent_receipt", "reference" => final_ref } ],
        payload: {
          "quality" => "agent_asserted_used",
          "reference_count" => persisted.dig("selection", "references").length,
          "query_count" => persisted.dig("selection", "queries").length
        }
      )
      result(:promoted, receipt: persisted)
    rescue ContextReceipt::InvalidReceipt => e
      result(:rejected, reason: "invalid_receipt", diagnostics: [ safe_error(e) ])
    rescue JSON::ParserError => e
      result(:rejected, reason: "invalid_json", diagnostics: [ safe_error(e) ])
    rescue ReceiptTooLarge => e
      result(:rejected, reason: "receipt_too_large", diagnostics: [ safe_error(e) ])
    rescue UnsafeReceipt => e
      result(:rejected, reason: e.reason, diagnostics: [ safe_error(e) ])
    rescue StandardError => e
      result(:unavailable, reason: "receipt_promotion_failed", diagnostics: [ safe_error(e) ])
    end

    class ReceiptTooLarge < Hive::Error; end
    class UnsafeReceipt < Hive::Error
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason)
      end
    end

    def launch_receipt(task:, attempt:, generation:, captured_at:)
      repository = RepositorySnapshot.capture(task.project_root)
      wiki = WikiSnapshot.capture(task.project_root)
      {
        "schema" => "hive-context-receipt",
        "schema_version" => 1,
        "kind" => "controller_launch",
        "binding" => binding_for(task, attempt, generation: generation),
        "captured_at" => captured_at,
        "quality" => "observed_at_launch",
        "repository" => repository,
        "wiki" => wiki,
        "selection" => nil,
        "diagnostics" => repository.fetch("diagnostics") + wiki.fetch("diagnostics")
      }
    end

    def partial_launch_receipt(task:, attempt:, generation:, captured_at:, error:)
      receipt = {
        "schema" => "hive-context-receipt", "schema_version" => 1,
        "kind" => "controller_launch",
        "binding" => binding_for(task, attempt, generation: generation),
        "captured_at" => captured_at, "quality" => "observed_at_launch",
        "repository" => RepositorySnapshot.unavailable(error.class.name),
        "wiki" => WikiSnapshot.unavailable(error.class.name), "selection" => nil,
        "diagnostics" => [ { "code" => "launch_capture_failed", "detail" => error.class.name } ]
      }
      write_immutable(task.folder, launch_reference(attempt.attempt_id), receipt)
    rescue StandardError
      receipt
    end

    def binding_for(task, attempt, generation: nil)
      task_generation = if attempt.respond_to?(:task_input_epoch)
        attempt.task_input_epoch
      else
        generation&.task_generation || 0
      end
      ownership_generation = if attempt.respond_to?(:ownership_generation)
        attempt.ownership_generation&.to_s
      else
        generation&.ownership_generation&.to_s
      end
      {
        "project" => attempt["project"].to_s,
        "task_slug" => attempt["task_slug"].to_s,
        "task_id" => attempt["task_id"]&.to_s,
        "stage" => attempt["intended_stage"].to_s,
        "attempt_id" => attempt.attempt_id.to_s,
        "task_generation" => task_generation,
        "ownership_generation" => ownership_generation
      }
    end

    def activity_for(task, attempt, attempt_store:, clock:)
      Hive::TaskActivity.new(
        task_folder: task.folder,
        task: { "id" => task.id, "slug" => task.slug },
        workflow: workflow_id(task), stage: attempt["intended_stage"],
        attempt_id: attempt.attempt_id,
        task_generation: attempt.task_input_epoch,
        ownership_generation: attempt.ownership_generation,
        attempt_store: attempt_store, clock: clock
      )
    end

    def activity_for_context(task, context, clock:)
      Hive::TaskActivity.for_context(task, context: context, clock: clock)
    end

    def workflow_id(task)
      workflow = task.respond_to?(:workflow) ? task.workflow : nil
      value = workflow.respond_to?(:id) ? workflow.id : workflow
      value.to_s.empty? ? "coding" : value.to_s
    end

    def record_activity(activity, **attributes)
      activity&.record(source: "context_provenance", **attributes)
    rescue StandardError
      nil
    end

    def compatible_context?(task, context)
      return false unless context && task.respond_to?(:folder) && task.respond_to?(:project_root)

      context.task_slug.to_s == task.slug.to_s &&
        (context.project.to_s.empty? || context.project.to_s == ContextReceipt.task_project(task))
    end

    def prompt_appendix(task, context)
      example = {
        "schema" => "hive-context-receipt", "schema_version" => 1,
        "kind" => "agent_selection",
        "binding" => {
          "project" => context.project, "task_slug" => context.task_slug,
          "task_id" => task.id&.to_s, "stage" => context.intended_stage,
          "attempt_id" => context.attempt_id,
          "task_generation" => context.task_generation,
          "ownership_generation" => context.ownership_generation
        },
        "captured_at" => "REPLACE_WITH_ISO_8601_TIME",
        "quality" => "agent_asserted_used", "repository" => nil, "wiki" => nil,
        "selection" => { "references" => [], "queries" => [], "rationale" => "..." },
        "diagnostics" => []
      }
      <<~APPENDIX.rstrip
        ## Optional context provenance receipt

        This receipt is optional and does not change the required stage artifact, outcome, or terminal marker.
        If you select repository or Wiki context for this attempt, write one JSON object to the task-relative path
        `#{candidate_reference(context.attempt_id)}` (maximum #{MAX_RECEIPT_BYTES} bytes) before exiting.
        Start from this exact shape (replace the timestamp, rationale, references, and queries):
        `#{JSON.generate(example)}`
        `selection` contains only project-relative selected references (`path`, `kind`, `label`), bounded
        query/result labels, and a short rationale. Do not include file contents, prompts, argv, credentials,
        tokens, or absolute paths. Hive presents this as an agent assertion, not proof of consumption.
      APPENDIX
    end

    def write_immutable(root, reference, receipt)
      payload = JSON.pretty_generate(receipt) << "\n"
      raise ReceiptTooLarge, "context receipt exceeds #{MAX_RECEIPT_BYTES} bytes" if
        payload.bytesize > MAX_RECEIPT_BYTES

      directory = receipt_directory(root)
      path = File.join(root, reference)
      if File.exist?(path)
        existing = read_json_nofollow(root, reference, max_bytes: MAX_RECEIPT_BYTES)
        return existing if canonical(existing) == canonical(receipt)

        raise UnsafeReceipt, "receipt_conflict"
      end

      temporary = File.join(directory, ".#{File.basename(path)}.#{SecureRandom.hex(8)}.tmp")
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(temporary, flags, 0o600) do |io|
        io.write(payload)
        io.flush
        io.fsync
      end
      File.rename(temporary, path)
      fsync_directory(directory)
      receipt
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end

    def read_json_nofollow(root, reference, max_bytes:)
      path = contained_receipt_path(root, reference)
      before = File.lstat(path)
      raise UnsafeReceipt, "symlink_refused" if before.symlink? || !before.file?
      raise ReceiptTooLarge, "context receipt exceeds #{max_bytes} bytes" if before.size > max_bytes

      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      raw = File.open(path, flags) do |io|
        opened = io.stat
        unless opened.dev == before.dev && opened.ino == before.ino && opened.file?
          raise UnsafeReceipt, "descriptor_changed"
        end
        content = io.read(max_bytes + 1).to_s
        raise ReceiptTooLarge, "context receipt exceeds #{max_bytes} bytes" if content.bytesize > max_bytes
        after = io.stat
        unless after.dev == opened.dev && after.ino == opened.ino &&
               after.size == opened.size && after.mtime == opened.mtime
          raise UnsafeReceipt, "source_changed"
        end
        content
      end
      JSON.parse(raw)
    rescue Errno::ELOOP
      raise UnsafeReceipt, "symlink_refused"
    end

    def remove_candidate(root, reference)
      path = contained_receipt_path(root, reference)
      stat = File.lstat(path)
      raise UnsafeReceipt, "candidate_changed" if stat.symlink? || !stat.file?

      File.delete(path)
      fsync_directory(File.dirname(path))
    rescue Errno::ENOENT
      nil
    end

    def safe_file?(root, reference)
      path = contained_receipt_path(root, reference)
      stat = File.lstat(path)
      stat.file? && !stat.symlink?
    rescue SystemCallError, UnsafeReceipt
      false
    end

    def contained_receipt_path(root, reference)
      directory = receipt_directory(root)
      path = File.expand_path(File.join(root, reference))
      unless path.start_with?("#{directory}#{File::SEPARATOR}")
        raise UnsafeReceipt, "containment_escape"
      end
      path
    end

    def receipt_directory(root)
      expanded = File.realpath(File.expand_path(root))
      directory = File.join(expanded, RECEIPT_DIRECTORY)
      if File.exist?(directory) || File.symlink?(directory)
        stat = File.lstat(directory)
        raise UnsafeReceipt, "symlink_refused" if stat.symlink? || !stat.directory?
      else
        Dir.mkdir(directory, 0o700)
      end
      real = File.realpath(directory)
      unless real == directory && real.start_with?("#{expanded}#{File::SEPARATOR}")
        raise UnsafeReceipt, "containment_escape"
      end
      File.chmod(0o700, directory)
      real
    end

    def launch_reference(attempt_id) = "#{RECEIPT_DIRECTORY}/#{safe_attempt_id(attempt_id)}.launch.json"
    def candidate_reference(attempt_id) = "#{RECEIPT_DIRECTORY}/#{safe_attempt_id(attempt_id)}.json.next"
    def promoted_reference(attempt_id) = "#{RECEIPT_DIRECTORY}/#{safe_attempt_id(attempt_id)}.json"

    def safe_attempt_id(value)
      id = value.to_s
      raise UnsafeReceipt, "invalid_attempt_id" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/)

      id
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
      when Array then value.map { |child| canonical(child) }
      else value
      end
    end

    def result(status, receipt: nil, reason: nil, diagnostics: [])
      PromotionResult.new(
        status: status, receipt: receipt, reason: reason,
        diagnostics: diagnostics.freeze
      )
    end

    def normalize_time(value)
      (value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc).iso8601(6)
    end

    def safe_error(error)
      Hive::SecretPatterns.redact(error.message.to_s)[0, 512]
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY, &:fsync)
    rescue SystemCallError, IOError
      nil
    end
  end
end
