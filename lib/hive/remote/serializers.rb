# frozen_string_literal: true

require "json"
require "hive/remote/protocol"
require "hive/remote/errors"
require "hive/secret_patterns"

module Hive
  module Remote
    class Serializers
      def initialize(project_names:)
        @project_names = project_names
      end

      def provenance(document)
        { "source_schema" => document["schema"], "source_schema_version" => document["schema_version"] }
      end

      def status_row(row, project:)
        dto = row.slice("id", "slug", "stage", "display_name", "workflow", "marker", "action",
          "action_label", "age_seconds", "live_task_lock", "task_generation", "unanswered_questions", "blocked")
        %w[depends_on blocked_by].each do |key|
          dto[key] = row[key] if permitted_reference?(row[key], project)
        end
        dto["unmet_dependencies"] = Array(row["unmet_dependencies"]).filter_map do |entry|
          next unless permitted_reference?(entry["reference"], project) && permitted_reference?(entry["blocked_by"], project)
          entry.slice("reference", "blocked_by", "dependency_stage", "required_gate")
        end
        dto
      end

      def task(document)
        provenance(document).merge(
          "task" => document.fetch("task").slice("project", "id", "slug", "stage", "generation", "workflow", "archived"),
          "status" => document.fetch("status").slice("state", "freshness", "observed_at"),
          "headline" => document.fetch("headline").slice("state", "label"),
          "actions" => []
        )
      end

      def questions(inventory, slots)
        provenance(inventory).merge(
          "task" => inventory.fetch("task").slice("project", "id", "slug", "stage", "generation"),
          "slot_count" => inventory["slot_count"], "unanswered_count" => inventory["unanswered_count"],
          "complete" => inventory["complete"], "slots" => slots
        )
      end

      def log(document)
        document.slice("state", "content", "truncated", "continuation")
      end

      def diff(result)
        document = result.to_h
        {
          "state" => document["state"],
          "sections" => document.fetch("sections", {}).slice("committed", "staged", "unstaged", "untracked"),
          "truncated" => document["truncated"], "invalid_encoding" => document["invalid_encoding"],
          "reason" => document["reason"], "continuation" => nil
        }
      end

      # A command result may include native paths, bindings and suggested shell
      # commands. Acknowledgements expose identity and admission facts only.
      def self.acknowledgement(document)
        receipt = document.fetch("command_receipt").slice("id", "generation", "state")
        result = document.slice("created", "workflow", "queued", "request_id", "outcome", "written",
          "unanswered_count", "complete", "slug", "task_id", "stage")
        task = document["task"]
        if task.is_a?(Hash)
          result["task_id"] = task["id"]
          result["slug"] = task["slug"]
          result["stage"] = task["stage"]
        end
        result["stage"] ||= document["current_stage"]
        result["state"] = document.fetch("state", receipt.fetch("state"))
        result.merge("operation_id" => receipt.fetch("id"), "command_receipt" => receipt)
      end

      # The byte cap applies to the complete JSON envelope, after JSON escaping.
      # Only public content strings are shortened; identity/control fields stay
      # intact, so a bounded result remains usable rather than malformed JSON.
      def self.bound!(data, max_bytes:, instance_id:)
        size = -> { JSON.generate(Protocol.envelope(instance_id: instance_id, data: data)).bytesize }
        return data if size.call <= max_bytes
        data["truncated"] = true
        strings = []
        collect_content(data, strings)
        strings.sort_by { |parent, key| -parent[key].bytesize }.each do |parent, key|
          original = parent[key]
          low, high = 0, original.bytesize
          while low < high
            middle = (low + high + 1) / 2
            parent[key] = original.byteslice(0, middle).to_s.force_encoding(Encoding::UTF_8).scrub("")
            size.call <= max_bytes ? low = middle : high = middle - 1
          end
          parent[key] = original.byteslice(0, low).to_s.force_encoding(Encoding::UTF_8).scrub("")
          return data if size.call <= max_bytes
        end
        raise Error.new(code: "too_large", status: 413, message: "requested limit cannot contain this response")
      end

      def self.collect_content(value, strings)
        case value
        when Hash
          value.each do |key, child|
            if child.is_a?(String) && %w[content text answer committed staged unstaged untracked].include?(key)
              strings << [ value, key ]
            else
              collect_content(child, strings)
            end
          end
        when Array
          value.each { |child| collect_content(child, strings) }
        end
      end
      private_class_method :collect_content

      private

      def permitted_reference?(reference, project)
        return true if reference.nil?
        value = reference.to_s
        parts = value.split(":", -1)
        return false unless parts.length.between?(1, 2) && parts.all? { |part| part.match?(/\A[A-Za-z0-9_.-]+\z/) }
        @project_names.include?(parts.length == 2 ? parts.first : project)
      end
    end
  end
end
