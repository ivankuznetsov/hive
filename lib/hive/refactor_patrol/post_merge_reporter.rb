require "digest"
require "json"
require "time"
require "hive/refactor_patrol/checkout_guard"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    # Finalizes one successful attributed child into the dedicated report and
    # emission ledger before allowing the post-merge checkpoint to advance.
    class PostMergeReporter
      class ReportError < Hive::Error
        attr_reader :reason

        def initialize(reason, message)
          super(message)
          @reason = reason
        end

        def exit_code
          Hive::ExitCodes::TEMPFAIL
        end
      end

      SAFE_ID = /\A[A-Za-z0-9_.-]+\z/

      def initialize(project_root, refactor_state: nil)
        @project_root = File.realpath(project_root)
        @refactor_state = refactor_state || Hive::RefactorPatrol::StateStore.new(@project_root)
      end

      def call(token:, envelope:, state_store:, guard:, snapshot:, now: Time.now)
        # The checkout is revalidated before accepting or persisting any child
        # output. A later atomic-report failure still leaves the merge running;
        # the scheduler turns that attempt back into owed state.
        guard.assert_unchanged!(snapshot)
        result = build(token: token, envelope: envelope, state_store: state_store, now: now)
        state_store.complete!(
          token.fetch("identity"),
          report: result.fetch(:report),
          emission_digests: result.fetch(:emission_digests),
          now: now
        )
        result.fetch(:report)
      end

      def build(token:, envelope:, state_store:, now: Time.now)
        validate_envelope!(token, envelope)
        merge = state_store.merge_record(token.fetch("identity"))
        validate_token_identity!(token, merge)
        baseline = merge.fetch("fingerprint_snapshot") || {}
        classifications = classifications(envelope, baseline)
        previous = state_store.emissions.dig(token.fetch("identity"), "digests") || {}
        digests = classifications.to_h { |item| [ item.fetch(:thesis).fingerprint, item.fetch(:content_digest) ] }
        emitted = classifications.filter_map do |item|
          thesis = item.fetch(:thesis)
          digest = item.fetch(:content_digest)
          next if previous[thesis.fingerprint] == digest

          {
            "fingerprint" => thesis.fingerprint,
            "bucket" => item.fetch(:bucket),
            "content_digest" => digest,
            "thesis_id" => thesis.id
          }
        end

        report = {
          "schema" => "hive-refactor-patrol-post-merge",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol-post-merge"),
          "completion_status" => "success",
          "project" => token.fetch("project"),
          "project_root" => @project_root,
          "pr_number" => token.fetch("pr_number"),
          "merge_sha" => token.fetch("merge_sha"),
          "base_sha" => token.fetch("base_sha"),
          "analysis_sha" => token.fetch("pinned_head"),
          "changed_paths" => Array(token.fetch("changed_paths")).map(&:to_s).uniq,
          "scope" => token.fetch("scope"),
          "totals" => bucket_totals(classifications),
          "flagged_theses" => classifications.filter_map { |item| flagged_detail(item) },
          "emitted_delta" => emitted,
          "started_at" => token.fetch("started_at"),
          "completed_at" => now.utc.iso8601
        }
        { report: report, emission_digests: digests }
      end

      private

      def validate_envelope!(token, envelope)
        valid = envelope.is_a?(Hash) &&
                envelope["schema"] == "hive-refactor-patrol" &&
                envelope["schema_version"] == Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-refactor-patrol") &&
                envelope["ok"] == true && envelope["dry_run"] == false &&
                envelope["project"] == token["project"] &&
                canonical_path(envelope["project_root"]) == @project_root &&
                envelope["last_scanned_sha"] == token["pinned_head"] &&
                envelope["ranked"].is_a?(Array) &&
                envelope["flagged_theses"].is_a?(Array) &&
                envelope["suppressed"].is_a?(Array)
        raise ReportError.new("invalid_envelope", "post-merge child envelope does not match its dispatch token") unless valid
      end

      def canonical_path(path)
        return unless path.is_a?(String) && !path.empty?

        File.realpath(path.to_s)
      rescue SystemCallError
        File.expand_path(path.to_s)
      end

      def validate_token_identity!(token, merge)
        %w[pr_number merge_sha base_sha changed_paths].each do |key|
          expected = key == "changed_paths" ? Array(merge[key]) : merge[key]
          actual = key == "changed_paths" ? Array(token[key]) : token[key]
          next if expected == actual

          raise ReportError.new("identity_mismatch", "post-merge dispatch token changed #{key}")
        end
        unless token["analysis_root"] == @project_root
          raise ReportError.new("identity_mismatch", "post-merge analysis root changed")
        end
      end

      def classifications(envelope, baseline)
        ranked_ids = ids_from(envelope.fetch("ranked"))
        flagged_ids = ids_from(envelope.fetch("flagged_theses"))
        suppressed = envelope.fetch("suppressed").to_h { |item| [ item.fetch("id"), item ] }
        ids = (ranked_ids + flagged_ids + suppressed.keys).uniq
        theses = ids.to_h { |id| [ id, read_thesis!(id) ] }

        ids.map do |id|
          thesis = theses.fetch(id)
          bucket, reason = bucket_for(
            id: id,
            thesis: thesis,
            flagged_ids: flagged_ids,
            suppression: suppressed[id],
            baseline: baseline
          )
          {
            thesis: thesis,
            bucket: bucket,
            reason: reason,
            content_digest: content_digest(thesis, bucket, reason)
          }
        end
      rescue KeyError => e
        raise ReportError.new("invalid_envelope", "post-merge result is missing #{e.key.inspect}")
      end

      def ids_from(items)
        items.map { |item| item.fetch("id") }.tap do |ids|
          unless ids.all? { |id| id.is_a?(String) && id.match?(SAFE_ID) }
            raise ReportError.new("invalid_envelope", "post-merge result contains an unsafe thesis id")
          end
        end
      end

      def read_thesis!(id)
        unless id.match?(SAFE_ID)
          raise ReportError.new("invalid_envelope", "post-merge result contains an unsafe thesis id")
        end

        path = File.join(@refactor_state.root, "theses", "#{id}.json")
        payload = JSON.parse(File.read(path))
        thesis = Hive::RefactorPatrol::Thesis.from_h(payload)
        raise ReportError.new("thesis_identity_mismatch", "post-merge thesis id does not match its file") unless thesis.id == id

        thesis
      rescue ReportError
        raise
      rescue JSON::ParserError, SystemCallError, KeyError => e
        raise ReportError.new("thesis_missing", "post-merge thesis #{id.inspect} is unavailable: #{e.message}")
      end

      def bucket_for(id:, thesis:, flagged_ids:, suppression:, baseline:)
        if suppression
          reason = suppression.fetch("reason").to_s
          # If this fingerprint was absent before the first logical attempt,
          # an `already_seen` collision on retry came from that interrupted
          # attempt itself. Recover its intrinsic accepted/flagged category.
          if reason.start_with?("collision_already") && !baseline.key?(thesis.fingerprint)
            return [ intrinsic_bucket(thesis), "recovered_interrupted_attempt" ]
          end
          return [ "suppressed", reason ]
        end
        return [ "flagged", thesis.admissibility_reason.to_s ] if flagged_ids.include?(id)

        [ "accepted", "accepted" ]
      end

      def intrinsic_bucket(thesis)
        thesis.admissible == true && Array(thesis.risk["flags"]).empty? ? "accepted" : "flagged"
      end

      def content_digest(thesis, bucket, reason)
        payload = {
          "bucket" => bucket,
          "reason" => reason,
          "feature_id" => thesis.feature_id,
          "problem" => thesis.problem,
          "cost" => thesis.cost,
          "evidence" => thesis.evidence,
          "proposed_refactor" => thesis.proposed_refactor,
          "feature_boundary" => thesis.feature_boundary,
          "expected_leverage" => thesis.expected_leverage,
          "confidence" => thesis.confidence,
          "risk" => thesis.risk,
          "required_validation" => thesis.required_validation,
          "admissible" => thesis.admissible,
          "admissibility_reason" => thesis.admissibility_reason
        }
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def bucket_totals(classifications)
        counts = classifications.group_by { |item| item.fetch(:bucket) }.transform_values(&:size)
        {
          "accepted" => counts.fetch("accepted", 0),
          "flagged" => counts.fetch("flagged", 0),
          "suppressed" => counts.fetch("suppressed", 0)
        }
      end

      def flagged_detail(item)
        return unless item.fetch(:bucket) == "flagged"

        thesis = item.fetch(:thesis)
        {
          "id" => thesis.id,
          "fingerprint" => thesis.fingerprint,
          "content_digest" => item.fetch(:content_digest),
          "problem" => thesis.problem,
          "proposed_refactor" => thesis.proposed_refactor,
          "evidence" => Array(thesis.evidence),
          "feature_boundary" => thesis.feature_boundary,
          "risk" => thesis.risk,
          "admissibility_reason" => thesis.admissibility_reason.to_s,
          "expected_leverage" => thesis.expected_leverage,
          "required_validation" => thesis.required_validation
        }
      end
    end
  end
end
