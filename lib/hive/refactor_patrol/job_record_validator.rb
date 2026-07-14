require "digest"
require "json"
require "time"
require "hive/refactor_patrol/publication_attempt"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Pure validation for durable job records and their allowed transitions.
    # The injected contract supplies JobStore's public schema constants and
    # error types so extraction does not fork the on-disk format.
    class JobRecordValidator
      def initialize(contract:)
        @contract = contract
        @corrupt_record = contract.const_get(:CorruptRecord)
        @unsupported_version = contract.const_get(:UnsupportedVersion)
        @inconsistent_record = contract.const_get(:InconsistentRecord)
      end

      def validate_id!(job_id)
        id = job_id.to_s
        unless id.match?(constant(:ID_PATTERN))
          raise @inconsistent_record, "invalid refactor patrol job id #{id.inspect}"
        end

        id
      end

      def validate_job!(data, path: nil)
        strict_hash!(
          data,
          required: constant(:TOP_LEVEL_KEYS),
          allowed: constant(:TOP_LEVEL_KEYS),
          label: "job",
          path: path
        )
        inconsistent!("unexpected job schema", path) unless data.fetch("schema") == constant(:SCHEMA)
        version = data.fetch("schema_version")
        unless version.is_a?(Integer)
          raise @corrupt_record.new("job schema_version must be an integer", path: path)
        end
        unless version == constant(:SCHEMA_VERSION)
          raise @unsupported_version.new(
            "unsupported refactor patrol job schema_version #{version}", path: path
          )
        end
        validate_id!(data.fetch("job_id"))
        inconsistent!("job state is invalid", path) unless constant(:STATES).include?(data.fetch("state"))
        unless [ true, false ].include?(data.fetch("complete"))
          inconsistent!("job complete must be boolean", path)
        end
        if data.fetch("complete") != (data.fetch("state") == "complete")
          inconsistent!("job state and complete flag disagree", path)
        end

        validate_source!(data.fetch("source"), path)
        validate_policy!(data.fetch("policy"), path)
        string_or_nil!(data.fetch("analysis_sha"), "analysis_sha", path)
        timestamp!(data.fetch("created_at"), "created_at", path)
        timestamp!(data.fetch("updated_at"), "updated_at", path)

        errors = array_of_hashes!(data.fetch("review_errors"), "review_errors", path)
        inconsistent!("complete job cannot retain review errors", path) if data.fetch("complete") && errors.any?
        zero_reason = data.fetch("zero_reason")
        unless zero_reason.nil? || constant(:ZERO_REASONS).include?(zero_reason)
          inconsistent!("zero_reason is invalid", path)
        end
        inconsistent!("partial job cannot have zero_reason", path) if !data.fetch("complete") && zero_reason

        dispositions = data.fetch("dispositions")
        strict_hash!(
          dispositions,
          required: constant(:DISPOSITIONS),
          allowed: constant(:DISPOSITIONS),
          label: "dispositions",
          path: path
        )
        seen_ids = {}
        fingerprint_by_id = {}
        constant(:DISPOSITIONS).each do |name|
          array_of_hashes!(dispositions.fetch(name), "#{name} dispositions", path).each do |item|
            validate_disposition!(item, name, path)
            id = item.fetch("id")
            inconsistent!("thesis #{id.inspect} appears in multiple dispositions", path) if seen_ids[id]
            seen_ids[id] = name
            fingerprint_by_id[id] = item.fetch("fingerprint")
          end
        end
        if data.fetch("complete") && seen_ids.empty? && zero_reason.nil?
          inconsistent!("complete zero-thesis job requires zero_reason", path)
        end

        array_of_hashes!(data.fetch("feature_results"), "feature_results", path).each do |item|
          strict_hash!(
            item,
            required: constant(:FEATURE_RESULT_KEYS),
            allowed: constant(:FEATURE_RESULT_KEYS),
            label: "feature result",
            path: path
          )
          nonempty_string!(item.fetch("feature_id"), "feature result id", path)
          unless [ true, false ].include?(item.fetch("complete"))
            inconsistent!("feature result complete must be boolean", path)
          end
          string_array!(item.fetch("thesis_ids"), "feature result thesis_ids", path)
          array_of_hashes!(item.fetch("errors"), "feature result errors", path)
        end
        validate_discovery_attempts!(data.fetch("attempts"), path)
        actions = data.fetch("actions")
        validate_actions!(
          actions,
          data.fetch("job_id"),
          fingerprint_by_id,
          path,
          repository: data.dig("source", "repository")
        )
        if actions.count { |action| active_action_claim(action) } > 1
          inconsistent!("job can serialize only one active action claim", path)
        end
        if actions.any? && data.fetch("complete") != actions.all? { |action| action.fetch("terminal") }
          inconsistent!("job completion must match terminal action snapshot", path)
        end
        data
      rescue KeyError => e
        raise @corrupt_record.new("refactor patrol job is missing #{e.key.inspect}", path: path)
      end

      def validate_terminal_proof!(proof, action_id, path)
        unless proof.is_a?(Hash) && proof.keys.sort == constant(:TERMINAL_PROOF_KEYS).sort
          raise @corrupt_record.new("terminal canonical action proof has an invalid shape", path: path)
        end
        owner = proof.fetch("owner")
        receipts = proof.fetch("proof")
        valid_owner = owner.is_a?(Hash) &&
                      owner.keys.sort == constant(:TERMINAL_PROOF_OWNER_KEYS).sort &&
                      %w[registration project_root job_id].all? { |key|
                        owner[key].is_a?(String) && !owner[key].empty?
                      } && owner["pr_number"].is_a?(Integer) && owner["pr_number"].positive? &&
                      owner["merge_sha"].to_s.match?(/\A[0-9a-f]{40,64}\z/)
        valid_receipts = receipts.is_a?(Hash) &&
                         (receipts.keys - constant(:TERMINAL_PROOF_RECEIPT_KEYS)).empty?
        unless proof.fetch("canonical_action_id") == action_id && valid_owner && valid_receipts &&
               !proof.fetch("outcome").to_s.empty?
          raise @inconsistent_record.new("terminal canonical action proof identity is invalid", path: path)
        end
        payload = proof.reject { |key, _| key == "proof_digest" }
        digest = ::Digest::SHA256.hexdigest(JSON.generate(deep_sort(payload)))
        unless proof.fetch("proof_digest").to_s.match?(/\A[a-f0-9]{64}\z/) &&
               proof.fetch("proof_digest") == digest
          raise @inconsistent_record.new("terminal canonical action proof digest is invalid", path: path)
        end
        proof
      end

      def validate_transition!(existing, replacement, path, action_api: false)
        %w[source policy created_at].each do |key|
          next if existing.fetch(key) == replacement.fetch(key)

          inconsistent!("job #{key} is immutable", path)
        end
        if !existing.fetch("analysis_sha").to_s.empty? &&
           existing.fetch("analysis_sha") != replacement.fetch("analysis_sha")
          inconsistent!("job analysis_sha is immutable once pinned", path)
        end

        old_dispositions = disposition_by_id(existing.fetch("dispositions"))
        new_dispositions = disposition_by_id(replacement.fetch("dispositions"))
        old_dispositions.each do |id, old_value|
          unless new_dispositions[id] == old_value
            inconsistent!("analysis disposition for thesis #{id.inspect} is immutable", path)
          end
        end
        validate_discovery_attempt_transition!(
          existing.fetch("attempts"), replacement.fetch("attempts"), path
        )
        validate_action_transition!(existing.fetch("actions"), replacement.fetch("actions"), path)
        if existing.fetch("actions") != replacement.fetch("actions") && !action_api
          inconsistent!("action changes require the fenced action transition API", path)
        end
        inconsistent!("complete job aggregate is write-once", path) if existing.fetch("complete") && existing != replacement
      end

      def disposition_by_id(dispositions)
        constant(:DISPOSITIONS).each_with_object({}) do |name, indexed|
          dispositions.fetch(name).each do |item|
            indexed[item.fetch("id")] = [ name, item ]
          end
        end
      end

      def strict_hash!(value, required:, allowed:, label:, path:)
        unless value.is_a?(Hash)
          raise @corrupt_record.new("#{label} must be an object", path: path)
        end

        missing = required - value.keys
        unknown = value.keys - allowed
        unless missing.empty?
          raise @corrupt_record.new("#{label} is missing keys #{missing.inspect}", path: path)
        end
        inconsistent!("#{label} has unknown keys #{unknown.inspect}", path) unless unknown.empty?
        value
      end

      private

      def validate_source!(source, path)
        strict_hash!(
          source,
          required: %w[url number repository registration base_branch base_sha merge_sha],
          allowed: constant(:SOURCE_KEYS),
          label: "source",
          path: path
        )
        %w[url repository registration base_branch base_sha merge_sha].each do |key|
          nonempty_string!(source.fetch(key), "source #{key}", path)
        end
        unless source.fetch("number").is_a?(Integer) && source.fetch("number").positive?
          inconsistent!("source number must be a positive integer", path)
        end
        string_array!(source["changed_paths"], "source changed_paths", path) if source.key?("changed_paths")
        timestamp!(source["merged_at"], "source merged_at", path) if source.key?("merged_at")
        if source.key?("manifest_checksum")
          nonempty_string!(source["manifest_checksum"], "source manifest_checksum", path)
        end
      end

      def validate_policy!(policy, path)
        strict_hash!(
          policy,
          required: %w[discovery auto_fix issue_filing],
          allowed: constant(:POLICY_KEYS),
          label: "policy",
          path: path
        )
        %w[discovery auto_fix issue_filing].each do |key|
          inconsistent!("policy #{key} must be boolean", path) unless [ true, false ].include?(policy.fetch(key))
        end
        validate_action_policy!(policy.fetch("action"), path) if policy.key?("action")
        if policy.key?("epoch") && !policy.fetch("epoch").to_s.match?(/\A[a-f0-9]{64}\z/)
          inconsistent!("policy epoch must be a SHA-256 digest", path)
        end
        timestamp!(policy["captured_at"], "policy captured_at", path) if policy.key?("captured_at")
      end

      def validate_action_policy!(action, path)
        strict_hash!(
          action,
          required: constant(:POLICY_ACTION_KEYS),
          allowed: constant(:POLICY_ACTION_KEYS),
          label: "policy action",
          path: path
        )
        %w[default_branch auto_fix_agent].each do |key|
          nonempty_string!(action.fetch(key), "policy action #{key}", path)
        end
        unless %w[low medium high].include?(action.fetch("min_confidence"))
          inconsistent!("policy action min_confidence is invalid", path)
        end

        commands = action.fetch("commands")
        strict_hash!(
          commands,
          required: constant(:POLICY_COMMAND_KEYS),
          allowed: constant(:POLICY_COMMAND_KEYS) + constant(:POLICY_OPTIONAL_COMMAND_KEYS),
          label: "policy action commands",
          path: path
        )
        commands.each do |key, value|
          next if value.nil? || (value.is_a?(String) && !value.strip.empty?)

          inconsistent!("policy action command #{key} must be null or non-empty", path)
        end

        caps = action.fetch("caps")
        strict_hash!(
          caps,
          required: constant(:POLICY_CAP_KEYS),
          allowed: constant(:POLICY_CAP_KEYS),
          label: "policy action caps",
          path: path
        )
        %w[single_feature_only allow_dependency_bumps allow_public_api_changes allow_cross_feature].each do |key|
          unless [ true, false ].include?(caps.fetch(key))
            inconsistent!("policy action cap #{key} must be boolean", path)
          end
        end
        %w[max_files max_diff_lines].each do |key|
          value = caps.fetch(key)
          unless value.is_a?(Integer) && value.positive?
            inconsistent!("policy action cap #{key} must be positive", path)
          end
        end
        score = action.fetch("issue_min_leverage_score")
        unless score.is_a?(Numeric) && score.between?(0, 1)
          inconsistent!("policy action issue_min_leverage_score must be between 0 and 1", path)
        end
      end

      def validate_disposition!(item, name, path)
        strict_hash!(
          item,
          required: %w[id feature_id fingerprint score admissible reasons],
          allowed: constant(:DISPOSITION_KEYS),
          label: "#{name} disposition",
          path: path
        )
        %w[id feature_id fingerprint].each do |key|
          nonempty_string!(item.fetch(key), "disposition #{key}", path)
        end
        inconsistent!("disposition score must be numeric", path) unless item.fetch("score").is_a?(Numeric)
        unless [ true, false ].include?(item.fetch("admissible"))
          inconsistent!("disposition admissible must be boolean", path)
        end
        reasons = string_array!(item.fetch("reasons"), "disposition reasons", path)
        if name == "accepted"
          inconsistent!("accepted disposition cannot have reasons", path) unless reasons.empty?
          inconsistent!("accepted disposition must be admissible", path) unless item.fetch("admissible")
        else
          inconsistent!("#{name} disposition requires reasons", path) if reasons.empty?
        end
        nonempty_string!(item["reference"], "disposition reference", path) if item.key?("reference")
        nonempty_string!(item["family_id"], "disposition family_id", path) if item.key?("family_id")
        validate_thesis_snapshot!(item, path) if item.key?("thesis")
      end

      def validate_thesis_snapshot!(disposition, path)
        thesis = disposition.fetch("thesis")
        unless thesis.is_a?(Hash)
          raise @corrupt_record.new("disposition thesis must be an object", path: path)
        end
        %w[id feature_id fingerprint].each do |key|
          nonempty_string!(thesis[key], "disposition thesis #{key}", path)
        end
        unless thesis.fetch("id") == disposition.fetch("id") &&
               thesis.fetch("feature_id") == disposition.fetch("feature_id") &&
               thesis.fetch("fingerprint") == disposition.fetch("fingerprint")
          inconsistent!("disposition thesis identity does not match its classification", path)
        end
        Thesis.from_h(thesis)
      rescue KeyError, ArgumentError => e
        raise @corrupt_record.new(
          "disposition thesis snapshot is incomplete (#{e.message})", path: path
        )
      end

      def validate_actions!(actions, job_id, fingerprint_by_id, path, repository:)
        seen = {}
        array_of_hashes!(actions, "actions", path).each do |action|
          strict_hash!(
            action,
            required: constant(:ACTION_REQUIRED_KEYS),
            allowed: constant(:ACTION_KEYS),
            label: "action",
            path: path
          )
          %w[canonical_action_id thesis_id thesis_fingerprint kind owner_job_id outcome].each do |key|
            nonempty_string!(action.fetch(key), "action #{key}", path)
          end
          validate_id!(action.fetch("canonical_action_id"))
          inconsistent!("action kind is invalid", path) unless constant(:ACTION_KINDS).include?(action.fetch("kind"))
          unless [ true, false ].include?(action.fetch("terminal"))
            inconsistent!("action terminal must be boolean", path)
          end
          inconsistent!("action receipts must be an object", path) unless action.fetch("receipts").is_a?(Hash)
          validate_publication_receipts!(action, repository, path)
          if (link = action.dig("receipts", "canonical_action_link"))
            validate_terminal_proof!(link, action.fetch("canonical_action_id"), path)
            unless action.fetch("terminal") && action.fetch("outcome") == link.fetch("outcome") &&
                   link.fetch("proof").all? { |key, value| action.fetch("receipts")[key] == value }
              inconsistent!("materialized canonical action proof conflicts with action state", path)
            end
          end
          validate_action_claims!(action, path)
          timestamp!(action.fetch("created_at"), "action created_at", path) if action.key?("created_at")
          timestamp!(action.fetch("updated_at"), "action updated_at", path) if action.key?("updated_at")
          nonempty_string!(action.fetch("family_id"), "action family_id", path) if action.key?("family_id")
          id = action.fetch("canonical_action_id")
          inconsistent!("duplicate canonical action #{id.inspect}", path) if seen[id]
          seen[id] = true
          expected_fingerprint = fingerprint_by_id[action.fetch("thesis_id")]
          unless expected_fingerprint == action.fetch("thesis_fingerprint")
            inconsistent!("action thesis identity is not present in this job", path)
          end
          if action.fetch("owner_job_id") != job_id && !action.fetch("receipts").empty?
            inconsistent!("linked canonical action #{id.inspect} cannot duplicate owner receipts", path)
          end
          if action.fetch("owner_job_id") != job_id && Array(action["claims"]).any?
            inconsistent!("linked canonical action #{id.inspect} cannot own claims", path)
          end
        end
      end

      # Discovery attempts of kind "discovery_claim" feed the same fence as
      # action claims (`active_discovery_attempt` resurrects the newest
      # active entry), so they get the same schema discipline: at most one
      # active attempt, strictly increasing generations, and complete claim
      # shapes. Non-claim attempts (discovery_block/action_block evidence)
      # keep their free-form shape.
      def validate_discovery_attempts!(attempts, path)
        generations = []
        active = 0
        array_of_hashes!(attempts, "attempts", path).each do |attempt|
          next unless attempt["kind"] == constant(:DISCOVERY_ATTEMPT_KIND)

          strict_hash!(
            attempt,
            required: constant(:DISCOVERY_ATTEMPT_KEYS),
            allowed: constant(:DISCOVERY_ATTEMPT_KEYS),
            label: "discovery attempt",
            path: path
          )
          nonempty_string!(attempt.fetch("owner"), "discovery attempt owner", path)
          generation = attempt.fetch("generation")
          unless generation.is_a?(Integer) && generation.positive?
            inconsistent!("discovery attempt generation must be a positive integer", path)
          end
          generations << generation
          unless %w[claimed running released superseded complete].include?(attempt.fetch("state"))
            inconsistent!("discovery attempt state is invalid", path)
          end
          %w[claimed_at heartbeat_at expires_at].each do |key|
            timestamp!(attempt.fetch(key), "discovery attempt #{key}", path)
          end
          timestamp!(attempt["finished_at"], "discovery attempt finished_at", path) if attempt["finished_at"]
          if attempt["next_eligible_at"]
            timestamp!(attempt["next_eligible_at"], "discovery attempt next_eligible_at", path)
          end
          validate_action_process_identity!(attempt, path, label: "discovery attempt")
          active += 1 if constant(:ACTIVE_ACTION_CLAIM_STATES).include?(attempt.fetch("state"))
        end
        unless generations == generations.uniq.sort
          inconsistent!("discovery attempt generations must be strictly increasing", path)
        end
        inconsistent!("job can serialize only one active discovery attempt", path) if active > 1
      end

      def validate_action_claims!(action, path)
        return unless action.key?("claims")

        generations = []
        active = 0
        array_of_hashes!(action.fetch("claims"), "action claims", path).each do |claim|
          strict_hash!(
            claim,
            required: constant(:ACTION_CLAIM_KEYS),
            allowed: constant(:ACTION_CLAIM_KEYS),
            label: "action claim",
            path: path
          )
          nonempty_string!(claim.fetch("owner"), "action claim owner", path)
          generation = claim.fetch("generation")
          unless generation.is_a?(Integer) && generation.positive?
            inconsistent!("action claim generation must be a positive integer", path)
          end
          generations << generation
          unless %w[claimed running released superseded complete].include?(claim.fetch("state"))
            inconsistent!("action claim state is invalid", path)
          end
          unless %w[full continuation_only].include?(claim.fetch("authority"))
            inconsistent!("action claim authority is invalid", path)
          end
          %w[claimed_at heartbeat_at expires_at].each do |key|
            timestamp!(claim.fetch(key), "action claim #{key}", path)
          end
          timestamp!(claim["finished_at"], "action claim finished_at", path) if claim["finished_at"]
          if claim["next_eligible_at"]
            timestamp!(claim["next_eligible_at"], "action claim next_eligible_at", path)
          end
          validate_action_process_identity!(claim, path)
          active += 1 if constant(:ACTIVE_ACTION_CLAIM_STATES).include?(claim.fetch("state"))
        end
        unless generations == generations.uniq.sort
          inconsistent!("action claim generations must be strictly increasing", path)
        end
        inconsistent!("action has multiple active claims", path) if active > 1
        if action.fetch("terminal") && active.positive?
          inconsistent!("terminal action cannot retain an active claim", path)
        end
      end

      def validate_action_process_identity!(claim, path, label: "action claim")
        owner_pid = claim.fetch("owner_pid")
        unless owner_pid.nil? || (owner_pid.is_a?(Integer) && owner_pid.positive?)
          inconsistent!("#{label} owner_pid must be a positive integer or null", path)
        end
        owner_start = claim.fetch("owner_process_start_time")
        unless owner_start.nil? || (owner_start.is_a?(String) && !owner_start.empty?)
          inconsistent!("#{label} owner_process_start_time must be a string or null", path)
        end

        child = [ claim.fetch("pid"), claim.fetch("process_start_time"), claim.fetch("pgid") ]
        if claim.fetch("state") == "running" || child.any?
          valid = child[0].is_a?(Integer) && child[0] > 1 &&
                  child[1].is_a?(String) && !child[1].empty? &&
                  child[2].is_a?(Integer) && child[2] > 1
          inconsistent!("#{label} child identity is incomplete", path) unless valid
        end
      end

      def validate_action_transition!(old_actions, new_actions, path)
        return if old_actions.empty?

        old_by_id = old_actions.to_h { |action| [ action.fetch("canonical_action_id"), action ] }
        new_by_id = new_actions.to_h { |action| [ action.fetch("canonical_action_id"), action ] }
        unless old_by_id.keys.sort == new_by_id.keys.sort
          inconsistent!("initialized action snapshot is immutable", path)
        end

        old_by_id.each do |action_id, old_action|
          new_action = new_by_id.fetch(action_id)
          %w[canonical_action_id thesis_id thesis_fingerprint kind owner_job_id family_id created_at].each do |key|
            next if old_action[key] == new_action[key]

            inconsistent!("canonical action #{action_id.inspect} identity is immutable", path)
          end
          old_action.fetch("receipts").each do |key, value|
            replacement = new_action.fetch("receipts")[key]
            if key == PublicationAttempt::ATTEMPTS_KEY
              validate_publication_attempt_transition!(value, replacement, path)
            elsif replacement != value
              inconsistent!("canonical action #{action_id.inspect} receipt #{key.inspect} is immutable", path)
            end
          end
          if old_action.fetch("terminal") && old_action != new_action
            inconsistent!("terminal canonical action #{action_id.inspect} is write-once", path)
          end
          validate_claim_transition!(old_action, new_action, path)
        end
      end

      # Discovery attempt history obeys the same lifecycle discipline as
      # action claim history: prior generations may only advance through
      # legal claim states, and finished attempts are immutable. Matching by
      # generation keeps the check independent of interleaved block-evidence
      # attempts that share the same array.
      def validate_discovery_attempt_transition!(old_attempts, new_attempts, path)
        old_discovery = old_attempts.select do |attempt|
          attempt["kind"] == constant(:DISCOVERY_ATTEMPT_KIND)
        end
        return if old_discovery.empty?

        new_by_generation = new_attempts.select do |attempt|
          attempt["kind"] == constant(:DISCOVERY_ATTEMPT_KIND)
        end.to_h { |attempt| [ attempt["generation"], attempt ] }
        old_discovery.each do |old_attempt|
          new_attempt = new_by_generation[old_attempt.fetch("generation")]
          inconsistent!("discovery attempt history is append-only", path) unless new_attempt.is_a?(Hash)
          if constant(:ACTIVE_ACTION_CLAIM_STATES).include?(old_attempt.fetch("state"))
            validate_active_claim_transition!(
              old_attempt, new_attempt, path, label: "discovery attempt"
            )
          elsif old_attempt != new_attempt
            inconsistent!("finished discovery attempt is immutable", path)
          end
        end
      end

      def validate_claim_transition!(old_action, new_action, path)
        old_claims = Array(old_action["claims"])
        new_claims = Array(new_action["claims"])
        if new_claims.size < old_claims.size
          inconsistent!("canonical action claim history is append-only", path)
        end

        old_claims.each_with_index do |old_claim, index|
          new_claim = new_claims.fetch(index)
          if constant(:ACTIVE_ACTION_CLAIM_STATES).include?(old_claim.fetch("state"))
            validate_active_claim_transition!(old_claim, new_claim, path)
          elsif old_claim != new_claim
            inconsistent!("finished canonical action claim is immutable", path)
          end
        end
      end

      def validate_publication_receipts!(action, repository, path)
        receipts = action.fetch("receipts")
        attempts = receipts[PublicationAttempt::ATTEMPTS_KEY]
        return unless attempts

        unless action.fetch("kind") == "fix" && attempts.is_a?(Hash) && !attempts.empty?
          inconsistent!("publication attempts require a fix action and non-empty object", path)
        end
        active = 0
        attempts.each do |attempt_id, attempt|
          unless attempt_id.is_a?(String) && attempt_id.match?(/\A[a-f0-9]{64}\z/)
            inconsistent!("publication attempt id is invalid", path)
          end
          strict_hash!(
            attempt,
            required: [ "descriptor" ],
            allowed: [ "descriptor", *PublicationAttempt::PHASES, "superseded" ],
            label: "publication attempt",
            path: path
          )
          descriptor = attempt.fetch("descriptor")
          strict_hash!(
            descriptor,
            required: PublicationAttempt::DESCRIPTOR_KEYS,
            allowed: PublicationAttempt::DESCRIPTOR_KEYS,
            label: "publication attempt descriptor",
            path: path
          )
          patch_key = descriptor.fetch("patch_receipt_key")
          patch = receipts[patch_key]
          expected_id = PublicationAttempt.id_for(
            publication_base_sha: descriptor.fetch("publication_base_sha"),
            commit_sha: descriptor.fetch("commit_sha")
          )
          unless descriptor.fetch("attempt_id") == attempt_id && expected_id == attempt_id &&
                 patch_key.to_s.match?(/\Apatch(?:_[1-9]\d*)?\z/) && patch.is_a?(Hash) &&
                 patch["publication_base_sha"] == descriptor.fetch("publication_base_sha") &&
                 patch["commit_sha"] == descriptor.fetch("commit_sha")
            inconsistent!("publication attempt does not reference its exact patch", path)
          end
          %w[publication_base_sha commit_sha].each do |key|
            unless descriptor.fetch(key).to_s.match?(/\A[a-f0-9]{40,64}\z/)
              inconsistent!("publication attempt #{key} is invalid", path)
            end
          end
          timestamp!(descriptor.fetch("recorded_at"), "publication attempt recorded_at", path)

          PublicationAttempt::PHASES.each do |phase|
            next unless attempt.key?(phase)

            validate_publication_phase!(
              phase,
              attempt.fetch(phase),
              descriptor: descriptor,
              patch: patch,
              action_id: action.fetch("canonical_action_id"),
              repository: repository,
              path: path
            )
          end
          if attempt.key?("pr_create_intent") && !attempt.key?("push_complete")
            inconsistent!("publication PR-create intent requires durable push completion", path)
          end
          if (superseded = attempt["superseded"])
            strict_hash!(
              superseded,
              required: PublicationAttempt::SUPERSEDED_KEYS,
              allowed: PublicationAttempt::SUPERSEDED_KEYS,
              label: "publication supersession",
              path: path
            )
            observed = superseded.fetch("observed_head_sha")
            unless superseded.fetch("reason") == "trunk_drift_retry" &&
                   observed.to_s.match?(/\A[a-f0-9]{40,64}\z/) &&
                   observed != descriptor.fetch("publication_base_sha") &&
                   !attempt.key?("pr_create_intent")
              inconsistent!("publication supersession evidence is invalid", path)
            end
            timestamp!(superseded.fetch("recorded_at"), "publication supersession recorded_at", path)
          else
            active += 1
          end
        end
        inconsistent!("fix action has multiple active publication attempts", path) if active > 1
      end

      def validate_publication_phase!(phase, payload, descriptor:, patch:, action_id:, repository:, path:)
        expected_keys = case phase
        when "push_intent"
          %w[operation canonical_action_id repository branch commit_sha expected_remote_oid]
        when "push_complete"
          %w[operation canonical_action_id repository branch commit_sha remote_oid]
        when "pr_create_intent"
          %w[operation canonical_action_id repository branch commit_sha]
        end
        strict_hash!(
          payload,
          required: expected_keys,
          allowed: expected_keys,
          label: "publication #{phase}",
          path: path
        )
        operation = {
          "push_intent" => "push_branch",
          "push_complete" => "push_branch_complete",
          "pr_create_intent" => "create_pr"
        }.fetch(phase)
        unless payload.fetch("operation") == operation &&
               payload.fetch("canonical_action_id") == action_id &&
               payload.fetch("repository") == repository &&
               payload.fetch("branch") == patch["branch"] &&
               payload.fetch("commit_sha") == descriptor.fetch("commit_sha")
          inconsistent!("publication #{phase} identity is invalid", path)
        end
        if phase == "push_intent"
          expected_oid = payload.fetch("expected_remote_oid")
          unless expected_oid.nil? || expected_oid.to_s.match?(/\A[a-f0-9]{40,64}\z/)
            inconsistent!("publication push_intent expected remote OID is invalid", path)
          end
        elsif phase == "push_complete" && payload.fetch("remote_oid") != descriptor.fetch("commit_sha")
          inconsistent!("publication push_complete remote OID is invalid", path)
        end
      end

      def validate_publication_attempt_transition!(old_attempts, new_attempts, path)
        unless old_attempts.is_a?(Hash) && new_attempts.is_a?(Hash)
          inconsistent!("publication attempt history is append-only", path)
        end
        old_attempts.each do |attempt_id, old_attempt|
          new_attempt = new_attempts[attempt_id]
          unless new_attempt.is_a?(Hash)
            inconsistent!("publication attempt history is append-only", path)
          end
          old_attempt.each do |key, value|
            unless new_attempt[key] == value
              inconsistent!("publication attempt #{attempt_id.inspect} field #{key.inspect} is immutable", path)
            end
          end
          if old_attempt.key?("superseded") && old_attempt != new_attempt
            inconsistent!("superseded publication attempt is write-once", path)
          end
          if !old_attempt.key?("superseded") && new_attempt.key?("superseded") &&
             (new_attempt.keys - old_attempt.keys).sort != [ "superseded" ]
            inconsistent!("publication supersession must be an isolated append", path)
          end
        end
      end

      def validate_active_claim_transition!(old_claim, new_claim, path, label: "canonical action claim")
        immutable = %w[
          owner owner_pid owner_process_start_time generation authority claimed_at
        ]
        immutable.each do |key|
          unless old_claim[key] == new_claim[key]
            inconsistent!("#{label} identity is immutable", path)
          end
        end
        if Time.iso8601(new_claim.fetch("expires_at")) < Time.iso8601(old_claim.fetch("expires_at")) ||
           Time.iso8601(new_claim.fetch("heartbeat_at")) < Time.iso8601(old_claim.fetch("heartbeat_at"))
          inconsistent!("#{label} heartbeat cannot move backwards", path)
        end
        transitions = {
          "claimed" => %w[claimed running released superseded complete],
          "running" => %w[running released superseded complete]
        }
        unless transitions.fetch(old_claim.fetch("state")).include?(new_claim.fetch("state"))
          inconsistent!("#{label} state cannot move backwards", path)
        end
        %w[pid process_start_time pgid finished_at outcome next_eligible_at].each do |key|
          next if old_claim[key].nil? || old_claim[key] == new_claim[key]

          inconsistent!("#{label} evidence is immutable once recorded", path)
        end
      end

      def active_action_claim(action)
        Array(action["claims"]).reverse_each.find do |claim|
          constant(:ACTIVE_ACTION_CLAIM_STATES).include?(claim["state"])
        end
      end

      def array_of_hashes!(value, label, path)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(Hash) }
          raise @corrupt_record.new("#{label} must be an array of objects", path: path)
        end

        value
      end

      def string_array!(value, label, path)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) && !item.empty? }
          raise @corrupt_record.new("#{label} must be an array of non-empty strings", path: path)
        end
        value
      end

      def nonempty_string!(value, label, path)
        inconsistent!("#{label} must be a non-empty string", path) unless value.is_a?(String) && !value.empty?
      end

      def string_or_nil!(value, label, path)
        inconsistent!("#{label} must be a string or null", path) unless value.nil? || value.is_a?(String)
      end

      def timestamp!(value, label, path)
        nonempty_string!(value, label, path)
        Time.iso8601(value)
      rescue ArgumentError
        inconsistent!("#{label} must be an ISO-8601 timestamp", path)
      end

      def deep_sort(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [ key, deep_sort(value.fetch(key)) ] }
        when Array
          value.map { |item| deep_sort(item) }
        else
          value
        end
      end

      def constant(name)
        @contract.const_get(name)
      end

      def inconsistent!(message, path)
        raise @inconsistent_record.new(message, path: path)
      end

      public :deep_sort, :string_array!, :timestamp!
    end
  end
end
