require "uri"
require "pathname"

module Hive
  module Modules
    class CapabilityDenied < Hive::ConfigError; end

    # Runtime enforcement for the exact grants disclosed by a module preview.
    # It intentionally knows nothing about first-party identity: built-ins and
    # reviewed external publishers pass through the same checks.
    class CapabilityContext
      SET_GRANTS = %w[
        github_mutations external_commands network_hosts filesystem_read filesystem_write secrets
      ].freeze

      attr_reader :grants

      def initialize(grants)
        @grants = grants.transform_keys(&:to_s)
        validate!
      end

      def require_repository_write!
        deny!("repository_write", "repository writes") unless grants.fetch("repository_write")
        true
      end

      def require_github_mutation!(operation) = require_member!("github_mutations", operation)
      def require_external_command!(command) = require_member!("external_commands", executable(command))
      def require_secret!(binding) = require_member!("secrets", binding)
      def require_network_host!(host) = require_member!("network_hosts", normalized_host(host))
      def require_filesystem_read!(path) = require_path!("filesystem_read", path)
      def require_filesystem_write!(path) = require_path!("filesystem_write", path)

      private

      def validate!
        expected = [ "repository_write", *SET_GRANTS ].sort
        unless grants.keys.sort == expected && [ true, false ].include?(grants["repository_write"]) &&
               SET_GRANTS.all? do |key|
                 values = grants[key]
                 values.is_a?(Array) && values.all? { |item| item.is_a?(String) } &&
                   values.uniq == values && (!values.include?("*") || values == [ "*" ])
               end
          raise CapabilityDenied, "module capability grant snapshot is malformed"
        end
      end

      def require_member!(category, value)
        value = value.to_s
        allowed = grants.fetch(category)
        deny!(category, value) unless allowed.include?(value) || allowed == [ "*" ]
        true
      end

      def require_path!(category, path)
        value = path.to_s.tr("\\", "/")
        allowed = grants.fetch(category)
        matches = allowed == [ "*" ] || allowed.any? do |pattern|
          pattern == value ||
            (pattern == "repository" && repository_relative?(value)) ||
            (repository_relative?(value) && File.fnmatch?(pattern, value, File::FNM_PATHNAME))
        end
        deny!(category, value) unless matches
        true
      end

      def repository_relative?(value)
        return true if value == "repository"
        return false if value.empty? || value.include?("\0") ||
                        Pathname.new(value).absolute? || /\A[A-Za-z]:\//.match?(value)

        clean = Pathname.new(value).cleanpath.to_s
        clean != ".." && !clean.start_with?("../")
      end

      def executable(command)
        File.basename(Array(command).first.to_s)
      end

      def normalized_host(value)
        uri = URI.parse(value.to_s.include?("://") ? value.to_s : "https://#{value}")
        uri.host.to_s.downcase
      rescue URI::InvalidURIError
        value.to_s.downcase
      end

      def deny!(category, value)
        raise CapabilityDenied, "module capability #{category} does not grant #{value.inspect}"
      end
    end
  end
end
