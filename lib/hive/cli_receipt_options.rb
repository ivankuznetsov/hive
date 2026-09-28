# frozen_string_literal: true

module Hive
  module CLIReceiptOptions
    module_function

    def apply(command)
      command.option :project, type: :string, desc: "registered project selector"
      command.option :namespace_id, type: :string,
                                    desc: "installation-owner namespace UUID selector"
      command.option :expected_generation, type: :numeric,
                                           desc: "required generation CAS for non-prune mutations"
      command.option :confirm, type: :boolean, default: false,
                               desc: "commit the previewed maintenance action"
      command.option :limit, type: :numeric,
                             desc: "bounded prune/namespace page size (default 100, max 1000)"
      command.option :cursor, type: :string, desc: "stable namespace preview cursor"
      command.option :idempotency_key, type: :string, desc: "optional durable key for prune only"
      command.option :settle_without_result, type: :boolean, default: false,
                                             desc: "terminalize one unresolved receipt without claiming its original result"
      command.option :orphaned_owner, type: :boolean, default: false,
                                      desc: "reclassify one executing receipt whose recorded owner is proven dead"
      command.option :evidence, type: :string, desc: "bounded JSON evidence for verified retirement"
      command.option :force, type: :boolean, default: false,
                             desc: "required with confirmed pin release"
      command.option :reason, type: :string, desc: "required audit reason"
      command.option :new_identity, type: :boolean, default: false,
                                    desc: "mint an explicitly acknowledged replacement project identity"
      command.option :previous_identity, type: :string,
                                         desc: "previous project identity UUID being abandoned"
    end
  end
end
