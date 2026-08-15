require "hive/task_workspace"

module Hive
  module TaskWorkspace
    # Reads only the task's known workflow artifacts. Every file has its own
    # descriptor-backed ceiling and all files share one aggregate budget, so a
    # growing or hostile artifact cannot turn the task page into an unbounded
    # filesystem read.
    class Artifacts
      def initialize(task_root:, references:, limits: Limits.new, reader: nil)
        @task_root = task_root
        @references = Array(references).map(&:to_s)
        @limits = limits
        @reader = reader || BoundedReader.new(root: task_root)
      end

      def call
        diagnostics = []
        records = []
        budget = BoundedReader::Budget.new(@limits.fetch(:artifact_total_bytes))
        present = present_references(diagnostics)
        observed_files = present.length
        if present.length > @limits.fetch(:artifact_files)
          diagnostics << cap_diagnostic(
            "artifact_files", @limits.fetch(:artifact_files), present.length
          )
          present = present.first(@limits.fetch(:artifact_files))
        end

        present.each do |reference|
          records << record_for(reference, budget)
        rescue SourceError => e
          diagnostics << e.diagnostic.merge("reference" => safe_reference(reference))
          break if e.reason == "aggregate_budget_exhausted"
        end

        diagnostics.concat(records.flat_map { |record| record["diagnostics"] })
        truncated = records.any? { |record| record["truncated"] } ||
                    diagnostics.any? { |row| row["reason"] == "limit_exhausted" ||
                                             row["reason"] == "aggregate_budget_exhausted" }
        state = if records.empty? && diagnostics.empty?
          "missing"
        elsif diagnostics.empty? && !truncated
          "current"
        else
          "partial"
        end
        {
          "state" => state,
          "records" => records,
          "diagnostics" => diagnostics.uniq,
          "truncated" => truncated,
          "observed_files" => observed_files,
          "observed_bytes" => budget.consumed
        }
      rescue ArgumentError => e
        {
          "state" => "unavailable", "records" => [], "truncated" => false,
          "observed_files" => 0, "observed_bytes" => 0,
          "diagnostics" => [
            {
              "source" => "artifact", "reason" => "task_root_unavailable",
              "message" => Hive::SecretPatterns.redact(e.class.name), "details" => {}
            }
          ]
        }
      end

      private

      def present_references(diagnostics)
        @references.uniq.filter_map do |reference|
          safe = safe_reference(reference)
          unless safe
            diagnostics << invalid_reference_diagnostic
            next
          end

          path = File.join(@task_root, safe)
          File.lstat(path)
          safe
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        rescue SystemCallError => e
          diagnostics << {
            "source" => "artifact", "reason" => "stat_failed",
            "reference" => safe, "message" => e.class.name, "details" => {}
          }
          nil
        end
      end

      def record_for(reference, budget)
        result = @reader.read(
          reference,
          max_bytes: @limits.fetch(:artifact_bytes),
          budget: budget
        )
        diagnostics = []
        if result.truncated
          diagnostics << {
            "source" => "artifact", "reason" => "limit_exhausted",
            "cap" => "artifact_bytes", "limit" => @limits.fetch(:artifact_bytes),
            "observed" => result.bytes, "reference" => result.evidence_ref,
            "message" => "artifact was truncated", "details" => {}
          }
        end
        if result.binary
          diagnostics << {
            "source" => "artifact", "reason" => "binary_content",
            "reference" => result.evidence_ref, "message" => "binary artifact hidden",
            "details" => { "observed_bytes" => result.bytes }
          }
        elsif result.invalid_encoding
          diagnostics << {
            "source" => "artifact", "reason" => "invalid_encoding_scrubbed",
            "reference" => result.evidence_ref, "message" => "invalid text bytes scrubbed",
            "details" => { "observed_bytes" => result.bytes }
          }
        end
        {
          "name" => result.evidence_ref,
          "reference" => result.evidence_ref,
          "content" => result.binary ? nil : result.content,
          "bytes" => result.bytes,
          "truncated" => result.truncated,
          "invalid_encoding" => result.invalid_encoding,
          "binary" => result.binary,
          "diagnostics" => diagnostics
        }
      end

      def safe_reference(reference)
        value = reference.to_s.tr("\\", "/")
        return nil if value.empty? || value.include?("\0") || value.start_with?("/")
        return nil if value.match?(/\A[A-Za-z]:\//)
        return nil unless value.split("/").none? { |part| part.empty? || part == "." || part == ".." }

        value
      end

      def invalid_reference_diagnostic
        {
          "source" => "artifact", "reason" => "invalid_reference",
          "reference" => "invalid",
          "message" => "artifact reference is not task-relative", "details" => {}
        }
      end

      def cap_diagnostic(cap, limit, observed)
        {
          "source" => "artifact", "reason" => "limit_exhausted",
          "cap" => cap, "limit" => limit, "observed" => observed,
          "message" => "artifact read limit exhausted", "details" => {}
        }
      end
    end
  end
end
