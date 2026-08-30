require "hive/proposals"

module Hive
  module Proposals
    # Immutable controller-owned admission receipt. Inbox receipts are a
    # recovery queue; canonical records and events remain projection inputs.
    class SourceEvent
      KEYS = %w[
        schema schema_version source_event_id kind proposal_id subject binding actor evaluator
        payload artifact configuration_fingerprint policy created_at
      ].freeze
      KINDS = %w[candidate_submitted evaluation_recorded].freeze
      BINDING_KEYS = %w[
        project task_id task_slug workflow_id stage task_generation ownership_generation attempt_id
      ].freeze
      SUBJECT_KEYS = %w[kind reference revision proposal_id].freeze
      PROPOSAL_BINDING_KEYS = %w[
        schema_version subject actor evaluator configuration_fingerprint policy
      ].freeze
      EVALUATOR_KEYS = %w[id fingerprint configuration_fingerprint admission].freeze
      ADMISSION_KEYS = %w[workflows stages agent_profiles].freeze
      SUBMISSION_KEYS = %w[proposed_change motivation evidence lineage].freeze
      EVALUATION_KEYS = %w[method result rationale evidence links].freeze

      attr_reader :data

      class << self
        def submission(source_event_id:, proposal_id:, proposal_binding:, task_binding:,
                       proposed_change:, motivation:, evidence:, lineage: {},
                       artifact: nil, created_at: Time.now.utc)
          build(
            source_event_id:, proposal_id:, proposal_binding:, task_binding:,
            kind: "candidate_submitted", artifact:, created_at:,
            payload: {
              "proposed_change" => proposed_change, "motivation" => motivation,
              "evidence" => evidence, "lineage" => lineage || {}
            }
          )
        end

        def evaluation(source_event_id:, proposal_id:, proposal_binding:, task_binding:,
                       method:, result:, rationale:, evidence:, links: [],
                       artifact: nil, created_at: Time.now.utc)
          build(
            source_event_id:, proposal_id:, proposal_binding:, task_binding:,
            kind: "evaluation_recorded", artifact:, created_at:,
            payload: {
              "method" => method, "result" => result, "rationale" => rationale,
              "evidence" => evidence, "links" => links
            }
          )
        end

        def build(source_event_id:, proposal_id:, proposal_binding:, task_binding:, kind:,
                  payload:, artifact:, created_at:)
          admitted = normalize_proposal_binding(proposal_binding)
          proposal_id = Proposals.proposal_id!(proposal_id)
          bound_id = admitted.dig("subject", "proposal_id")
          if bound_id && bound_id != proposal_id
            raise InvalidRecord, "proposal source subject does not match the target proposal"
          end
          if kind == "evaluation_recorded" && admitted["evaluator"].nil?
            raise Unauthorized, "proposal evaluation requires an admitted evaluator binding"
          end
          new(
            "schema" => SOURCE_EVENT_SCHEMA, "schema_version" => SCHEMA_VERSION,
            "source_event_id" => Proposals.source_event_id!(source_event_id),
            "kind" => kind, "proposal_id" => proposal_id,
            "subject" => admitted.fetch("subject"),
            "binding" => normalize_task_binding(task_binding),
            "actor" => admitted.fetch("actor"), "evaluator" => admitted["evaluator"],
            "payload" => normalize_payload(kind, payload, policy: admitted.fetch("policy")),
            "artifact" => normalize_artifact(artifact, policy: admitted.fetch("policy")),
            "configuration_fingerprint" => admitted.fetch("configuration_fingerprint"),
            "policy" => admitted.fetch("policy"),
            "created_at" => Proposals.timestamp!(created_at, label: "source event created_at")
          )
        end

        def normalize_proposal_binding(value)
          binding = Proposals.closed_hash!(
            value, required: PROPOSAL_BINDING_KEYS, label: "durable proposal binding"
          )
          unless binding["schema_version"] == 1
            raise InvalidRecord, "durable proposal binding has an unsupported version"
          end
          binding["subject"] = normalize_subject(binding.fetch("subject"))
          binding["actor"] = Proposals.author!(binding.fetch("actor"))
          binding["evaluator"] = normalize_evaluator(binding["evaluator"])
          binding["configuration_fingerprint"] = Proposals.digest!(
            binding.fetch("configuration_fingerprint"), label: "proposal configuration fingerprint"
          )
          binding["policy"] = Proposals.policy!(binding.fetch("policy"))
          binding
        end

        def normalize_subject(value)
          subject = Proposals.closed_hash!(value, required: SUBJECT_KEYS, label: "proposal source subject")
          unless SUBJECT_KINDS.include?(subject["kind"])
            raise InvalidRecord, "proposal source subject kind is invalid"
          end
          subject["reference"] = Proposals.subject_ref!(subject["reference"])
          subject["revision"] = Proposals.label!(subject["revision"], label: "proposal source revision")
          if subject["proposal_id"]
            subject["proposal_id"] = Proposals.proposal_id!(subject["proposal_id"])
          end
          subject
        end

        def normalize_task_binding(value)
          binding = Proposals.closed_hash!(value, required: BINDING_KEYS, label: "proposal task binding")
          %w[project task_id task_slug workflow_id stage ownership_generation attempt_id].each do |key|
            binding[key] = Proposals.label!(binding[key], label: "proposal task binding #{key}")
          end
          generation = binding["task_generation"]
          unless (generation.is_a?(Integer) && generation >= 0) ||
                 (generation.is_a?(String) && !generation.empty?)
            raise InvalidRecord, "proposal task generation is malformed"
          end
          binding
        end

        def normalize_evaluator(value)
          return nil if value.nil?

          evaluator = Proposals.closed_hash!(value, required: EVALUATOR_KEYS, label: "proposal evaluator binding")
          evaluator["id"] = Proposals.label!(evaluator["id"], label: "proposal evaluator id")
          %w[fingerprint configuration_fingerprint].each do |key|
            evaluator[key] = Proposals.digest!(evaluator[key], label: "proposal evaluator #{key}")
          end
          admission = Proposals.closed_hash!(
            evaluator["admission"], required: ADMISSION_KEYS, label: "proposal evaluator admission"
          )
          ADMISSION_KEYS.each do |key|
            values = admission[key]
            unless values.is_a?(Array) && values.uniq == values && values.length <= 64
              raise InvalidRecord, "proposal evaluator admission #{key} is malformed"
            end
            admission[key] = values.map do |entry|
              Proposals.label!(entry, label: "proposal evaluator admission #{key}")
            end.sort
          end
          evaluator["admission"] = admission
          evaluator
        end

        def normalize_payload(kind, value, policy:)
          case kind
          when "candidate_submitted"
            payload = Proposals.closed_hash!(value, required: SUBMISSION_KEYS, label: "proposal submission")
            lineage = Proposals.closed_hash!(
              payload["lineage"] || {}, required: [], optional: %w[retries requested_supersedes],
              label: "proposal submission lineage"
            )
            %w[retries requested_supersedes].each do |key|
              lineage[key] = Proposals.proposal_id!(lineage[key]) if lineage[key]
            end
            payload.merge(
              "proposed_change" => Proposals.text!(payload["proposed_change"], label: "proposed_change"),
              "motivation" => Proposals.text!(payload["motivation"], label: "motivation"),
              "evidence" => Proposals.evidence!(payload["evidence"], policy:),
              "lineage" => { "retries" => lineage["retries"],
                             "requested_supersedes" => lineage["requested_supersedes"] }
            )
          when "evaluation_recorded"
            normalize_evaluation_payload(value, policy:)
          else
            raise InvalidRecord, "unknown proposal source event kind #{kind.inspect}"
          end
        end

        def normalize_evaluation_payload(value, policy:)
          payload = Proposals.closed_hash!(value, required: EVALUATION_KEYS, label: "proposal evaluation source")
          method = Proposals.closed_hash!(
            payload["method"], required: %w[kind label], optional: %w[reference],
            label: "proposal evaluation method"
          )
          unless %w[benchmark test manual policy other].include?(method["kind"])
            raise InvalidRecord, "proposal evaluation method kind is invalid"
          end
          method["label"] = Proposals.label!(method["label"], label: "proposal evaluation method label")
          if method["reference"]
            method["reference"] = Proposals.safe_reference!(
              method["reference"], label: "proposal evaluation method reference",
              allowed_schemes: policy.fetch("allowed_link_schemes")
            )
          end
          result = normalize_result(payload.fetch("result"))
          payload.merge(
            "method" => method, "result" => result,
            "rationale" => Proposals.text!(payload["rationale"], label: "evaluation rationale"),
            "evidence" => Proposals.evidence!(payload["evidence"], policy:),
            "links" => Proposals.links!(
              payload["links"], allowed_schemes: policy.fetch("allowed_link_schemes"),
              error: InvalidRecord
            )
          )
        end

        def normalize_result(value)
          result = Proposals.closed_hash!(
            value, required: %w[outcome metrics], optional: %w[details_digest],
            label: "proposal evaluation result"
          )
          unless RESULT_OUTCOMES.include?(result["outcome"])
            raise InvalidRecord, "proposal evaluation result outcome is invalid"
          end
          metrics = result["metrics"]
          unless metrics.is_a?(Hash) && metrics.length <= 64 && metrics.all? do |key, entry|
                   key.to_s.match?(SAFE_LABEL) &&
                     (entry.nil? || [ true, false ].include?(entry) || entry.is_a?(Numeric))
                 end
            raise InvalidRecord, "proposal evaluation metrics must contain only typed facts"
          end
          if result["details_digest"]
            result["details_digest"] = Proposals.digest!(
              result["details_digest"], label: "proposal evaluation details digest"
            )
          end
          result
        end

        def normalize_artifact(value, policy:)
          return nil if value.nil?

          artifact = Proposals.closed_hash!(
            value, required: %w[reference digest bytes media_type],
            label: "proposal source artifact"
          )
          artifact["reference"] = Proposals.safe_reference!(
            artifact["reference"], label: "proposal source artifact reference",
            allowed_schemes: policy.fetch("allowed_link_schemes")
          )
          artifact["digest"] = Proposals.digest!(
            artifact["digest"], label: "proposal source artifact digest"
          )
          unless artifact["bytes"].is_a?(Integer) && artifact["bytes"] >= 0
            raise InvalidRecord, "proposal source artifact bytes must be non-negative"
          end
          artifact["media_type"] = Proposals.label!(
            artifact["media_type"], label: "proposal source artifact media type"
          )
          artifact
        end
      end

      def initialize(attributes)
        @data = Proposals.stringify(attributes)
        validate!
        @data = Proposals.deep_copy_freeze(@data)
        freeze
      end

      def [](key) = data[key.to_s]
      def to_h = JSON.parse(JSON.generate(data))
      def source_event_id = self["source_event_id"]
      def proposal_id = self["proposal_id"]
      def kind = self["kind"]
      def digest = Proposals.digest(data)

      def provenance(source_commit:)
        binding = data.fetch("binding")
        actor = data.fetch("actor")
        provenance = {
          "task_id" => binding.fetch("task_id"),
          "task_generation" => binding.fetch("task_generation"),
          "ownership_generation" => binding.fetch("ownership_generation"),
          "attempt_id" => binding.fetch("attempt_id"),
          "workflow_id" => binding.fetch("workflow_id"), "stage" => binding.fetch("stage"),
          "actor" => {
            "id" => actor.fetch("id"), "kind" => actor.fetch("kind"),
            "binding_fingerprint" => Proposals.digest(actor.fetch("binding"))
          },
          "source_commit" => source_commit,
          "configuration_fingerprint" => data.fetch("configuration_fingerprint")
        }
        if data["evaluator"]
          provenance["evaluator_binding"] = {
            "id" => data.dig("evaluator", "id"),
            "fingerprint" => data.dig("evaluator", "fingerprint")
          }
        end
        if data["artifact"]
          provenance["artifact_reference"] = data.dig("artifact", "reference")
          provenance["artifact_digest"] = data.dig("artifact", "digest")
        end
        provenance
      end

      private

      def validate!
        unless data.is_a?(Hash) && data.keys.sort == KEYS.sort &&
               data["schema"] == SOURCE_EVENT_SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise InvalidRecord, "proposal source event has an invalid or open schema envelope"
        end
        data["source_event_id"] = Proposals.source_event_id!(data["source_event_id"])
        data["proposal_id"] = Proposals.proposal_id!(data["proposal_id"])
        raise InvalidRecord, "proposal source event kind is invalid" unless KINDS.include?(data["kind"])
        data["subject"] = self.class.normalize_subject(data["subject"])
        bound_id = data.dig("subject", "proposal_id")
        if bound_id && bound_id != data["proposal_id"]
          raise InvalidRecord, "proposal source subject does not match the target proposal"
        end
        data["binding"] = self.class.normalize_task_binding(data["binding"])
        data["actor"] = Proposals.author!(data["actor"])
        data["evaluator"] = self.class.normalize_evaluator(data["evaluator"])
        if data["kind"] == "evaluation_recorded" && data["evaluator"].nil?
          raise Unauthorized, "proposal evaluation requires an admitted evaluator binding"
        end
        data["payload"] = self.class.normalize_payload(
          data["kind"], data["payload"], policy: persisted_policy
        )
        data["artifact"] = self.class.normalize_artifact(data["artifact"], policy: persisted_policy)
        data["configuration_fingerprint"] = Proposals.digest!(
          data["configuration_fingerprint"], label: "proposal configuration fingerprint"
        )
        data["policy"] = Proposals.policy!(data["policy"])
        data["created_at"] = Proposals.timestamp!(data["created_at"], label: "source event created_at")
      end

      def persisted_policy
        Proposals.policy!(data.fetch("policy"))
      end
    end
  end
end
