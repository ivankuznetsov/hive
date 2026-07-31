require "hive/errors"
require "uri"

module Hive
  module RefactorPatrol
    # Pure boundary between a registered project descriptor and immutable PR
    # provenance. It owns no registry lookup, JobStore state, or transition
    # behavior.
    module ArchitectureProjectBinding
      PROJECT_KEYS = %w[name project_id repository].freeze
      SOURCE_IDENTITY_ERROR = "source repository URL is invalid".freeze
      PROJECT_BINDING_ERROR =
        "architecture patrol project binding does not match manifest source".freeze
      PROJECT_DRIFT_ERROR =
        "architecture patrol project binding does not match registered project".freeze

      module_function

      def source_identity!(source)
        uri = URI.parse(source.fetch("url").to_s)
        repository = source.fetch("repository").to_s
        number = source.fetch("number")
        match = uri.path.match(
          %r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z}
        )
        unless uri.is_a?(URI::HTTP) && uri.host &&
               uri.userinfo.nil? && uri.query.nil? &&
               uri.fragment.nil? && match &&
               match[1].casecmp?(repository) &&
               number.is_a?(Integer) && number.positive? &&
               match[2].to_i == number
          raise Hive::GhError, SOURCE_IDENTITY_ERROR
        end

        { "repository" => repository, "host" => uri.host }
      rescue KeyError, NoMethodError, TypeError,
             URI::InvalidURIError => e
        raise Hive::GhError,
              "#{SOURCE_IDENTITY_ERROR}: #{e.message}"
      end

      def from_entry!(entry:, source:)
        unless entry.is_a?(Hash)
          raise Hive::ConfigError, PROJECT_BINDING_ERROR
        end

        validate!(
          project: {
            "project_id" => entry.fetch("project_id"),
            "name" => entry.fetch("name"),
            "repository" => entry.fetch("repository_identity")
          },
          source: source
        )
      rescue KeyError
        raise Hive::ConfigError, PROJECT_BINDING_ERROR
      end

      def validate!(project:, source:)
        project = project_snapshot!(
          project, error: PROJECT_BINDING_ERROR
        )
        identity = source_identity!(source)
        registration = source.fetch("registration")
        expected_repository = [
          identity.fetch("host"),
          identity.fetch("repository")
        ].join("/")
        unless registration.is_a?(String) &&
               !registration.empty? &&
               project.fetch("name") == registration &&
               project.fetch("repository").casecmp?(
                 expected_repository
               )
          raise Hive::ConfigError, PROJECT_BINDING_ERROR
        end

        project
      rescue Hive::GhError, KeyError, NoMethodError, TypeError
        raise Hive::ConfigError, PROJECT_BINDING_ERROR
      end

      def assert_same!(expected:, observed:)
        expected = project_snapshot!(
          expected, error: PROJECT_DRIFT_ERROR
        )
        observed = project_snapshot!(
          observed, error: PROJECT_DRIFT_ERROR
        )
        raise Hive::ConfigError, PROJECT_DRIFT_ERROR unless
          observed == expected

        expected
      end

      def project_snapshot!(project, error:)
        valid = project.is_a?(Hash) &&
                project.keys.sort == PROJECT_KEYS &&
                PROJECT_KEYS.all? do |key|
                  project[key].is_a?(String) &&
                    !project[key].empty?
        end
        raise Hive::ConfigError, error unless valid

        project.each_with_object({}) do |(key, value), copy|
          copy[key.dup.freeze] = value.dup.freeze
        end.freeze
      end
      private_class_method :project_snapshot!
    end
  end
end
