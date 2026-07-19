module Hive
  module WorkflowPackage
    # Optional workflow inputs become child-process environment variables.
    # Keep them away from process/runtime control surfaces even when a package
    # and an operator accidentally choose the same binding name.
    module InputName
      PORTABLE = /\A[A-Z_][A-Z0-9_]*\z/
      RESERVED = %w[
        BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_WITH BUNDLE_WITHOUT
        CDPATH ENV GEM_HOME GEM_PATH HOME IFS LANG LD_LIBRARY_PATH LD_PRELOAD
        NODE_OPTIONS PATH PERL5LIB PROMPT_COMMAND PS4 PYTHONHOME PYTHONPATH
        RUBYLIB RUBYOPT SHELL TMP TMPDIR
      ].freeze
      RESERVED_PREFIXES = %w[
        BASH_ BUNDLE_ CLAUDE_ CODEX_ DYLD_ GEM_ GIT_ HIVE_ LC_ OPENAI_ SSH_
      ].freeze

      module_function

      def valid?(value)
        name = value.to_s
        PORTABLE.match?(name) && !reserved?(name)
      end

      def reserved?(name)
        RESERVED.include?(name) || RESERVED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
      end
    end
  end
end
