require "shellwords"

module Hive
  module ModulePackage
    # Parses a reviewed command target into argv without ever invoking a shell.
    # The conservative bounds keep manifests, snapshots, and diagnostics small.
    module CommandTarget
      MAX_BYTES = 4096
      MAX_ARGUMENTS = 128
      MAX_ARGUMENT_BYTES = 2048

      module_function

      def argv(value)
        unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
               value.bytesize <= MAX_BYTES && !value.match?(/[\x00-\x1f\x7f]/)
          raise Hive::ConfigError, "module command target is malformed"
        end

        parsed = Shellwords.shellsplit(value)
        unless parsed.any? && parsed.length <= MAX_ARGUMENTS &&
               parsed.first.is_a?(String) && !parsed.first.empty? &&
               parsed.all? { |argument| argument.bytesize <= MAX_ARGUMENT_BYTES }
          raise Hive::ConfigError, "module command target is malformed"
        end
        parsed.freeze
      rescue ArgumentError
        raise Hive::ConfigError, "module command target is malformed"
      end
    end
  end
end
