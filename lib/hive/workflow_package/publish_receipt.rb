require "time"
require "hive/workflow_package/registry_manifest"

module Hive
  module WorkflowPackage
    class PublishRecoveryError < Hive::ConfigError; end

    class PublishConflict < Hive::Error
      def exit_code = Hive::ExitCodes::GENERIC
    end

    class PublishReceipt
      SCHEMA = "hive.workflow-publish-receipt/v1".freeze
      STEPS = %w[
        validated prepared fork_create_intent fork_verified push_intent pushed
        pr_create_intent pr_verified
      ].freeze
      STATES = %w[pending_review merged_pending_listing listed closed_unmerged].freeze
      SHA256 = /\A[0-9a-f]{64}\z/
      SHA = /\A[0-9a-f]{40}\z/
      REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
      BRANCH = /\A(?!\/)(?!.*(?:\.\.|@\{|\/\/))[A-Za-z0-9._\/-]{1,240}(?<![\/.])\z/
      URL = %r{\Ahttps://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*\z}
      IDENTITY_KEYS = %w[registry name version package_digest release_digest lint_contract].freeze
      OPTIONAL_KEYS = %w[
        submission_mode destination_repository base_branch base_sha head_repository
        head_branch owner fork_parent fork_owner commit_oid pr_number pr_url observation
      ].freeze
      KEYS = ([ "schema", *IDENTITY_KEYS, "last_completed_step", *OPTIONAL_KEYS ]).freeze

      attr_reader :data

      def self.build(registry:, name:, version:, package_digest:, release_digest:, lint_contract:)
        from_h(
          "schema" => SCHEMA, "registry" => registry, "name" => name,
          "version" => version, "package_digest" => package_digest,
          "release_digest" => release_digest, "lint_contract" => lint_contract,
          "last_completed_step" => "validated"
        )
      end

      def self.from_h(value)
        new(value).tap(&:validate!).freeze
      end

      def initialize(value)
        @data = deep_copy(value)
      end
      private_class_method :new

      def registry = data.fetch("registry")
      def name = data.fetch("name")
      def version = data.fetch("version")
      def package_digest = data.fetch("package_digest")
      def release_digest = data.fetch("release_digest")
      def lint_contract = data.fetch("lint_contract")
      def last_completed_step = data.fetch("last_completed_step")
      def observation = data["observation"]

      def identity
        IDENTITY_KEYS.to_h { |key| [ key, data.fetch(key) ] }.freeze
      end

      def assert_identity!(registry:, name:, version:, package_digest:, release_digest:, lint_contract:)
        requested = {
          "registry" => registry, "name" => name, "version" => version,
          "package_digest" => package_digest, "release_digest" => release_digest,
          "lint_contract" => lint_contract
        }
        return self if identity == requested

        raise PublishConflict,
              "immutable workflow publication conflict for #{registry}/#{name}@#{version}"
      end

      def advance(step, attributes = {})
        target = STEPS.index(step.to_s)
        current = STEPS.index(last_completed_step)
        raise PublishRecoveryError, "publication receipt step is unknown" unless target && current
        raise PublishRecoveryError, "publication receipt progress cannot move backwards" if target < current
        normalized = stringify(attributes)
        unknown = normalized.keys - OPTIONAL_KEYS
        raise PublishRecoveryError, "publication receipt update contains unsupported fields" unless unknown.empty?

        copy = deep_copy(data)
        normalized.each do |key, value|
          if copy.key?(key) && copy[key] != value
            raise PublishRecoveryError, "publication receipt field #{key} is write-once"
          end
          copy[key] = value
        end
        copy["last_completed_step"] = step.to_s
        self.class.from_h(copy)
      end

      def observe(state:, observed_at:, pr_url: nil, pr_number: nil)
        state = state.to_s
        validate_transition!(observation && observation.fetch("state"), state)
        observation = {
          "state" => state, "freshness" => "current", "observed_at" => observed_at.to_s
        }
        observation["pr_url"] = pr_url if pr_url
        observation["pr_number"] = pr_number if pr_number
        copy = deep_copy(data)
        copy["observation"] = observation
        self.class.from_h(copy)
      end

      def cached_observation
        raise PublishRecoveryError, "publication has no prior lifecycle observation" unless observation
        observation.merge("freshness" => "cached").freeze
      end

      def to_h = deep_copy(data)

      def validate!
        unless data.is_a?(Hash) && data.keys.all?(String) && (data.keys - KEYS).empty? &&
               data["schema"] == SCHEMA && (IDENTITY_KEYS + [ "last_completed_step" ] - data.keys).empty?
          fail!("receipt schema is malformed or unsupported")
        end
        fail!("registry identity is malformed") unless REPOSITORY.match?(data["registry"].to_s)
        fail!("package name is malformed") unless RegistryManifest::NAME.match?(data["name"].to_s)
        fail!("package version is malformed") unless RegistryManifest::SEMVER.match?(data["version"].to_s)
        %w[package_digest release_digest].each do |key|
          fail!("#{key} is malformed") unless SHA256.match?(data[key].to_s)
        end
        validate_lint_contract!
        fail!("last completed step is malformed") unless STEPS.include?(data["last_completed_step"])
        validate_optional_fields!
        deep_freeze(data)
        true
      end

      private

      def validate_transition!(from, to)
        allowed = {
          nil => STATES,
          "pending_review" => %w[pending_review merged_pending_listing listed closed_unmerged],
          "merged_pending_listing" => %w[merged_pending_listing listed],
          "listed" => %w[listed],
          "closed_unmerged" => %w[closed_unmerged]
        }
        fail!("lifecycle observation cannot move backwards") unless allowed.fetch(from, []).include?(to)
      end

      def validate_lint_contract!
        contract = data["lint_contract"]
        keys = %w[
          contract_sha256 expected_output_sha256 fixture_corpus_sha256 upstream_commit
          upstream_policy_sha256 version
        ]
        unless contract.is_a?(Hash) && contract.keys.sort == keys &&
               contract["version"].is_a?(String) && !contract["version"].empty? &&
               SHA.match?(contract["upstream_commit"].to_s) &&
               %w[
                 upstream_policy_sha256 fixture_corpus_sha256 expected_output_sha256
                 contract_sha256
               ].all? { |key| SHA256.match?(contract[key].to_s) }
          fail!("lint contract identity is malformed")
        end
      end

      def validate_optional_fields!
        mode = data["submission_mode"]
        fail!("submission mode is malformed") if mode && !%w[direct fork].include?(mode)
        %w[destination_repository head_repository fork_parent].each do |key|
          fail!("#{key} is malformed") if data[key] && !REPOSITORY.match?(data[key].to_s)
        end
        %w[base_branch head_branch].each do |key|
          fail!("#{key} is malformed") if data[key] && !BRANCH.match?(data[key].to_s)
        end
        %w[base_sha commit_oid].each do |key|
          fail!("#{key} is malformed") if data[key] && !SHA.match?(data[key].to_s)
        end
        %w[owner fork_owner].each do |key|
          fail!("#{key} is malformed") if data[key] && !data[key].to_s.match?(/\A[A-Za-z0-9-]{1,39}\z/)
        end
        fail!("PR number is malformed") if data["pr_number"] && !(data["pr_number"].is_a?(Integer) && data["pr_number"].positive?)
        fail!("PR URL is malformed") if data["pr_url"] && !URL.match?(data["pr_url"].to_s)

        if mode
          required = %w[destination_repository base_branch head_repository head_branch owner]
          fail!("submission mode fields are incomplete") unless required.all? { |key| data[key] }
          if mode == "direct"
            fail!("direct submission head must be the destination") unless data["head_repository"] == data["destination_repository"]
            fail!("direct submission cannot carry fork identity") if data["fork_parent"] || data["fork_owner"]
          else
            fail!("fork submission identity is incomplete") unless data["fork_parent"] == data["destination_repository"] && data["fork_owner"] == data["owner"]
            fail!("fork submission head must differ from destination") if data["head_repository"] == data["destination_repository"]
          end
        end
        validate_observation! if data["observation"]
      end

      def validate_observation!
        value = data["observation"]
        keys = %w[state freshness observed_at pr_url pr_number]
        unless value.is_a?(Hash) && value.keys.all?(String) && (value.keys - keys).empty? &&
               STATES.include?(value["state"]) && value["freshness"] == "current"
          fail!("lifecycle observation is malformed")
        end
        Time.iso8601(value.fetch("observed_at"))
        fail!("lifecycle PR URL is malformed") if value["pr_url"] && !URL.match?(value["pr_url"].to_s)
        if value["pr_number"] && !(value["pr_number"].is_a?(Integer) && value["pr_number"].positive?)
          fail!("lifecycle PR number is malformed")
        end
      rescue ArgumentError, KeyError
        fail!("lifecycle observation time is malformed")
      end

      def stringify(value)
        fail!("receipt update must be a map") unless value.is_a?(Hash)
        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, child| [ key.to_s, deep_copy(child) ] }
        when Array then value.map { |child| deep_copy(child) }
        else value
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array then value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end

      def fail!(message) = raise(PublishRecoveryError, "workflow publication recovery failed: #{message}")
    end
  end
end
