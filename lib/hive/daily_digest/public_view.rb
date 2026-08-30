require "hive/daily_digest/materiality"

module Hive
  module DailyDigest
    # Closed, privacy-specific projection shared by every digest output sink.
    # Store records remain auditable, while CLI/Web/Telegram only receive the
    # fields that are safe and useful to an operator.
    module PublicView
      PROJECT_KEYS = %w[project_id registration_id name repository_identity historical].freeze
      FACT_KEYS = %w[
        fact_id kind category summary project_id project task_id task_slug stage state
        occurred_at observed_at source task_url
      ].freeze
      ATTENTION_KEYS = %w[
        attention_id kind project_id project task_id task_slug stage state
        waiting_since waiting_age_seconds task_url
      ].freeze
      GAP_KEYS = %w[
        gap_id source scope reason_code reason observed_at freshness_at
        project_id task_slug retry_state
      ].freeze
      AMENDMENT_KEYS = %w[
        amendment_id kind source event_at observed_at amended_at
      ].freeze
      PR_KEYS = %w[number url state draft head_revision checks review merged_at].freeze
      CUTOVER_KEYS = %w[requested_at effective_at previous_time_zone skipped_labels].freeze
      DETAIL_KEYS = (Materiality::DETAIL_KEYS.values.flatten + [ "workflow" ]).uniq.freeze

      module_function

      def sanitize_nested(record)
        copy = stringify(record)
        copy["projects"] = rows(copy["projects"], method(:project))
        copy["items"] = rows(copy["items"], method(:fact))
        copy["attention"] = rows(copy["attention"], method(:attention))
        %w[gaps effective_gaps].each do |key|
          copy[key] = rows(copy[key], method(:gap)) if copy.key?(key)
        end
        copy["amendments"] = rows(copy["amendments"], method(:amendment))
        copy
      end

      def project(value)
        pick(value, PROJECT_KEYS)
      end

      def fact(value)
        row = pick(value, FACT_KEYS)
        source = stringify(value)
        row["details"] = pick(source["details"], DETAIL_KEYS) if source["details"].is_a?(Hash)
        row["pr"] = pick(source["pr"], PR_KEYS) if source["pr"].is_a?(Hash)
        row
      end

      def attention(value)
        pick(value, ATTENTION_KEYS)
      end

      def gap(value)
        pick(value, GAP_KEYS)
      end

      def amendment(value)
        source = stringify(value)
        pick(source, AMENDMENT_KEYS).merge(
          "items" => rows(source["items"], method(:fact)),
          "attention" => rows(source["attention"], method(:attention)),
          "gaps" => rows(source["gaps"], method(:gap)),
          "resolved_gap_ids" => Array(source["resolved_gap_ids"]).map(&:to_s),
          "resolved_gaps" => rows(source["resolved_gaps"], method(:gap))
        )
      end

      def cutover(value)
        value.is_a?(Hash) ? pick(value, CUTOVER_KEYS) : nil
      end

      def rows(values, sanitizer)
        Array(values).filter_map { |value| sanitizer.call(value) if value.is_a?(Hash) }
      end
      private_class_method :rows

      def pick(value, keys)
        source = stringify(value)
        source.slice(*keys)
      end
      private_class_method :pick

      def stringify(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, child), out|
          out[key.to_s] = child.is_a?(Hash) ? stringify(child) : child
        end
      end
      private_class_method :stringify
    end
  end
end
