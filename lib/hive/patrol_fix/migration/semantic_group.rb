require "digest"
require "hive/patrol_fix"

module Hive
  module PatrolFix
    module Migration
      # Provider-free grouping for preflight. Exact source-owned roots group
      # directly; ambiguous roots join only through an injected, already
      # durable admission decision observation.
      module SemanticGroup
        module_function

        DIGEST = /\A[0-9a-f]{64}\z/
        DECISION_KEYS = %w[
          left right decision receipt_digest candidate_set_digest current_head
        ].freeze
        DECISIONS = %w[same_root distinct insufficient_evidence].freeze
        REVISION = /\A[0-9a-f]{40}\z/

        class InvalidGroup < Hive::Error; end

        def build(candidates, semantic_decisions: [])
          values = Array(candidates)
          by_ref = values.to_h { |entry| [ source_ref(entry), entry ] }
          invalid!("semantic grouping contains duplicate sources") unless by_ref.length == values.length
          candidate_set_digest = Digest::SHA256.hexdigest(
            PatrolFix.canonical_json(by_ref.keys.sort.map do |ref|
              [ ref, by_ref.fetch(ref).fetch("canonical_digest") ]
            end)
          )
          parent = by_ref.keys.to_h { |ref| [ ref, ref ] }

          values.group_by { |entry| entry["semantic_root"] }.each do |root, members|
            next if root.nil?

            refs = members.map { |entry| source_ref(entry) }.sort
            refs.drop(1).each { |ref| union(parent, refs.first, ref) }
          end

          Array(semantic_decisions).each do |decision|
            validate_decision!(decision, by_ref, candidate_set_digest)
            next unless decision.fetch("decision") == "same_root"

            left = decision.fetch("left")
            right = decision.fetch("right")
            union(parent, left, right)
          end
          heads = Array(semantic_decisions).map { |entry| entry.fetch("current_head") }.uniq
          invalid!("semantic decision observations bind different current heads") if heads.length > 1

          raw_groups = by_ref.keys.group_by { |ref| find(parent, ref) }.values
          root_by_ref = raw_groups.each_with_object({}) do |members, result|
            root = members.sort.first
            members.each { |ref| result[ref] = root }
          end
          distinct_neighbors = Hash.new { |hash, key| hash[key] = {} }
          Array(semantic_decisions).each do |decision|
            next unless decision.fetch("decision") == "distinct"

            left_root = root_by_ref.fetch(decision.fetch("left"))
            right_root = root_by_ref.fetch(decision.fetch("right"))
            invalid!("a distinct semantic decision conflicts with a same-root group") if
              left_root == right_root
            distinct_neighbors[left_root][right_root] = true
            distinct_neighbors[right_root][left_root] = true
          end

          groups = raw_groups.map do |members|
            sorted = members.sort
            injected = Array(semantic_decisions).select do |decision|
              decision.fetch("decision") == "same_root" &&
                sorted.include?(decision.fetch("left")) &&
                sorted.include?(decision.fetch("right"))
            end
            candidate_projection = sorted.map do |ref|
              [ ref, by_ref.fetch(ref).fetch("canonical_digest") ]
            end
            group_candidate_digest = Digest::SHA256.hexdigest(
              PatrolFix.canonical_json(candidate_projection)
            )
            group_digest = Digest::SHA256.hexdigest(
              PatrolFix.canonical_json("members" => sorted,
                                       "candidate_set_digest" => group_candidate_digest)
            )
            relevant = Array(semantic_decisions).select do |decision|
              sorted.include?(decision.fetch("left")) ||
                sorted.include?(decision.fetch("right"))
            end
            route = if relevant.any? { |entry| entry.fetch("decision") == "insufficient_evidence" }
              "insufficient_evidence"
            elsif injected.any?
              "injected_same_root"
            elsif raw_groups.length == 1
              "exact_root"
            elsif distinct_neighbors.fetch(sorted.first, {}).length == raw_groups.length - 1
              "injected_distinct"
            else
              "semantic_decision_required"
            end
            {
              "group_id" => "group-#{group_digest[0, 32]}",
              "candidate_set_digest" => group_candidate_digest,
              "members" => sorted,
              "canonical_source" => sorted.first,
              "semantic_decision" => {
                "route" => route,
                "inventory_candidate_set_digest" => candidate_set_digest,
                "current_head" => relevant.first&.fetch("current_head"),
                "receipt_digests" => relevant.map { |entry| entry.fetch("receipt_digest") }.uniq.sort
              }
            }
          end
          PatrolFix.deep_freeze(groups.sort_by { |group| group.fetch("group_id") })
        end

        def source_ref(entry)
          "#{entry.fetch('source_kind')}:#{entry.fetch('source_id')}"
        rescue KeyError
          invalid!("semantic grouping source is invalid")
        end

        def validate_decision!(decision, by_ref, candidate_set_digest)
          valid = decision.is_a?(Hash) && decision.keys.sort == DECISION_KEYS.sort &&
            by_ref.key?(decision["left"]) && by_ref.key?(decision["right"]) &&
            decision["left"] != decision["right"] &&
            DECISIONS.include?(decision["decision"]) &&
            decision["receipt_digest"].is_a?(String) &&
            decision["receipt_digest"].match?(DIGEST) &&
            decision["candidate_set_digest"] == candidate_set_digest &&
            decision["current_head"].is_a?(String) &&
            decision["current_head"].match?(REVISION)
          invalid!("semantic decision observation is invalid") unless valid
        end
        private_class_method :validate_decision!

        def find(parent, ref)
          cursor = ref
          cursor = parent.fetch(cursor) while parent.fetch(cursor) != cursor
          cursor
        end
        private_class_method :find

        def union(parent, left, right)
          left_root = find(parent, left)
          right_root = find(parent, right)
          return if left_root == right_root

          canonical, alias_ref = [ left_root, right_root ].sort
          parent[alias_ref] = canonical
        end
        private_class_method :union

        def invalid!(message)
          raise InvalidGroup, message.to_s[0, 512]
        end
        private_class_method :invalid!
      end
    end
  end
end
