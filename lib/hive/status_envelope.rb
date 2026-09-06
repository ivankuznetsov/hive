# frozen_string_literal: true

module Hive
  # Shared compatibility contract for long-running consumers of a versioned
  # status subprocess. Envelope shape is strict; additive forward versions are
  # best-effort, and older producers fail closed with an actionable message.
  class StatusEnvelope
    SCHEMA = "hive-status"
    EXPECTED_VERSION = Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA)

    def initialize(restart_target:)
      @restart_target = restart_target
    end

    def validate!(document)
      unless document.is_a?(Hash) && document["schema"] == SCHEMA
        raise ArgumentError, "missing schema=#{SCHEMA} in envelope"
      end
      return if document["ok"] == true

      raise ArgumentError, "envelope ok=false: #{yield}"
    end

    def schema_skew(document)
      version = document["schema_version"]
      return :match if version == EXPECTED_VERSION
      return :newer if version.is_a?(Integer) && version > EXPECTED_VERSION

      :older
    end

    def forward_skew_warning(document)
      "#{forward_skew_summary(document)}; parsing best-effort. " \
        "Restart the #{@restart_target} to pick up the new schema."
    end

    def forward_skew_message(document, underlying:)
      "hive status: #{forward_skew_summary(document)}; " \
        "restart the #{@restart_target} to pick up the new version " \
        "(underlying error: #{underlying.class}: #{underlying.message})"
    end

    def older_skew_message(document)
      "hive status: envelope schema v#{document['schema_version']} is older than this process " \
        "(v#{EXPECTED_VERSION}); update/reinstall the hive binary on PATH"
    end

    private

    def forward_skew_summary(document)
      "envelope schema v#{document['schema_version']} is newer than this process (v#{EXPECTED_VERSION})"
    end
  end
end
