require "digest"
require "time"
require "hive/errors"
require "hive/modules/migration/patrol_decision_projection"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      module PatrolEvidence
        MODULES = %w[patrol architecture-patrol].freeze
        OWNERS = %w[legacy module].freeze
        AUTHORITIES = %w[legacy module shadow].freeze
        MAX_CAPTURE_BYTES = 48 * 1024
        MAX_RECEIPT_BYTES = 128 * 1024
        MAX_INTENT_BYTES = 32 * 1024
        MAX_EFFECTS_PER_OCCURRENCE = 128
        MAX_JSON_DEPTH = 32
        MAX_JSON_NODES = 8_192
        MAX_STRING_BYTES = 32 * 1024
        SINKS = %w[
          attempt state finding branch pull_request review_handoff
          job discovery action issue
        ].freeze
        RECEIPT_STATUSES = %w[
          attempted denied known_not_sent unknown committed reconciled failed
        ].freeze
        TRIGGER_KINDS = %w[
          direct job_store.schema_v2_import manual module_event
          pull_request.merged schedule
        ].freeze
        SCOPE_KEY_SETS = [
          [],
          %w[fingerprint],
          %w[fingerprint fingerprint_operation],
          %w[job_id],
          %w[job_id operation],
          %w[canonical_action_id job_id],
          %w[
            base_sha branch fingerprint head_sha patch_id worktree_path
          ],
          %w[
            base_sha branch fingerprint fingerprint_operation head_sha
            patch_id worktree_path
          ],
          %w[
            base_branch base_sha branch finding_projection fingerprint
            head_sha patch_id repository worktree_path
          ]
        ].map(&:sort).freeze
        EFFECT_OUTCOME_KEY_SETS = [
          [],
          %w[attempted reason],
          %w[base_oid head_oid pr_url state],
          %w[content_digest],
          %w[error_code transition_digest transition_status],
          %w[finding_id],
          %w[issue_url],
          %w[migration transition_status],
          %w[patch_id],
          %w[pr_url],
          %w[reason],
          %w[remote_oid],
          %w[task_path],
          %w[transition_digest transition_status],
          %w[transition_status]
        ].map(&:sort).freeze
        PATROL_OUTCOME_KEYS = %w[
          exit_code features_mapped features_reviewed finding_ids findings
          fixes_attempted last_scanned_sha ok prs_opened rationale
          review_complete
        ].freeze
        ARCHITECTURE_OUTCOME_KEYS = %w[
          action_count action_outcomes complete completion_status job_id
          rationale state zero_reason
        ].freeze

        module_function

        def immutable_json(value, label:, depth: 0, budget: nil)
          budget ||= { nodes: 0 }
          budget[:nodes] += 1
          malformed!(label) if depth > MAX_JSON_DEPTH ||
                               budget.fetch(:nodes) > MAX_JSON_NODES
          case value
          when Hash
            value.each_with_object({}) do |(key, child), copy|
              malformed!(label) unless key.is_a?(String) &&
                                       key.bytesize <= MAX_STRING_BYTES
              copy[key.dup.freeze] = immutable_json(
                child, label: label, depth: depth + 1, budget: budget
              )
            end.freeze
          when Array
            value.map do |child|
              immutable_json(
                child, label: label, depth: depth + 1, budget: budget
              )
            end.freeze
          when String
            malformed!(label) if value.bytesize > MAX_STRING_BYTES
            value.dup.freeze
          when Integer, TrueClass, FalseClass, NilClass
            value
          when Float
            malformed!(label) unless value.finite?
            value
          else
            malformed!(label)
          end
        end

        def timestamp(value, label:)
          time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
          time.utc.iso8601(6).freeze
        rescue ArgumentError, TypeError
          malformed!(label)
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def digest(prefix, value)
          "#{prefix}-#{::Digest::SHA256.hexdigest(canonical(value))}".freeze
        end

        def bounded!(value, max_bytes:, label:)
          malformed!(label) if canonical(value).bytesize > max_bytes
          value
        end

        def nonempty(value, label:)
          string = value.to_s
          malformed!(label) if string.empty?
          string.dup.freeze
        end

        def positive_integer(value, label:)
          integer = Integer(value)
          malformed!(label) unless integer.positive?
          integer
        rescue ArgumentError, TypeError
          malformed!(label)
        end

        def optional_generation(value, label:)
          return nil if value.nil?

          generation = Integer(value)
          malformed!(label) if generation.negative?
          generation
        rescue ArgumentError, TypeError
          malformed!(label)
        end

        def exact_keys!(value, keys, label:)
          malformed!(label) unless value.is_a?(Hash) && value.keys.sort == keys.sort
          value
        end

        def allowed_keys!(value, allowed, required:, label:)
          malformed!(label) unless value.is_a?(Hash)
          keys = value.keys
          malformed!(label) unless (keys - allowed).empty? &&
                                   (required - keys).empty?
          value
        end

        def enum(value, allowed, label:)
          string = value.to_s
          malformed!(label) unless allowed.include?(string)
          string.dup.freeze
        end

        def hex_id(value, prefix, label:)
          string = value.to_s
          malformed!(label) unless string.match?(/\A#{Regexp.escape(prefix)}-[0-9a-f]{64}\z/)
          string.dup.freeze
        end

        def malformed!(label)
          raise Hive::ConfigError, "#{label} is malformed"
        end

        def trigger(value, label:)
          object = immutable_json(value, label: label)
          malformed!(label) unless object.is_a?(Hash)
          kind = enum(object["kind"], TRIGGER_KINDS, label: label)
          keys = case kind
          when "manual", "direct"
            %w[id kind]
          when "schedule"
            %w[id kind occurred_at schedule]
          when "module_event"
            %w[event_name id kind occurred_at]
          when "pull_request.merged"
            %w[id kind manifest_digest merge_sha]
          when "job_store.schema_v2_import"
            %w[id kind source_digest source_schema_version]
          end
          exact_keys!(object, keys, label: label)
          nonempty(object["id"], label: label)
          case kind
          when "schedule"
            nonempty(object["schedule"], label: label)
            timestamp(object["occurred_at"], label: label)
          when "module_event"
            nonempty(object["event_name"], label: label)
            timestamp(object["occurred_at"], label: label)
          when "pull_request.merged"
            nonempty(object["manifest_digest"], label: label)
            nonempty(object["merge_sha"], label: label)
          when "job_store.schema_v2_import"
            malformed!(label) unless object["source_schema_version"] == 2
            nonempty(object["source_digest"], label: label)
          end
          object
        end

        def reservation(value, label:)
          object = immutable_json(value, label: label)
          malformed!(label) unless object.is_a?(Hash)
          kind = enum(
            object["kind"],
            %w[ordinary module_hook architecture],
            label: label
          )
          scheduled = object.key?("window_started_at") ||
                      object.key?("attempt_generation")
          keys = %w[id kind]
          keys << "job_id" if kind == "architecture"
          keys.concat(%w[attempt_generation window_started_at]) if scheduled
          exact_keys!(object, keys, label: label)
          nonempty(object["id"], label: label)
          nonempty(object["job_id"], label: label) if
            kind == "architecture"
          if scheduled
            positive_integer(object["attempt_generation"], label: label)
            timestamp(object["window_started_at"], label: label)
          end
          object
        end

        def scope(value, label:)
          object = immutable_json(value, label: label)
          malformed!(label) unless object.is_a?(Hash) &&
                                   SCOPE_KEY_SETS.include?(object.keys.sort)
          object.each_value { |item| nonempty(item, label: label) }
          object
        end

        def capture_outcome(module_name, outcome_class, value, label:)
          return [ nil, nil ] if outcome_class.nil? && value.nil?
          malformed!(label) if outcome_class.nil? || value.nil?

          klass = enum(
            outcome_class,
            %w[complete completed failed not_dispatched schema_v2_import],
            label: label
          )
          outcome = immutable_json(value, label: label)
          allowed = module_name == "patrol" ?
            PATROL_OUTCOME_KEYS : ARCHITECTURE_OUTCOME_KEYS
          allowed_keys!(
            outcome, allowed,
            required:
              klass == "schema_v2_import" ?
                %w[complete job_id state] : %w[rationale],
            label: label
          )
          validate_capture_outcome_scalars!(
            module_name, outcome, label: label
          )
          [ klass, outcome ]
        end

        def effect_outcome(value, label:)
          outcome = immutable_json(value, label: label)
          malformed!(label) unless outcome.is_a?(Hash) &&
                                   EFFECT_OUTCOME_KEY_SETS.include?(
                                     outcome.keys.sort
                                   )
          outcome.each_value do |item|
            malformed!(label) unless
              item.is_a?(String) || item.is_a?(Integer) ||
              item == true || item == false || item.nil?
          end
          malformed!(label) if
            outcome.key?("attempted") && outcome["attempted"] != true
          outcome
        end

        def validate_capture_outcome_scalars!(module_name, outcome, label:)
          outcome.each do |key, value|
            case key
            when "ok", "review_complete", "complete"
              malformed!(label) unless [ true, false ].include?(value)
            when "exit_code"
              malformed!(label) unless value.nil? || value.is_a?(Integer)
            when "features_mapped", "features_reviewed", "findings",
                 "fixes_attempted", "prs_opened", "action_count"
              malformed!(label) unless value.is_a?(Integer) &&
                                       value >= 0
            when "finding_ids"
              malformed!(label) unless value.is_a?(Array) &&
                                       value.all? do |item|
                                         item.is_a?(String) && !item.empty?
                                       end
            when "action_outcomes"
              malformed!(label) unless
                module_name == "architecture-patrol" &&
                value.is_a?(Hash) &&
                value.all? do |action_id, action_outcome|
                  action_id.is_a?(String) && !action_id.empty? &&
                    action_outcome.is_a?(String)
                end
            else
              malformed!(label) unless value.nil? ||
                                       value.is_a?(String)
            end
          end
          true
        end
        private_class_method :validate_capture_outcome_scalars!
      end

      class PatrolCaptureValidator
        KEYS = %w[
          capture_id effect_ids module occurred_at occurrence_id outcome
          outcome_class owner owner_epoch project recorded_at reservation schema
          schema_version selection selection_input trigger
        ].freeze
        PROJECT_KEYS = %w[name project_id repository].freeze

        class << self
          def build(module_name:, project:, trigger:, reservation:, owner:, owner_epoch:,
                    selection_input:, selection:, outcome_class:, outcome:,
                    effect_ids: [], occurred_at:, recorded_at:)
            label = "patrol capture"
            module_name = PatrolEvidence.enum(module_name, PatrolEvidence::MODULES, label: label)
            owner = PatrolEvidence.enum(owner, PatrolEvidence::OWNERS, label: label)
            owner_epoch = PatrolEvidence.positive_integer(owner_epoch, label: label)
            project = project_value(project, label)
            trigger = PatrolEvidence.trigger(trigger, label: label)
            reservation = PatrolEvidence.reservation(
              reservation, label: label
            )
            selection_input = selection_input_value(
              module_name, selection_input, label
            )
            selection = PatrolDecisionProjection.coerce(selection)
            PatrolEvidence.malformed!(label) unless
              selection.module_name == module_name
            outcome_class, outcome = PatrolEvidence.capture_outcome(
              module_name, outcome_class, outcome, label: label
            )
            effect_ids = Array(effect_ids).map do |effect_id|
              PatrolEvidence.nonempty(effect_id, label: label)
            end
            PatrolEvidence.malformed!(label) unless effect_ids.uniq == effect_ids &&
                                                    effect_ids.size <=
                                                      PatrolEvidence::MAX_EFFECTS_PER_OCCURRENCE
            effect_ids = effect_ids.freeze
            occurred_at = PatrolEvidence.timestamp(occurred_at, label: label)
            recorded_at = PatrolEvidence.timestamp(recorded_at, label: label)
            occurrence_identity = {
              "module" => module_name,
              "project" => project,
              "trigger" => trigger,
              "reservation" => reservation,
              "owner" => owner,
              "owner_epoch" => owner_epoch,
              "selection_input" => selection_input,
              "selection" => selection.to_h
            }
            occurrence_id = PatrolEvidence.digest("occ", occurrence_identity)
            capture_id = PatrolEvidence.digest(
              "cap",
              occurrence_identity.merge(
                "outcome_class" => outcome_class,
                "outcome" => outcome,
                "effect_ids" => effect_ids
              )
            )
            attributes = {
              capture_id: capture_id,
              module_name: module_name,
              occurrence_id: occurrence_id,
              project: project,
              trigger: trigger,
              reservation: reservation,
              owner: owner,
              owner_epoch: owner_epoch,
              selection_input: selection_input,
              selection: selection,
              outcome_class: outcome_class,
              outcome: outcome,
              effect_ids: effect_ids,
              occurred_at: occurred_at,
              recorded_at: recorded_at
            }
            PatrolEvidence.bounded!(
              {
                "schema" => "hive-patrol-capture",
                "schema_version" => 1,
                "capture_id" => capture_id,
                "module" => module_name,
                "occurrence_id" => occurrence_id,
                "project" => project,
                "trigger" => trigger,
                "reservation" => reservation,
                "owner" => owner,
                "owner_epoch" => owner_epoch,
                "selection_input" => selection_input,
                "selection" => selection.to_h,
                "outcome_class" => outcome_class,
                "outcome" => outcome,
                "effect_ids" => effect_ids,
                "occurred_at" => occurred_at,
                "recorded_at" => recorded_at
              },
              max_bytes: PatrolEvidence::MAX_CAPTURE_BYTES,
              label: label
            )
            attributes
          end

          def parse(value)
            label = "patrol capture"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            PatrolEvidence.malformed!(label) unless value["schema"] == "hive-patrol-capture" &&
                                                    value["schema_version"] == 1
            attributes = build(
              module_name: value["module"],
              project: value["project"],
              trigger: value["trigger"],
              reservation: value["reservation"],
              owner: value["owner"],
              owner_epoch: value["owner_epoch"],
              selection_input: value["selection_input"],
              selection: value["selection"],
              outcome_class: value["outcome_class"],
              outcome: value["outcome"],
              effect_ids: value["effect_ids"],
              occurred_at: value["occurred_at"],
              recorded_at: value["recorded_at"]
            )
            unless attributes[:occurrence_id] == value["occurrence_id"] &&
                   attributes[:capture_id] == value["capture_id"]
              raise Hive::ConfigError, "patrol capture identity does not match its contents"
            end
            attributes
          end

          private

          def project_value(value, label)
            PatrolEvidence.exact_keys!(value, PROJECT_KEYS, label: label)
            project_id = PatrolEvidence.nonempty(value["project_id"], label: label)
            name = PatrolEvidence.nonempty(value["name"], label: label)
            repository = value["repository"]
            unless repository.nil?
              repository = PatrolEvidence.nonempty(repository, label: label)
            end
            { "project_id" => project_id, "name" => name, "repository" => repository }.freeze
          end

          def object(value, label)
            immutable = PatrolEvidence.immutable_json(value, label: label)
            PatrolEvidence.malformed!(label) unless immutable.is_a?(Hash)
            immutable
          end

          def selection_input_value(module_name, value, label)
            input = object(value, label)
            kind = input["kind"].to_s
            case [ module_name, kind ]
            when [ "patrol", "schedule" ]
              PatrolEvidence.exact_keys!(
                input,
                %w[branch_changed enabled kind timer_due trigger],
                label: label
              )
              PatrolEvidence.malformed!(label) unless
                [ true, false ].include?(input["enabled"]) &&
                %w[continuous timer new_commits].include?(input["trigger"]) &&
                boolean_or_nil?(input["timer_due"]) &&
                boolean_or_nil?(input["branch_changed"])
            when [ "patrol", "module_event" ]
              PatrolEvidence.exact_keys!(
                input, %w[event_id kind], label: label
              )
              PatrolEvidence.nonempty(input["event_id"], label: label)
            when [ "patrol", "operation" ]
              PatrolEvidence.exact_keys!(
                input, %w[kind operation], label: label
              )
              PatrolEvidence.nonempty(input["operation"], label: label)
            when [ "architecture-patrol", "candidate" ]
              validate_architecture_input!(input, label)
            when [ "architecture-patrol", "operation" ]
              PatrolEvidence.exact_keys!(
                input, %w[job_id kind operation phase], label: label
              )
              validate_architecture_values!(input, label)
              PatrolEvidence.nonempty(input["operation"], label: label)
            else
              PatrolEvidence.malformed!(label)
            end
            input
          end

          def validate_architecture_input!(input, label)
            PatrolEvidence.exact_keys!(
              input, %w[job_id kind phase], label: label
            )
            validate_architecture_values!(input, label)
          end

          def validate_architecture_values!(input, label)
            PatrolEvidence.nonempty(input["job_id"], label: label)
            PatrolEvidence.enum(
              input["phase"], PatrolDecisionProjection::ARCHITECTURE_PHASES,
              label: label
            )
          end

          def boolean_or_nil?(value)
            value.nil? || value == true || value == false
          end
        end
      end

      PatrolCapture = Data.define(
        :capture_id, :module_name, :occurrence_id, :project, :trigger,
        :reservation, :owner, :owner_epoch, :selection_input, :selection,
        :outcome_class, :outcome, :effect_ids, :occurred_at, :recorded_at
      ) do
        class << self
          def build(**attributes)
            new(**PatrolCaptureValidator.build(**attributes))
          end

          def from_h(value)
            new(**PatrolCaptureValidator.parse(value))
          end
        end

        def to_h
          {
            "schema" => "hive-patrol-capture",
            "schema_version" => 1,
            "capture_id" => capture_id,
            "module" => module_name,
            "occurrence_id" => occurrence_id,
            "project" => project,
            "trigger" => trigger,
            "reservation" => reservation,
            "owner" => owner,
            "owner_epoch" => owner_epoch,
            "selection_input" => selection_input,
            "selection" => selection.to_h,
            "outcome_class" => outcome_class,
            "outcome" => outcome,
            "effect_ids" => effect_ids,
            "occurred_at" => occurred_at,
            "recorded_at" => recorded_at
          }.freeze
        end
      end

      class EffectIntentValidator
        KEYS = %w[
          authority authorization_digest capability claim_generation created_at
          idempotency_key intent_id module occurrence_id owner_epoch scope sink
          target
        ].freeze

        class << self
          def build(module_name:, occurrence_id:, authority:, owner_epoch:, sink:, target:,
                    idempotency_key:, capability:, created_at:, claim_generation: nil,
                    scope: {})
            label = "patrol effect intent"
            module_name = PatrolEvidence.enum(module_name, PatrolEvidence::MODULES, label: label)
            occurrence_id = PatrolEvidence.hex_id(occurrence_id, "occ", label: label)
            authority = PatrolEvidence.enum(authority, PatrolEvidence::AUTHORITIES, label: label)
            owner_epoch = PatrolEvidence.positive_integer(owner_epoch, label: label)
            sink = PatrolEvidence.enum(sink, PatrolEvidence::SINKS, label: label)
            target = PatrolEvidence.nonempty(target, label: label)
            idempotency_key = PatrolEvidence.nonempty(idempotency_key, label: label)
            capability = PatrolEvidence.nonempty(capability, label: label)
            claim_generation = PatrolEvidence.optional_generation(claim_generation, label: label)
            created_at = PatrolEvidence.timestamp(created_at, label: label)
            scope = PatrolEvidence.scope(scope, label: label)
            identity = {
              "module" => module_name,
              "occurrence_id" => occurrence_id,
              "sink" => sink,
              "target" => target,
              "idempotency_key" => idempotency_key,
              "owner_epoch" => owner_epoch,
              "scope" => scope
            }
            intent_id = PatrolEvidence.digest("intent", identity)
            authorization_digest = PatrolEvidence.digest(
              "auth",
              {
                "intent_id" => intent_id,
                "authority" => authority,
                "owner_epoch" => owner_epoch,
                "capability" => capability,
                "claim_generation" => claim_generation,
                "created_at" => created_at
              }
            )
            attributes = {
              intent_id: intent_id,
              module_name: module_name,
              occurrence_id: occurrence_id,
              authority: authority,
              authorization_digest: authorization_digest,
              owner_epoch: owner_epoch,
              sink: sink,
              target: target,
              idempotency_key: idempotency_key,
              capability: capability,
              claim_generation: claim_generation,
              scope: scope,
              created_at: created_at
            }
            PatrolEvidence.bounded!(
              attributes.transform_keys(&:to_s),
              max_bytes: PatrolEvidence::MAX_INTENT_BYTES,
              label: label
            )
            attributes
          end

          def parse(value)
            label = "patrol effect intent"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            attributes = build(
              module_name: value["module"],
              occurrence_id: value["occurrence_id"],
              authority: value["authority"],
              owner_epoch: value["owner_epoch"],
              sink: value["sink"],
              target: value["target"],
              idempotency_key: value["idempotency_key"],
              capability: value["capability"],
              claim_generation: value["claim_generation"],
              scope: value["scope"],
              created_at: value["created_at"]
            )
            unless attributes[:intent_id] == value["intent_id"]
              raise Hive::ConfigError,
                    "patrol effect intent identity does not match its contents"
            end
            unless attributes[:authorization_digest] ==
                   value["authorization_digest"]
              raise Hive::ConfigError,
                    "patrol effect intent authorization does not match its contents"
            end
            attributes
          end
        end
      end

      EffectIntent = Data.define(
        :intent_id, :module_name, :occurrence_id, :authority,
        :authorization_digest, :owner_epoch, :sink, :target, :idempotency_key,
        :capability, :claim_generation, :scope, :created_at
      ) do
        class << self
          def build(**attributes)
            new(**EffectIntentValidator.build(**attributes))
          end

          def from_h(value)
            new(**EffectIntentValidator.parse(value))
          end
        end

        def to_h
          {
            "intent_id" => intent_id,
            "module" => module_name,
            "occurrence_id" => occurrence_id,
            "authority" => authority,
            "authorization_digest" => authorization_digest,
            "owner_epoch" => owner_epoch,
            "sink" => sink,
            "target" => target,
            "idempotency_key" => idempotency_key,
            "capability" => capability,
            "claim_generation" => claim_generation,
            "scope" => scope,
            "created_at" => created_at
          }.freeze
        end
      end

      class EffectReceiptValidator
        KEYS = %w[intent outcome receipt_id recorded_at schema schema_version status].freeze

        class << self
          def build(intent:, status:, outcome:, recorded_at:)
            label = "patrol effect receipt"
            intent = intent.is_a?(EffectIntent) ? intent : EffectIntent.from_h(intent)
            status = PatrolEvidence.enum(status, PatrolEvidence::RECEIPT_STATUSES, label: label)
            outcome = PatrolEvidence.effect_outcome(
              outcome, label: label
            )
            recorded_at = PatrolEvidence.timestamp(recorded_at, label: label)
            receipt_id = PatrolEvidence.digest(
              "receipt",
              {
                "intent_id" => intent.intent_id,
                "status" => status,
                "outcome" => outcome
              }
            )
            {
              receipt_id: receipt_id,
              intent: intent,
              status: status,
              outcome: outcome,
              recorded_at: recorded_at
            }
              .tap do |attributes|
                PatrolEvidence.bounded!(
                  {
                    "schema" => "hive-patrol-effect-receipt",
                    "schema_version" => 1,
                    "receipt_id" => attributes.fetch(:receipt_id),
                    "intent" => attributes.fetch(:intent).to_h,
                    "status" => attributes.fetch(:status),
                    "outcome" => attributes.fetch(:outcome),
                    "recorded_at" => attributes.fetch(:recorded_at)
                  },
                  max_bytes: PatrolEvidence::MAX_RECEIPT_BYTES,
                  label: label
                )
              end
          end

          def parse(value)
            label = "patrol effect receipt"
            PatrolEvidence.exact_keys!(value, KEYS, label: label)
            PatrolEvidence.malformed!(label) unless value["schema"] == "hive-patrol-effect-receipt" &&
                                                    value["schema_version"] == 1
            attributes = build(
              intent: value["intent"],
              status: value["status"],
              outcome: value["outcome"],
              recorded_at: value["recorded_at"]
            )
            unless attributes[:receipt_id] == value["receipt_id"]
              raise Hive::ConfigError,
                    "patrol effect receipt identity does not match its contents"
            end
            attributes
          end
        end
      end

      EffectReceipt = Data.define(:receipt_id, :intent, :status, :outcome, :recorded_at) do
        class << self
          def build(**attributes)
            new(**EffectReceiptValidator.build(**attributes))
          end

          def from_h(value)
            new(**EffectReceiptValidator.parse(value))
          end
        end

        def to_h
          {
            "schema" => "hive-patrol-effect-receipt",
            "schema_version" => 1,
            "receipt_id" => receipt_id,
            "intent" => intent.to_h,
            "status" => status,
            "outcome" => outcome,
            "recorded_at" => recorded_at
          }.freeze
        end
      end
    end
  end
end
