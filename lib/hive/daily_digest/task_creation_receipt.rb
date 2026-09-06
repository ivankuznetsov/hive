require "digest"
require "json"
require "time"
require "hive/atomic_file"
require "hive/daily_digest"
require "hive/daily_digest/record"

module Hive
  module DailyDigest
    # Project-local authority for task creation. It is committed with the task
    # candidate so the host-global projector can replay creation without a
    # cross-store transaction or file-time inference.
    module TaskCreationReceipt
      FILENAME = "task-creation.json".freeze
      SCHEMA = "hive-task-creation".freeze
      SCHEMA_VERSION = 1
      class Error < DailyDigest::Error; end
      class InvalidReceipt < Error; end
      class Conflict < Error; end

      module_function

      def write!(task_folder:, project:, task:, workflow:, stage:, created_at: Time.now.utc)
        path = File.join(File.expand_path(task_folder), FILENAME)
        receipt = build(project: project, task: task, workflow: workflow, stage: stage,
                        created_at: created_at)
        if File.file?(path)
          existing = read!(task_folder)
          return existing if canonical(existing) == canonical(receipt)

          raise Conflict, "task creation receipt conflicts with the existing task identity"
        end
        Hive::AtomicFile.write(path, "#{canonical(receipt)}\n", mode: 0o600)
        File.chmod(0o600, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        receipt
      rescue Error
        raise
      rescue SystemCallError, IOError, JSON::GeneratorError => error
        raise Error, "task creation receipt could not be written: #{error.class}: #{error.message}"
      end

      def read!(task_folder)
        path = File.join(File.expand_path(task_folder), FILENAME)
        parse!(File.binread(path))
      rescue Error
        raise
      rescue JSON::ParserError, SystemCallError, IOError => error
        raise InvalidReceipt, "task creation receipt is unavailable: #{error.class}: #{error.message}"
      end

      def parse!(bytes)
        validate!(JSON.parse(bytes))
      rescue JSON::ParserError => error
        raise InvalidReceipt, "task creation receipt is unavailable: #{error.class}: #{error.message}"
      end

      def path(task_folder) = File.join(File.expand_path(task_folder), FILENAME)

      def build(project:, task:, workflow:, stage:, created_at:)
        project = stringify(project)
        task = stringify(task)
        body = {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "project_id" => required_text(project["project_id"], "project_id", 160),
          "project_name" => required_text(project["name"], "project_name", 160),
          "task_id" => task["id"]&.to_s,
          "task_slug" => required_text(task["slug"], "task_slug", 128),
          "workflow" => required_text(workflow, "workflow", 128),
          "stage" => required_text(stage, "stage", 80),
          "created_at" => normalize_time(created_at)
        }
        body["creation_id"] = Digest::SHA256.hexdigest(canonical(body))
        validate!(body)
      end
      private_class_method :build

      def validate!(receipt)
        unless receipt.is_a?(Hash) && receipt["schema"] == SCHEMA &&
               receipt["schema_version"] == SCHEMA_VERSION
          raise InvalidReceipt, "unsupported task creation receipt"
        end
        %w[project_id project_name task_slug workflow stage created_at creation_id].each do |key|
          required_text(receipt[key], key, key == "creation_id" ? 64 : 160)
        end
        unless receipt["creation_id"].match?(/\A[0-9a-f]{64}\z/)
          raise InvalidReceipt, "creation_id is invalid"
        end
        normalize_time(receipt["created_at"])
        expected = Digest::SHA256.hexdigest(canonical(receipt.reject { |key, _| key == "creation_id" }))
        raise InvalidReceipt, "task creation receipt identity is invalid" unless expected == receipt["creation_id"]

        Record.canonical_object(receipt).freeze
      end
      private_class_method :validate!

      def canonical(value) = Record.canonical_json(value)
      private_class_method :canonical

      def normalize_time(value)
        (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).utc.iso8601(6)
      rescue ArgumentError, TypeError
        raise InvalidReceipt, "created_at must be an ISO-8601 timestamp"
      end
      private_class_method :normalize_time

      def required_text(value, label, max)
        text = value.to_s
        unless !text.empty? && text.valid_encoding? && text.bytesize <= max &&
               !text.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidReceipt, "#{label} is invalid"
        end
        text
      end
      private_class_method :required_text

      def stringify(value)
        value.to_h.each_with_object({}) { |(key, child), out| out[key.to_s] = child }
      rescue NoMethodError
        {}
      end
      private_class_method :stringify
    end
  end
end
