require "hive/patrol_fix"
require "hive/patrol_fix/publication_receipt"

module Hive
  module PatrolFix
    module Migration
      # Pure reconciliation over injected task/local/remote observations.
      # Routes describe U9's eventual disposition; this preflight never acts.
      class Reconciler
        OBSERVATION_KEYS = %w[
          kind identity state match canonical_digest details
        ].freeze
        DIGEST = /\A[0-9a-f]{64}\z/
        MAX_OBSERVATIONS_PER_GROUP = 4_096
        MAX_OBSERVATION_DETAILS_BYTES = 128 * 1024

        class InvalidReconciliation < Hive::Error; end

        def initialize(observation_port: ->(_group) { [] })
          @observation_port = observation_port
        end

        def reconcile(groups:, candidates:)
          candidate_map = Array(candidates).to_h { |entry| [ source_ref(entry), entry ] }
          seen_members = {}
          dispositions = []
          observation_dispositions = []
          reconciled_groups = Array(groups).map do |group|
            members = group.fetch("members")
            member_candidates = members.map do |ref|
              invalid!("semantic group repeats a source") if seen_members[ref]
              seen_members[ref] = true
              candidate_map.fetch(ref) do
                invalid!("semantic group references an unknown source")
              end
            end
            observations = collect_observations(group, member_candidates)
            decision = canonical_decision(
              member_candidates, observations,
              semantic_route: group.dig("semantic_decision", "route")
            )
            members.each do |ref|
              candidate = candidate_map.fetch(ref)
              dispositions << {
                "source_kind" => candidate.fetch("source_kind"),
                "source_id" => candidate.fetch("source_id"),
                "source_schema" => candidate.fetch("source_schema"),
                "canonical_digest" => candidate.fetch("canonical_digest"),
                "group_id" => group.fetch("group_id"),
                "route" => decision.fetch("route"),
                "canonical_identity" => decision.fetch("canonical_identity"),
                "blocking_reason" => candidate.fetch("blocking_reason") ||
                  blocking_reason(decision.fetch("route"))
              }
            end
            observation_dispositions.concat(observations.map do |observation|
              observation_disposition(group, observation, decision: decision)
            end)
            PatrolFix.deep_copy(group).merge("canonical_decision" => decision)
          rescue KeyError => error
            invalid!("migration reconciliation is missing #{error.key.inspect}")
          end
          unless seen_members.keys.sort == candidate_map.keys.sort
            invalid!("migration reconciliation omitted a source")
          end
          {
            "groups" => reconciled_groups.sort_by { |group| group.fetch("group_id") },
            "dispositions" => dispositions.sort_by { |entry| source_ref(entry) },
            "observation_dispositions" => observation_dispositions.sort_by do |entry|
              [ entry.fetch("kind"), entry.fetch("identity") ]
            end
          }
        end

        private

        def collect_observations(group, candidates)
          supplied = Array(@observation_port.call(PatrolFix.deep_copy(group)))
          combined = candidates.flat_map { |entry| entry.fetch("observations") } + supplied
          invalid!("migration semantic group has too many observations") if
            combined.length > MAX_OBSERVATIONS_PER_GROUP
          by_identity = {}
          combined.each do |observation|
            normalized = validate_observation(observation)
            key = [ normalized.fetch("kind"), normalized.fetch("identity") ]
            if by_identity.key?(key) && by_identity.fetch(key) != normalized
              invalid!("migration observation identity has conflicting bytes")
            end
            by_identity[key] = normalized
          end
          by_identity.values.sort_by { |entry| [ entry.fetch("kind"), entry.fetch("identity") ] }
        end

        def validate_observation(observation)
          valid = observation.is_a?(Hash) && observation.keys.sort == OBSERVATION_KEYS.sort &&
            %w[kind identity state match].all? do |key|
              observation[key].is_a?(String) && !observation[key].empty? &&
                observation[key].bytesize <= (key == "identity" ? 4_096 : 128)
            end && observation["canonical_digest"].is_a?(String) &&
            observation["canonical_digest"].match?(DIGEST) &&
            observation["details"].is_a?(Hash) &&
            PatrolFix.canonical_json(observation["details"]).bytesize <=
              MAX_OBSERVATION_DETAILS_BYTES
          invalid!("migration observation is invalid") unless valid
          validate_exact_publication!(observation) if
            observation.fetch("kind") == "pull_request" &&
              observation.fetch("match") == "exact"
          PatrolFix.deep_freeze(PatrolFix.deep_copy(observation))
        rescue JSON::GeneratorError, JSON::NestingError, TypeError
          invalid!("migration observation is invalid")
        end

        def validate_exact_publication!(observation)
          payload = PublicationReceipt.validate_payload!(
            observation.fetch("details").fetch("publication")
          )
          unless payload.fetch("id") == observation.fetch("identity") &&
                 payload.fetch("state") == observation.fetch("state")
            invalid!("exact migration pull request identity is inconsistent")
          end
        rescue KeyError, PublicationReceipt::InvalidPublication
          invalid!("exact migration pull request lacks a canonical publication receipt")
        end

        def canonical_decision(candidates, observations, semantic_route:)
          exact_prs = observations.select do |entry|
            entry.fetch("kind") == "pull_request" &&
              entry.fetch("match") == "exact"
          end
          exact_tasks = observations.select do |entry|
            entry.fetch("kind") == "patrol_fix_task" &&
              entry.fetch("match") == "exact"
          end
          exact_successors = observations.select do |entry|
            entry.fetch("kind") == "coding_successor" &&
              entry.fetch("match") == "exact"
          end
          route, identity = if semantic_route == "semantic_decision_required"
            [ "blocked_semantic_decision", nil ]
          elsif semantic_route == "insufficient_evidence"
            [ "blocked_semantic_evidence", nil ]
          elsif candidates.any? { |entry| entry.fetch("authority_state") == "blocked" }
            [ "blocked_source", nil ]
          elsif (claim = observations.find { |entry| entry.fetch("kind") == "claim" &&
                                                    %w[claimed running live].include?(entry.fetch("state")) })
            [ "wait_live_claim", claim.fetch("identity") ]
          elsif observations.any? { |entry| entry.fetch("kind") == "pull_request" &&
                                            %w[wrong_head foreign_branch repository_drift multiple uncertain].include?(entry.fetch("match")) }
            [ "blocked_remote_conflict", nil ]
          elsif observations.any? { |entry| entry.fetch("match") == "uncertain" }
            [ "blocked_artifact_conflict", nil ]
          elsif exact_prs.length > 1
            [ "blocked_remote_conflict", nil ]
          elsif exact_tasks.length > 1 || exact_successors.length > 1
            [ "blocked_ownership_conflict", nil ]
          elsif (pr = exact_prs.find { |entry|
                  %w[open draft closed merged].include?(entry.fetch("state"))
                })
            [ "done_existing_pr", pr.fetch("identity") ]
          elsif (task = observations.find { |entry| entry.fetch("kind") == "patrol_fix_task" &&
                                                   entry.fetch("match") == "exact" })
            [ "retain_patrol_fix_task", task.fetch("identity") ]
          elsif (successor = observations.find { |entry| entry.fetch("kind") == "coding_successor" &&
                                                        entry.fetch("match") == "exact" })
            [ "reuse_linked_successor", successor.fetch("identity") ]
          elsif (intent = observations.find { |entry| entry.fetch("kind") == "publication_intent" })
            [ "recover_publication", intent.fetch("identity") ]
          elsif (patch = observations.find { |entry| entry.fetch("kind") == "validated_patch" })
            [ "resume_validate", patch.fetch("identity") ]
          else
            [ "create_or_attach_inbox", nil ]
          end
          {
            "route" => route,
            "canonical_identity" => identity,
            "planned_mutations" => [],
            "observation_ids" => observations.map { |entry| entry.fetch("identity") }.uniq.sort
          }
        end

        def observation_disposition(group, observation, decision:)
          return {
            "group_id" => group.fetch("group_id"),
            "kind" => observation.fetch("kind"),
            "identity" => observation.fetch("identity"),
            "canonical_digest" => observation.fetch("canonical_digest"),
            "route" => "block_reconciliation"
          } if decision.fetch("route") == "blocked_artifact_conflict"

          route = case observation.fetch("kind")
          when "pull_request"
            if observation.fetch("match") == "exact" &&
               decision.fetch("route") != "blocked_remote_conflict"
              "adopt_read_only"
            else
              "block_adoption"
            end
          when "issue"
            "link_read_only"
          when "claim"
            "wait_for_release"
          when "coding_task", "coding_successor"
            decision.fetch("route") == "blocked_ownership_conflict" ?
              "block_binding" : "link_read_only"
          when "publication_intent"
            "recover_before_retry"
          when "validated_patch", "branch"
            "reconcile_custody"
          else
            "retain_read_only"
          end
          {
            "group_id" => group.fetch("group_id"),
            "kind" => observation.fetch("kind"),
            "identity" => observation.fetch("identity"),
            "canonical_digest" => observation.fetch("canonical_digest"),
            "route" => route
          }
        end

        def blocking_reason(route)
          case route
          when "blocked_semantic_decision" then "semantic decision is required"
          when "blocked_semantic_evidence" then "semantic evidence is insufficient"
          when "wait_live_claim" then "legacy source claim is live"
          when "blocked_remote_conflict" then "remote effect cannot be adopted safely"
          when "blocked_artifact_conflict" then "local artifact evidence conflicts"
          when "blocked_ownership_conflict" then "multiple owned artifacts claim one semantic group"
          end
        end

        def source_ref(entry)
          "#{entry.fetch('source_kind')}:#{entry.fetch('source_id')}"
        end

        def invalid!(message)
          raise InvalidReconciliation, message.to_s[0, 512]
        end
      end
    end
  end
end
