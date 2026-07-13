# frozen_string_literal: true

require "yaml"

module HiveBench
  # Loads the frozen corpus into the entry hashes the run-pass driver feeds to
  # Run/Gate/Judge. Each entry is its `manifest.yml` plus the two fields the
  # harness needs that the manifest doesn't carry:
  #
  #   entry_dir       — where spec/, reference.patch, gate/ live (the corpus dir).
  #   checkout_source — the local clone restored at source.base_commit during
  #                     generation and gating.
  #
  # v1 is single-repo (the Ruby/CLI hive corpus), so one checkout_source serves
  # every entry. When the corpus widens to multiple repos, resolve the clone per
  # entry from manifest "source" -> "repo".
  module Corpus
    module_function

    def load(root:, checkout_source:)
      # Dir.glob sorts its results by default on Ruby 3+ (sort: true), so entry
      # order is deterministic across platforms — the run matrix is reproducible.
      manifests = Dir.glob(File.join(root, "*", "manifest.yml"))
      manifests.map do |path|
        manifest = YAML.safe_load_file(path)
        # A blank or non-mapping manifest would otherwise blow up with a cryptic
        # NoMethodError on #merge — name the offending file instead.
        raise ArgumentError, "corpus manifest is not a mapping: #{path}" unless manifest.is_a?(Hash)

        manifest.merge(
          "entry_dir" => File.dirname(path),
          "checkout_source" => checkout_source
        )
      end
    end
  end
end
