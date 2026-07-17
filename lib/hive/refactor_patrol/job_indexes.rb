module Hive
  module RefactorPatrol
    # Pure projection of authoritative terminal job aggregates. Persistence
    # and rebuild timing remain JobStore responsibilities.
    class JobIndexes
      FINGERPRINT_SCHEMA = "hive-refactor-patrol-fingerprint-index".freeze
      ACTION_SCHEMA = "hive-refactor-patrol-action-index".freeze

      def initialize(schema_version:, dispositions:, inconsistent_record:)
        @schema_version = schema_version
        @dispositions = dispositions
        @inconsistent_record = inconsistent_record
      end

      def project(records)
        fingerprint_entries = {}
        owner_actions = {}
        action_links = []

        records.each do |aggregate|
          next unless aggregate.fetch("complete") == true

          job_id = aggregate.fetch("job_id")
          project_dispositions(aggregate, job_id, fingerprint_entries)
          project_actions(aggregate, job_id, fingerprint_entries, owner_actions, action_links)
        end

        validate_action_links!(owner_actions, action_links)
        normalize_fingerprints!(fingerprint_entries)
        {
          "fingerprints" => {
            "schema" => FINGERPRINT_SCHEMA,
            "schema_version" => @schema_version,
            "fingerprints" => fingerprint_entries.sort.to_h
          },
          "actions" => {
            "schema" => ACTION_SCHEMA,
            "schema_version" => @schema_version,
            "actions" => owner_actions.sort.to_h
          }
        }
      end

      private

      def project_dispositions(aggregate, job_id, fingerprint_entries)
        @dispositions.each do |disposition|
          aggregate.fetch("dispositions").fetch(disposition).each do |item|
            entry = fingerprint_entry(fingerprint_entries, item.fetch("fingerprint"))
            entry.fetch("occurrences") << {
              "job_id" => job_id,
              "thesis_id" => item.fetch("id"),
              "disposition" => disposition
            }
          end
        end
      end

      def project_actions(aggregate, job_id, fingerprint_entries, owner_actions, action_links)
        aggregate.fetch("actions").select { |action| action.fetch("terminal") == true }.each do |action|
          action_id = action.fetch("canonical_action_id")
          if action.fetch("owner_job_id") == job_id
            if owner_actions.key?(action_id)
              raise @inconsistent_record, "canonical action #{action_id.inspect} has multiple owner jobs"
            end
            owner_actions[action_id] = {
              "owner_job_id" => job_id,
              "kind" => action.fetch("kind"),
              "thesis_fingerprint" => action.fetch("thesis_fingerprint"),
              "outcome" => action.fetch("outcome")
            }
          else
            action_links << [ action_id, action.fetch("owner_job_id") ]
          end

          fingerprint_entry(fingerprint_entries, action.fetch("thesis_fingerprint"))
            .fetch("canonical_action_ids") << action_id
        end
      end

      def validate_action_links!(owner_actions, action_links)
        action_links.each do |action_id, owner_job_id|
          owner = owner_actions[action_id]
          next if owner && owner.fetch("owner_job_id") == owner_job_id

          raise @inconsistent_record,
                "canonical action #{action_id.inspect} links to missing owner job #{owner_job_id.inspect}"
        end
      end

      def normalize_fingerprints!(fingerprint_entries)
        fingerprint_entries.each_value do |entry|
          entry.fetch("occurrences").sort_by! { |item| [ item.fetch("job_id"), item.fetch("thesis_id") ] }
          entry["canonical_action_ids"] = entry.fetch("canonical_action_ids").uniq.sort
        end
      end

      def fingerprint_entry(entries, fingerprint)
        entries[fingerprint] ||= { "occurrences" => [], "canonical_action_ids" => [] }
      end
    end
  end
end
