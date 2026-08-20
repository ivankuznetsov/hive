require "hive"
require "hive/workflow_package/canonical_json"

module Hive
  # First-party Patrol remediation values. Source adapters and UI consumers sit
  # outside this namespace; the core owns only task-local artifacts and their
  # closed read projection.
  module PatrolFix
    WORKFLOW_ID = :"patrol-fix"

    autoload :TaskManifest, "hive/patrol_fix/task_manifest"
    autoload :ReceiptStore, "hive/patrol_fix/receipt_store"
    autoload :Projection, "hive/patrol_fix/projection"
    autoload :Runner, "hive/patrol_fix/runner"
    autoload :SourceSnapshot, "hive/patrol_fix/source_snapshot"
    autoload :AdmissionStore, "hive/patrol_fix/admission_store"
    autoload :SemanticAdmission, "hive/patrol_fix/semantic_admission"
    autoload :TaskMaterializer, "hive/patrol_fix/task_materializer"
    autoload :CutoverGate, "hive/patrol_fix/cutover_gate"
    autoload :HandoffOutbox, "hive/patrol_fix/handoff_outbox"
    autoload :InboxReport, "hive/patrol_fix/inbox_report"
    autoload :FixReport, "hive/patrol_fix/fix_report"
    autoload :WorktreeReceipt, "hive/patrol_fix/worktree_receipt"
    autoload :ValidationReceipt, "hive/patrol_fix/validation_receipt"
    autoload :StageTransition, "hive/patrol_fix/stage_transition"
    autoload :ReviewReceipt, "hive/patrol_fix/review_receipt"
    autoload :Transition, "hive/patrol_fix/transition"
    autoload :SuccessorMaterializer, "hive/patrol_fix/successor_materializer"
    autoload :PublicationReceipt, "hive/patrol_fix/publication_receipt"

    module_function

    def canonical_json(value)
      Hive::WorkflowPackage::CanonicalJSON.generate(value)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
