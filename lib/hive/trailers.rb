module Hive
  # Canonical schema for hive fix-agent commit trailers. Templates emit
  # trailers in title-case (`Hive-Foo-Bar`); parsers canonicalise via
  # downcase (see `Hive::Metrics.parse_trailers`). Adding a new trailer:
  # append to KNOWN, update the templates that emit it, and bump
  # SCHEMA_VERSION when the change is breaking (e.g., a renamed key, a
  # changed value semantic).
  #
  # The constant is the documentation source of truth — `Hive::Metrics`
  # uses it as a reference, not as a strict allowlist (we don't want a
  # new trailer landing in templates to fail the rollback metric while
  # the schema bump rolls out).
  module Trailers
    SCHEMA_VERSION = 1
    KNOWN = %w[
      Hive-Task-Slug
      Hive-Fix-Pass
      Hive-Fix-Findings
      Hive-Triage-Bias
      Hive-Reviewer-Sources
      Hive-Fix-Phase
    ].freeze

    module_function

    def known?(name) = KNOWN.map(&:downcase).include?(name.to_s.downcase)
  end
end
