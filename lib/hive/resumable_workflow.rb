require "digest"
require "json"
require "pathname"

module Hive
  module ResumableWorkflow
    STATUSES = %w[complete pending provider_retryable terminal].freeze

    class SnapshotError < Hive::ConfigError; end

    Child = Data.define(
      :child_id, :status, :failed_provider, :artifact_ref, :routing, :reason
    ) do
      def initialize(child_id:, status:, failed_provider: nil, artifact_ref: nil,
                     routing: nil, reason: nil)
        child_id = child_id.to_s.strip
        status = status.to_s
        raise SnapshotError, "resumable child_id must be non-empty" if child_id.empty?
        unless STATUSES.include?(status)
          raise SnapshotError, "resumable child #{child_id.inspect} has unknown status #{status.inspect}"
        end
        if status == "provider_retryable" && failed_provider.to_s.strip.empty?
          raise SnapshotError,
                "resumable child #{child_id.inspect} is provider_retryable without failed_provider"
        end
        if status == "complete" && artifact_ref.to_s.strip.empty?
          raise SnapshotError, "resumable child #{child_id.inspect} is complete without artifact_ref"
        end

        artifact_ref = normalize_artifact_ref(artifact_ref, child_id)
        super(
          child_id: child_id,
          status: status,
          failed_provider: blank_to_nil(failed_provider),
          artifact_ref: artifact_ref,
          routing: routing&.to_h&.freeze,
          reason: blank_to_nil(reason)
        )
      end

      def eligible?
        %w[pending provider_retryable].include?(status)
      end

      def immutable?
        %w[complete terminal].include?(status)
      end

      private

      def normalize_artifact_ref(value, child_id)
        return nil if value.nil?

        text = value.to_s.strip
        path = Pathname.new(text)
        if text.empty? || path.absolute? || path.each_filename.include?("..") || text.include?("\0")
          raise SnapshotError,
                "resumable child #{child_id.inspect} has invalid task-relative artifact_ref #{value.inspect}"
        end
        text.freeze
      end

      def blank_to_nil(value)
        text = value&.to_s&.strip
        text.nil? || text.empty? ? nil : text.freeze
      end
    end

    Snapshot = Data.define(
      :workflow_id, :kind, :checkpoint_generation, :checkpoint_fingerprint,
      :children, :source
    ) do
      def initialize(workflow_id:, kind:, checkpoint_generation:, children:,
                     checkpoint_fingerprint: nil, source: nil)
        workflow_id = workflow_id.to_s.strip
        kind = kind.to_s.strip
        generation = Integer(checkpoint_generation)
        raise SnapshotError, "resumable workflow_id must be non-empty" if workflow_id.empty?
        raise SnapshotError, "resumable workflow kind must be non-empty" if kind.empty?
        raise SnapshotError, "checkpoint_generation must be non-negative" if generation.negative?

        children = Array(children).map { |child| normalize_child(child) }
        duplicates = children.group_by(&:child_id).select { |_id, group| group.length > 1 }.keys
        unless duplicates.empty?
          raise SnapshotError, "resumable snapshot has duplicate child IDs #{duplicates.sort.inspect}"
        end
        fingerprint = checkpoint_fingerprint.to_s.strip
        fingerprint = self.class.fingerprint_for(children) if fingerprint.empty?
        super(
          workflow_id: workflow_id.freeze,
          kind: kind.freeze,
          checkpoint_generation: generation,
          checkpoint_fingerprint: fingerprint.freeze,
          children: children.freeze,
          source: source&.to_s&.freeze
        )
      rescue ArgumentError, TypeError
        raise SnapshotError, "checkpoint_generation must be a non-negative integer"
      end

      def self.from_h(value, source: nil)
        unless value.is_a?(Hash)
          raise SnapshotError, "resumable snapshot at #{source || '(memory)'} must be a JSON object"
        end
        if value["schema"] && value["schema"] != "hive-resumable-workflow"
          raise SnapshotError, "resumable snapshot has unsupported schema #{value['schema'].inspect}"
        end
        if value["schema_version"] && value["schema_version"] != 1
          raise SnapshotError,
                "resumable snapshot has unsupported schema_version #{value['schema_version'].inspect}"
        end

        new(
          workflow_id: value.fetch("workflow_id"),
          kind: value.fetch("kind"),
          checkpoint_generation: value.fetch("checkpoint_generation"),
          checkpoint_fingerprint: value["checkpoint_fingerprint"],
          children: value.fetch("children"),
          source: source
        )
      rescue KeyError => e
        raise SnapshotError, "resumable snapshot is missing #{e.key.inspect}"
      end

      def self.fingerprint_for(children)
        payload = children.map do |child|
          [ child.child_id, child.status, child.failed_provider, child.artifact_ref, child.routing ]
        end
        "sha256:#{::Digest::SHA256.hexdigest(JSON.generate(payload))}"
      end

      def retryable_children
        children.select(&:eligible?)
      end

      private

      def normalize_child(value)
        return value if value.is_a?(Child)
        unless value.is_a?(Hash)
          raise SnapshotError, "resumable child must be an object"
        end

        Child.new(
          child_id: value.fetch("child_id"),
          status: value.fetch("status"),
          failed_provider: value["failed_provider"],
          artifact_ref: value["artifact_ref"],
          routing: value["routing"],
          reason: value["reason"]
        )
      rescue KeyError => e
        raise SnapshotError, "resumable child is missing #{e.key.inspect}"
      end
    end

    Resume = Data.define(:row, :snapshot, :command, :recovery_lease, :provider_decisions)
  end
end
