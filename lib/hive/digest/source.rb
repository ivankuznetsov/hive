module Hive
  module Digest
    module Source
      MERGED_PRS = "merged-prs".freeze
      SHIPPED = "shipped".freeze
      DEFAULT = MERGED_PRS
      VALUES = [ MERGED_PRS, SHIPPED ].freeze
      SCHEMAS = {
        MERGED_PRS => "hive-merged-pr-digest",
        SHIPPED => "hive-digest"
      }.freeze

      module_function

      def resolve(explicit: nil, repos: [], configured: nil)
        explicit = normalize(explicit)
        configured = normalize(configured)
        validate!(configured, label: "digest.source")
        validate!(explicit, label: "hive digest: --source")

        if explicit == SHIPPED && Array(repos).any?
          raise Hive::ConfigError,
                "hive digest: --source shipped cannot be combined with --repo; " \
                "remove --repo or select --source merged-prs"
        end

        explicit || (MERGED_PRS if Array(repos).any?) || configured || DEFAULT
      end

      def schema_for(source)
        SCHEMAS.fetch(source)
      end

      # Select the most honest existing envelope even when command dispatch
      # never occurs (or source validation itself fails). Valid explicit input
      # wins, --repo still implies merged PRs, and an invalid explicit value
      # falls back to the configured/default source for the error envelope.
      def schema_for_options(explicit: nil, repos: [], configured: nil)
        explicit = normalize(explicit)
        configured = normalize(configured)
        source =
          if VALUES.include?(explicit)
            explicit
          elsif Array(repos).any?
            MERGED_PRS
          elsif VALUES.include?(configured)
            configured
          else
            DEFAULT
          end
        schema_for(source)
      end

      def schema_for_argv(argv, configured: nil)
        explicit = nil
        repos = []
        argv.each_with_index do |arg, index|
          next unless valid_text?(arg)

          if arg == "--source"
            value = argv[index + 1]
            explicit = value if valid_text?(value)
          elsif arg.start_with?("--source=")
            explicit = arg.split("=", 2).last
          elsif arg == "--repo" || arg.start_with?("--repo=")
            repos << true
          end
        end
        schema_for_options(explicit: explicit, repos: repos, configured: configured)
      end

      def normalize(value)
        value = value.to_s.strip
        value.empty? ? nil : value
      end
      private_class_method :normalize

      def validate!(source, label:)
        return if source.nil? || VALUES.include?(source)

        raise Hive::ConfigError,
              "#{label} must be one of #{VALUES.join(', ')}; got #{source.inspect}"
      end
      private_class_method :validate!

      def valid_text?(value)
        value.is_a?(String) && value.valid_encoding?
      end
      private_class_method :valid_text?
    end
  end
end
