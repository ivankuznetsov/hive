require "uri"

module Hive
  module Gh
    module RepositoryIdentity
      module_function

      def validated_repository_slug(repository)
        value = repository.to_s.strip
        segments = value.split("/", -1)
        valid = segments.size == 2 && segments.all? do |segment|
          segment.match?(/\A[a-zA-Z0-9_.-]+\z/) && !%w[. ..].include?(segment)
        end
        raise Hive::GhError, "repository must be an owner/name slug" unless valid

        value
      end

      def validated_github_host(host)
        value = host.to_s.strip
        uri = URI.parse("https://#{value}")
        valid = !value.empty? && uri.host == value && uri.path.empty? &&
                uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise Hive::GhError, "GitHub host must be a hostname without a scheme or path" unless valid

        value
      rescue URI::InvalidURIError
        raise Hive::GhError, "GitHub host must be a hostname without a scheme or path"
      end

      def github_repository_target(repository, host)
        "#{validated_github_host(host)}/#{validated_repository_slug(repository)}"
      end
    end
  end
end
