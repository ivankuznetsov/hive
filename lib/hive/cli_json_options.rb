# frozen_string_literal: true

module Hive
  # Shared parsing rules for the global --json boolean accepted by the Hive
  # binaries. Keep this aligned with Thor's exact boolean spellings so wrapper
  # routing and command dispatch always agree on whether JSON was requested.
  module CliJsonOptions
    TRUE_OPTIONS = %w[--json --json=true --json=TRUE --json=t --json=T].freeze
    FALSE_OPTIONS = %w[--no-json --skip-json --json=false --json=FALSE --json=f --json=F].freeze
    BOOLEAN_OPTIONS = (TRUE_OPTIONS + FALSE_OPTIONS).freeze
    BOOLEAN_VALUES = { "true" => true, "TRUE" => true, "t" => true, "T" => true,
                       "false" => false, "FALSE" => false, "f" => false, "F" => false }.freeze

    module_function

    def option_argv(argv)
      argv.take(argv.index("--") || argv.length)
    end

    def requested?(argv)
      options = option_argv(argv)
      index = options.rindex { |arg| BOOLEAN_OPTIONS.include?(arg) }
      return false unless index

      option = options[index]
      value = options[index + 1]
      return BOOLEAN_VALUES.fetch(value) if separate_value?(option, value)

      TRUE_OPTIONS.include?(option)
    end

    def separate_value?(option, value)
      %w[--json --no-json --skip-json].include?(option) && BOOLEAN_VALUES.key?(value)
    end

    def unsupported_assignment(argv, before_index: nil)
      option_argv(argv).each_with_index.find do |candidate, index|
        next false if before_index && index >= before_index

        candidate.start_with?("--json=") && !BOOLEAN_OPTIONS.include?(candidate)
      end&.first
    end
  end
end
