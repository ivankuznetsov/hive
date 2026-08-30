# frozen_string_literal: true

require "digest"
require "stringio"
require "time"
require "hive/brainstorm_parser"
require "hive/brainstorm_suggestions"
require "hive/commands/brainstorm_suggestion"
require "hive/attempts/generation"
require "hive/brainstorm_suggestions/projection"
require "hive/task"
require "hive/lock"
require "hive/markers"

module Hive
  module Tui
    # Projects canonical sidecar candidates into the external-editor buffer.
    # The lock is held only for projection/reconciliation; never while the
    # editor is open. A lease records the exact pre-open envelope so an editor
    # save can be classified without granting advisory state answer authority.
    module BrainstormSuggestions
      LeaseRegion = Data.define(
        :ordinal, :question_fingerprint, :binding, :text, :source
      )
      Lease = Data.define(:task_root, :file_digest, :regions, :projected_at)
      Result = Data.define(:adopted, :dismissed, :untouched, :stale)

      module_function

      def project!(task_root:, path:, now: Time.now.utc)
        task_root = File.expand_path(task_root)
        return empty_lease(task_root, now) unless brainstorm_path?(task_root, path)

        lease = nil
        Hive::Lock.with_task_lock(
          task_root,
          { op: "tui_brainstorm_suggestion_projection", slug: File.basename(task_root) },
          create: false
        ) do
          store = Hive::BrainstormSuggestions::Store.new(task_root)
          document = store.read
          records = current_records(document, path, task_root: task_root)
          Hive::Markers.with_markers_lock(path, create: false, timeout: 1) do
            original = read_regular(path)
            stripped = Hive::BrainstormSuggestions::Envelope.strip(original).text
            projected, regions = insert_records(stripped, records)
            Hive::Markers.write_atomic(path, projected) unless projected == original
            lease = Lease.new(
              task_root: task_root,
              file_digest: Digest::SHA256.hexdigest(projected.b),
              regions: regions.freeze,
              projected_at: now.utc.iso8601(6)
            )
          end
        end
        lease || empty_lease(task_root, now)
      rescue Hive::ConcurrentRunError, Hive::BrainstormSuggestions::Error,
             SystemCallError, IOError
        empty_lease(task_root, now)
      end

      def reconcile_editor_exit!(task_root:, path:, lease:)
        return Result.new(adopted: 0, dismissed: 0, untouched: 0, stale: 0) unless
          lease.is_a?(Lease) && lease.regions.any?

        task_root = File.expand_path(task_root)
        outcome = { adopted: 0, dismissed: 0, untouched: 0, stale: 0 }
        Hive::Lock.with_task_lock(
          task_root,
          { op: "tui_brainstorm_suggestion_reconcile", slug: File.basename(task_root) },
          create: false
        ) do
          store = Hive::BrainstormSuggestions::Store.new(task_root)
          document = store.read
          changed_store = false
          Hive::Markers.with_markers_lock(path, create: false, timeout: 1) do
            original = read_regular(path)
            content = original.dup
            parsed = Hive::BrainstormParser.parse_text(content)
            lease.regions.each do |region|
              record = document.fetch("records").find do |candidate|
                candidate["ordinal"] == region.ordinal &&
                  candidate["suggestion_binding"] == region.binding
              end
              question = parsed[region.ordinal - 1]
              same_question = question &&
                              Hive::BrainstormParser.question_fingerprint(question.text) ==
                                region.question_fingerprint
              unless record && same_question
                content = remove_binding(content, region.binding)
                outcome[:stale] += 1
                next
              end

              if question.answered?
                content = remove_binding(content, region.binding)
                document["records"].delete(record)
                changed_store = true
                outcome[:adopted] += 1
              elsif envelope_unchanged?(content, region)
                outcome[:untouched] += 1
              else
                record["dismissed"] = true
                record["updated_at"] = Time.now.utc.iso8601(6)
                changed_store = true
                outcome[:dismissed] += 1
              end
            end
            Hive::Markers.write_atomic(path, content) unless content == original
          end
          if changed_store
            document["updated_at"] = Time.now.utc.iso8601(6)
            document.fetch("records").empty? ? store.delete! : store.write(document)
          end
        end
        Result.new(**outcome)
      rescue Hive::ConcurrentRunError, Hive::BrainstormSuggestions::Error,
             SystemCallError, IOError
        Result.new(adopted: 0, dismissed: 0, untouched: 0, stale: 0)
      end

      def restore!(task_root)
        candidate_action(task_root, "restore") do |record|
          record["state"] == "fresh" && record["dismissed"] == true
        end
      end

      def retry!(task_root)
        candidate_action(task_root, "retry") do |record|
          Hive::BrainstormSuggestions::RETRYABLE_STATES.include?(record["state"]) ||
            record["state"] == "stale" || record["state"] == "fresh"
        end
      end

      def current_records(document, path, task_root:)
        return [] if document["corrupt"]

        parsed = Hive::BrainstormParser.parse(path)
        task = Hive::Task.new(task_root)
        projection = Hive::BrainstormSuggestions::Projection.call(
          task_root: task_root,
          project_root: task.project_root,
          questions: parsed,
          task_generation: Hive::Attempts::Generation.current_task_input_epoch(task)
        )
        document.fetch("records").filter_map do |record|
          next unless record["state"] == "fresh" && record["dismissed"] == false
          next unless record["suggestion_binding"].to_s.match?(/\A[0-9a-f]{64}\z/)

          question = parsed[record.fetch("ordinal") - 1]
          next unless question && !question.answered?
          next unless Hive::BrainstormParser.question_fingerprint(question.text) ==
                      record["question_fingerprint"]
          projected = projection[record.fetch("ordinal")]
          next unless projected && projected["state"] == "fresh" &&
                      projected["suggestion_binding"] == record["suggestion_binding"] &&
                      projected["text"] == record["text"]

          record
        end.sort_by { |record| record.fetch("ordinal") }
      end
      private_class_method :current_records

      def envelope_unchanged?(content, lease_region)
        Hive::BrainstormSuggestions::Envelope.regions(content).any? do |current|
          current.binding == lease_region.binding &&
            normalize_editor_text(current.text) == normalize_editor_text(lease_region.text)
        end
      end
      private_class_method :envelope_unchanged?

      def normalize_editor_text(value)
        value.to_s.gsub("\r\n", "\n").lines.map { |line| line.rstrip }.join("\n").rstrip
      end
      private_class_method :normalize_editor_text

      def insert_records(content, records)
        lines = content.lines
        indices = answer_heading_indices(lines)
        indexed_regions = records.filter_map do |record|
          index = indices[record.fetch("ordinal")]
          next unless index

          source = Hive::BrainstormSuggestions::Envelope.render(
            binding: record.fetch("suggestion_binding"), text: record.fetch("text")
          )
          region = LeaseRegion.new(
            ordinal: record.fetch("ordinal"),
            question_fingerprint: record.fetch("question_fingerprint"),
            binding: record.fetch("suggestion_binding"),
            text: record.fetch("text"),
            source: source
          )
          [ region, index + 1 ]
        end
        indexed_regions.sort_by { |_region, index| -index }.each do |region, index|
          if index.positive? && !lines[index - 1].to_s.end_with?("\n")
            lines[index - 1] = "#{lines[index - 1]}\n"
          end
          lines.insert(index, region.source)
        end
        [ lines.join, indexed_regions.map(&:first).sort_by(&:ordinal) ]
      end
      private_class_method :insert_records

      def answer_heading_indices(lines)
        ordinal = 0
        active = nil
        found = {}
        lines.each_with_index do |line, index|
          if Hive::BrainstormParser::QUESTION_RE.match?(line.chomp)
            ordinal += 1
            active = ordinal
          elsif active && Hive::BrainstormParser::ANSWER_RE.match?(line.chomp)
            found[active] ||= index
            active = nil
          elsif Hive::BrainstormParser::ROUND_RE.match?(line.chomp)
            active = nil
          end
        end
        found
      end
      private_class_method :answer_heading_indices

      def remove_binding(content, binding)
        Hive::BrainstormSuggestions::Envelope.regions(content).select do |region|
          region.binding == binding
        end.reduce(content) { |body, region| body.sub(region.source, "") }
      end
      private_class_method :remove_binding

      def candidate_action(task_root, action)
        root = File.expand_path(task_root.to_s)
        document = Hive::BrainstormSuggestions::Store.new(root).read
        record = document.fetch("records").sort_by { |candidate| candidate.fetch("ordinal") }.find do |candidate|
          yield candidate
        end
        return { "status" => "not_found", "operation" => action } unless record

        binding = record["suggestion_binding"]
        return { "status" => "not_found", "operation" => action } unless binding
        Hive::Commands::BrainstormSuggestion.new(
          action,
          target: root,
          task_roots: [ root ],
          question: record.fetch("ordinal"),
          binding: binding,
          json: true,
          output: StringIO.new
        ).call
      rescue Hive::Error, SystemCallError, IOError
        { "status" => "unavailable", "operation" => action }
      end
      private_class_method :candidate_action

      def read_regular(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags) do |file|
          raise IOError, "brainstorm projection target is not a regular file" unless file.stat.file?

          file.read
        end
      end
      private_class_method :read_regular

      def brainstorm_path?(task_root, path)
        File.expand_path(path.to_s) == File.join(task_root, "brainstorm.md") &&
          File.file?(path) && !File.symlink?(path)
      rescue SystemCallError, ArgumentError
        false
      end
      private_class_method :brainstorm_path?

      def empty_lease(task_root, now)
        Lease.new(
          task_root: task_root,
          file_digest: nil,
          regions: [].freeze,
          projected_at: now.utc.iso8601(6)
        )
      end
      private_class_method :empty_lease
    end
  end
end
