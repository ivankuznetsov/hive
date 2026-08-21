require "set"
require "hive/artifacts/outcome_evidence/document"
require "hive/artifacts/outcome_evidence/identity"
require "hive/artifacts/outcome_evidence/proof"
require "hive/secret_patterns"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Semantic admission around the byte-level Proof contract. Agents
      # propose claims and verdicts; controller code decides publication.
      module Contract
        MAX_CLAIMS = 5
        MAX_EXCLUSIONS = 16
        MAX_STATEMENT_BYTES = 1024
        VAGUE = %w[
          works-as-expected various-changes updated-files changes-are-correct
          looks-good feature-works
        ].freeze

        module_function

        def requirement!(implementation:, claims:, exclusions:, inference:)
          changed_paths = Array(implementation.fetch("changed_paths")).map do |path|
            Identity.validate_changed_path!(path)
          end
          raise StoreError, "implementation changed paths must be nonempty" if changed_paths.empty?

          canonical_claims = canonical_targets(claims, kind: :claim)
          canonical_exclusions = canonical_targets(exclusions, kind: :exclusion)
          raise StoreError, "outcome evidence requires at least one bounded claim" if canonical_claims.empty?

          ids = (canonical_claims + canonical_exclusions).map { |item| item.fetch("id") }
          raise StoreError, "claim and exclusion IDs must be unique" unless ids.uniq == ids

          known = changed_paths.to_set
          traced = Hash.new { |hash, key| hash[key] = [] }
          (canonical_claims + canonical_exclusions).each do |item|
            item.fetch("changed_paths").each do |path|
              raise StoreError, "traceability names a path outside the frozen diff: #{path}" unless known.include?(path)

              traced[path] << item.fetch("id")
            end
          end
          missing = changed_paths.reject { |path| traced.key?(path) }
          unless missing.empty?
            raise StoreError, "every frozen changed path needs a claim or supported exclusion: #{missing.join(', ')}"
          end

          {
            "claims" => canonical_claims,
            "exclusions" => canonical_exclusions,
            "traceability" => changed_paths.sort.to_h { |path| [ path, traced.fetch(path).sort ] },
            "inference" => actor!(inference, "inference")
          }
        rescue KeyError => e
          raise StoreError, "outcome-evidence requirement is missing #{e.key}"
        end

        def review!(requirement:, evidence:, producer:, reviewer:, output:)
          inference = actor!(requirement.fetch("inference"), "inference")
          producer = actor!(producer, "producer")
          reviewer = actor!(reviewer, "reviewer")
          context_ids = [ inference, producer, reviewer ].map { |actor| actor.fetch("context_id") }
          unless context_ids.uniq.length == 3
            raise StoreError, "inference, producer, and reviewer must use distinct fresh contexts"
          end

          entries = Array(evidence)
          claims = requirement.fetch("claims")
          claim_by_id = claims.to_h { |item| [ item.fetch("id"), item ] }
          covered = Hash.new(0)
          expected_hashes = []
          entries.each do |entry|
            kind = entry.fetch("kind").to_s
            Array(entry.fetch("claims")).each do |claim_id|
              claim = claim_by_id[claim_id.to_s]
              raise StoreError, "evidence names unknown claim #{claim_id.inspect}" unless claim
              unless claim.fetch("proof_kind") == kind
                raise StoreError, "claim #{claim_id} requires #{claim.fetch('proof_kind')} proof, not #{kind}"
              end
              covered[claim.fetch("id")] += 1
            end
            Array(entry.fetch("representations")).each do |representation|
              expected_hashes << representation.fetch("sha256").to_s.downcase
            end
          end
          uncovered = claim_by_id.keys.reject { |id| covered[id].positive? }

          output = object!(output, "review output")
          reject_unknown!(output, %w[review_scope_hashes verdicts], "review output")
          review_scope = Array(output.fetch("review_scope_hashes")).map { |value| digest!(value) }.uniq.sort
          unless review_scope == expected_hashes.uniq.sort
            raise StoreError, "controller review scope must name every representation hash"
          end
          target_ids = (claims + requirement.fetch("exclusions")).map { |item| item.fetch("id") }.sort
          verdicts = Array(output.fetch("verdicts")).map { |item| verdict!(item) }
          unless verdicts.map { |item| item.fetch("target_id") }.sort == target_ids
            raise StoreError, "reviewer must return exactly one verdict per claim and exclusion"
          end
          verdict_by_target = verdicts.to_h { |item| [ item.fetch("target_id"), item ] }
          accepted_without_proof = uncovered.select do |claim_id|
            verdict_by_target.fetch(claim_id).fetch("verdict") == "accepted"
          end
          unless accepted_without_proof.empty?
            raise StoreError,
                  "reviewer cannot accept a claim without admitted proof: " \
                  "#{accepted_without_proof.join(', ')}"
          end

          status = if verdicts.any? { |item| item.fetch("verdict") == "blocked" }
            "blocked"
          elsif verdicts.any? { |item| item.fetch("verdict") == "revise" }
            "revise"
          else
            "accepted"
          end
          {
            "producer" => producer,
            "reviewer" => reviewer,
            "review_scope_hashes" => review_scope,
            "verdicts" => verdicts.sort_by { |item| item.fetch("target_id") },
            "status" => status,
            "accepted" => status == "accepted"
          }
        rescue KeyError => e
          raise StoreError, "outcome-evidence review is missing #{e.key}"
        end

        def canonical_targets(value, kind:)
          items = Array(value)
          limit = kind == :claim ? MAX_CLAIMS : MAX_EXCLUSIONS
          if items.length > limit
            raise StoreError, "outcome evidence supports at most #{limit} #{kind}s"
          end

          items.map do |raw|
            item = object!(raw, kind.to_s)
            allowed = %w[id statement changed_paths]
            allowed << "proof_kind" if kind == :claim
            allowed << "reason" if kind == :exclusion
            reject_unknown!(item, allowed, kind.to_s)
            result = {
              "id" => safe_id!(item.fetch("id"), "#{kind} ID"),
              "statement" => meaningful!(item.fetch("statement"), "#{kind} statement"),
              "changed_paths" => canonical_paths!(item.fetch("changed_paths"), kind)
            }
            if kind == :claim
              proof_kind = item.fetch("proof_kind").to_s
              unless Proof::KINDS.include?(proof_kind)
                raise StoreError, "claim has unsupported proof kind #{proof_kind.inspect}"
              end
              result["proof_kind"] = proof_kind
            else
              result["reason"] = meaningful!(item.fetch("reason"), "exclusion reason")
            end
            result
          end.sort_by { |item| item.fetch("id") }
        rescue KeyError => e
          raise StoreError, "#{kind} is missing #{e.key}"
        end
        private_class_method :canonical_targets

        def canonical_paths!(value, kind)
          paths = Array(value).map { |path| Identity.validate_changed_path!(path) }
          unless paths.any? && paths.uniq.length == paths.length
            raise StoreError, "#{kind} changed paths must be nonempty and unique"
          end
          paths.sort
        end
        private_class_method :canonical_paths!

        def meaningful!(value, label)
          text = value.to_s.strip
          words = text.scan(/[[:alnum:]]+/)
          normalized = words.join("-").downcase
          if text.bytesize > MAX_STATEMENT_BYTES || words.length < 4 || VAGUE.include?(normalized)
            raise StoreError, "#{label} must be a meaningful bounded explanation"
          end
          secret_free!(text, label)
        end
        private_class_method :meaningful!

        def secret_free!(text, label)
          hits = Hive::SecretPatterns.scan(text)
          return text if hits.empty?

          names = hits.map { |hit| hit.fetch(:name) }.uniq.join(", ")
          raise StoreError, "#{label} contains secret-shaped content: #{names}"
        end

        def actor!(value, label)
          actor = object!(value, label)
          reject_unknown!(actor, %w[context_id agent model effort], label)
          {
            "context_id" => safe_id!(actor.fetch("context_id"), "#{label} context ID"),
            "agent" => safe_id!(actor.fetch("agent"), "#{label} agent"),
            "model" => bounded_identity!(actor.fetch("model", "provider-default"), "#{label} model"),
            "effort" => bounded_identity!(actor.fetch("effort", "default"), "#{label} effort")
          }
        rescue KeyError => e
          raise StoreError, "#{label} identity is missing #{e.key}"
        end
        private_class_method :actor!

        # Validate reviewer verdicts without persisting anything. A controller
        # can then surface a contract violation to the reviewer as a repair
        # round, rather than discovering it during the append that ends the
        # stage — an over-long or vague reason is precisely what one more
        # reviewer turn fixes.
        def verdicts!(value, label = "review output")
          output = object!(value, label)
          Array(output.fetch("verdicts")).map { |item| verdict!(item) }
        rescue KeyError => e
          raise StoreError, "#{label} is missing #{e.key}"
        end

        def verdict!(value)
          verdict = object!(value, "review verdict")
          reject_unknown!(verdict, %w[target_id verdict reason], "review verdict")
          result = verdict.fetch("verdict").to_s
          unless %w[accepted revise blocked].include?(result)
            raise StoreError, "review verdict must be accepted, revise, or blocked"
          end

          {
            "target_id" => safe_id!(verdict.fetch("target_id"), "review target ID"),
            "verdict" => result,
            "reason" => meaningful!(verdict.fetch("reason"), "review verdict reason")
          }
        rescue KeyError => e
          raise StoreError, "review verdict is missing #{e.key}"
        end
        private_class_method :verdict!

        def safe_id!(value, label)
          text = value.to_s
          raise StoreError, "#{label} is unsafe" unless text.match?(Proof::SAFE_CLAIM)
          text
        end
        private_class_method :safe_id!

        def bounded_identity!(value, label)
          text = value.to_s
          if text.empty? || text.bytesize > 128 || !text.valid_encoding? || text.match?(/[[:cntrl:]]/)
            raise StoreError, "#{label} is invalid"
          end
          text
        end
        private_class_method :bounded_identity!

        def digest!(value)
          text = value.to_s.downcase
          raise StoreError, "review scope hash is invalid" unless text.match?(Proof::DIGEST)
          text
        end
        private_class_method :digest!

        def object!(value, label)
          raise StoreError, "#{label} must be an object" unless value.respond_to?(:to_h)
          value.to_h.transform_keys(&:to_s)
        end
        private_class_method :object!

        def reject_unknown!(object, allowed, label)
          unknown = object.keys - allowed
          raise StoreError, "#{label} contains unknown keys: #{unknown.sort.join(', ')}" unless unknown.empty?
        end
        private_class_method :reject_unknown!
      end
    end
  end
end
