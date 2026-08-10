# frozen_string_literal: true

module Hive
  # Shared parsing rules for the global --json boolean accepted by the Hive
  # binaries. Keep this aligned with Thor's exact boolean spellings so wrapper
  # routing and command dispatch always agree on whether JSON was requested.
  module CliJsonOptions
    TRUE_OPTIONS = %w[--json --json=true --json=TRUE --json=t --json=T].freeze
    FALSE_OPTIONS = %w[--no-json --skip-json --json=false --json=FALSE --json=f --json=F].freeze
    BOOLEAN_OPTIONS = (TRUE_OPTIONS + FALSE_OPTIONS).freeze

    module_function

    def option_argv(argv)
      argv.take(argv.index("--") || argv.length)
    end

    def requested?(argv)
      options = option_argv(argv)
      TRUE_OPTIONS.include?(options.reverse.find { |arg| BOOLEAN_OPTIONS.include?(arg) })
    end

    def unsupported_assignment(argv, before_index: nil)
      option_argv(argv).each_with_index.find do |candidate, index|
        next false if before_index && index >= before_index

        candidate.start_with?("--json=") && !BOOLEAN_OPTIONS.include?(candidate)
      end&.first
    end
  end
end
