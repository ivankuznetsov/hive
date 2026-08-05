# frozen_string_literal: true

require_relative "workflow_creator_bundle"
require_relative "workflow_creator_receipt_publisher"

module HiveLiveAgentProof
  class WorkflowCreatorEvidence
    class Error < StandardError; end
    class Conflict < Error; end
    class UnsafeStorage < Error; end
    class Unavailable < Error; end

    TARGET_NAME = WorkflowCreator::Vocabulary.fetch("bundle_files").first
    private_constant :TARGET_NAME

    class << self
      def initialize!(bundle_directory:, candidate_sha:)
        receipt = WorkflowCreator.failure(
          candidate_sha:, phase: "preflight", reason: "not_started"
        )
        publisher(bundle_directory).initialize_receipt(receipt.canonical_bytes)
        receipt
      rescue WorkflowCreatorReceiptPublisher::Conflict
        raise Conflict, "workflow-creator evidence initialization conflicts", cause: nil
      rescue WorkflowCreatorReceiptPublisher::Unsafe
        raise UnsafeStorage, "workflow-creator evidence storage is unsafe", cause: nil
      rescue WorkflowCreatorReceiptPublisher::Unavailable
        raise Unavailable, "workflow-creator evidence storage is unavailable", cause: nil
      end

      def replace_nonpassing!(bundle_directory:, expected:, receipt:, exact_secrets: [])
        expected_receipt = WorkflowCreator.validate_nonpassing!(expected, exact_secrets:)
        desired_receipt = WorkflowCreator.validate_nonpassing!(receipt, exact_secrets:)
        replace(bundle_directory, expected_receipt, desired_receipt)
      end

      def replace_primary!(bundle_directory:, expected:, receipt:, manifest:, candidate_sha:, bundle_records:)
        expected_receipt = WorkflowCreator.validate_nonpassing!(expected)
        desired_receipt = WorkflowCreator.validate_primary!(
          row: receipt, manifest:, candidate_sha:, bundle_records:
        )
        replace(bundle_directory, expected_receipt, desired_receipt)
      end

      def replace_primary_with_failure!(bundle_directory:, expected:, receipt:, manifest:, candidate_sha:,
                                        bundle_records:, exact_secrets: [])
        expected_receipt = WorkflowCreator.validate_primary!(
          row: expected, manifest:, candidate_sha:, bundle_records:
        )
        desired_receipt = WorkflowCreator.validate_nonpassing!(receipt, exact_secrets:)
        replace(bundle_directory, expected_receipt, desired_receipt)
      end

      private

      def replace(bundle_directory, expected_receipt, desired_receipt)
        publisher(bundle_directory).replace_receipt(expected_receipt.canonical_bytes, desired_receipt.canonical_bytes)
        desired_receipt
      rescue WorkflowCreatorReceiptPublisher::Conflict
        raise Conflict, "workflow-creator evidence replacement conflicts", cause: nil
      rescue WorkflowCreatorReceiptPublisher::Unsafe
        raise UnsafeStorage, "workflow-creator evidence storage is unsafe", cause: nil
      rescue WorkflowCreatorReceiptPublisher::Unavailable
        raise Unavailable, "workflow-creator evidence storage is unavailable", cause: nil
      end

      def publisher(bundle_directory)
        WorkflowCreatorReceiptPublisher.new(
          bundle_directory:, target_name: TARGET_NAME
        )
      end
    end
  end

  private_constant :WorkflowCreatorReceiptPublisher
end
