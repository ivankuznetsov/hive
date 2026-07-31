require "pathname"
require "hive/errors"

module Hive
  module Modules
    module Migration
      # Host-only identity for the reviewed compiler inputs of one Patrol
      # qualification run. The persisted payload is deliberately separate
      # from checkout_root: descriptors retain immutable provenance, while the
      # host alone decides where those exact Git objects may be read.
      class TrustedQualificationControl < Data.define(
        :payload, :checkout_root
      )
        TRUST_SCOPES = %w[local trusted_remote].freeze
        TOP_LEVEL_KEYS = %w[
          catalog commit_sha harness_manifest_sha256 provenance ref
          repository tree_sha trust_scope
        ].freeze
        CATALOG_KEYS = %w[ref sha256].freeze
        PROVENANCE_KEYS = %w[
          action_lock_sha256 run_attempt run_id workflow_path workflow_sha
        ].freeze
        SHA = /\A[0-9a-f]{40}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        REPOSITORY = %r{
          \Agithub\.com/
          [a-z0-9][a-z0-9._-]{0,99}/
          [a-z0-9][a-z0-9._-]{0,99}\z
        }x
        SAFE_REF = %r{\Arefs/[a-zA-Z0-9][a-zA-Z0-9._/-]{0,4090}\z}
        TRUSTED_REF = "refs/heads/main".freeze

        class << self
          def build(repository:, ref:, commit_sha:, tree_sha:,
                    trust_scope:, catalog_ref:, catalog_sha256:,
                    harness_manifest_sha256:, provenance:,
                    checkout_root:)
            from_h(
              {
                "repository" => repository,
                "ref" => ref,
                "commit_sha" => commit_sha,
                "tree_sha" => tree_sha,
                "trust_scope" => trust_scope,
                "catalog" => {
                  "ref" => catalog_ref,
                  "sha256" => catalog_sha256
                },
                "harness_manifest_sha256" =>
                  harness_manifest_sha256,
                "provenance" => provenance
              },
              checkout_root: checkout_root
            )
          end

          def from_h(value, checkout_root:)
            payload = normalize(value)
            root = normalize_root(checkout_root)
            new(payload: payload, checkout_root: root).freeze
          end

          def normalize(value)
            malformed! unless
              value.is_a?(Hash) &&
                value.keys.all? { |key| key.is_a?(String) } &&
                value.keys.sort == TOP_LEVEL_KEYS
            repository = value.fetch("repository")
            malformed! unless
              repository.is_a?(String) &&
                REPOSITORY.match?(repository)
            ref = value.fetch("ref")
            commit_sha = value.fetch("commit_sha")
            tree_sha = value.fetch("tree_sha")
            malformed! unless
              commit_sha.is_a?(String) &&
                tree_sha.is_a?(String) &&
                SHA.match?(commit_sha) &&
                SHA.match?(tree_sha)
            trust_scope = value.fetch("trust_scope")
            malformed! unless
              trust_scope.is_a?(String) &&
                TRUST_SCOPES.include?(trust_scope)
            if trust_scope == "local"
              malformed! unless ref.nil?
            else
              malformed! unless safe_ref?(ref)
            end
            catalog = value.fetch("catalog")
            malformed! unless
              catalog.is_a?(Hash) &&
                catalog.keys.all? { |key| key.is_a?(String) } &&
                catalog.keys.sort == CATALOG_KEYS &&
                safe_path?(catalog.fetch("ref")) &&
                catalog.fetch("sha256").is_a?(String) &&
                DIGEST.match?(catalog.fetch("sha256"))
            malformed! unless
              value.fetch("harness_manifest_sha256").is_a?(String) &&
              DIGEST.match?(
                value.fetch("harness_manifest_sha256")
              )
            provenance = normalize_provenance(
              value.fetch("provenance"),
              trust_scope: trust_scope,
              ref: ref,
              commit_sha: commit_sha
            )
            immutable(
              value.merge(
                "catalog" => catalog,
                "provenance" => provenance
              )
            )
          rescue KeyError, NoMethodError, TypeError
            malformed!
          end

          private

          def normalize_provenance(
            value, trust_scope:, ref:, commit_sha:
          )
            malformed! unless
              value.is_a?(Hash) &&
                value.keys.all? { |key| key.is_a?(String) } &&
                value.keys.sort == PROVENANCE_KEYS
            if trust_scope == "local"
              malformed! unless
                ref.nil? &&
                  value.values.all?(&:nil?)
              return value
            end

            malformed! unless ref == TRUSTED_REF
            workflow_path = value.fetch("workflow_path")
            malformed! unless
                safe_path?(workflow_path) &&
                workflow_path.start_with?(".github/workflows/") &&
                workflow_path.end_with?(".yml")
            malformed! unless
              value.fetch("workflow_sha").is_a?(String) &&
                SHA.match?(value.fetch("workflow_sha")) &&
                value.fetch("workflow_sha") ==
                  commit_sha &&
                value.fetch("action_lock_sha256").is_a?(String) &&
                DIGEST.match?(
                  value.fetch("action_lock_sha256")
                ) &&
                positive_integer?(value.fetch("run_id")) &&
                positive_integer?(value.fetch("run_attempt"))
            value
          end

          def normalize_root(value)
            malformed! unless value.is_a?(String)

            root = value
            malformed! unless
              !root.empty? &&
                !root.include?("\0") &&
                root != File::SEPARATOR &&
                root == File.expand_path(root)
            root.dup.freeze
          end

          def safe_ref?(value)
            value.is_a?(String) &&
              SAFE_REF.match?(value) &&
              !value.include?("\\") &&
              value.split("/").none? do |part|
                part.empty? || part == "." || part == ".."
              end
          end

          def safe_path?(value)
            return false unless value.is_a?(String)

            path = Pathname.new(value)
            !path.absolute? &&
              path.cleanpath.to_s == value &&
              !value.empty? &&
              !value.include?("\\") &&
              !value.include?("\0") &&
              value.split("/").none? do |part|
                part.empty? || part == "." || part == ".."
              end
          rescue ArgumentError
            false
          end

          def positive_integer?(value)
            value.is_a?(Integer) && value.positive?
          end

          def immutable(value)
            case value
            when Hash
              value.to_h do |key, child|
                [ key.dup.freeze, immutable(child) ]
              end.freeze
            when Array
              value.map { |child| immutable(child) }.freeze
            when String
              value.dup.freeze
            when Integer, TrueClass, FalseClass, NilClass
              value
            else
              malformed!
            end
          end

          def malformed!
            raise Hive::ConfigError,
                  "patrol qualification trusted control is malformed"
          end
        end

        def trusted_remote? = payload.fetch("trust_scope") == "trusted_remote"

        def qualifying_for?(candidate_sha)
          trusted_remote? &&
            payload.fetch("commit_sha") != candidate_sha.to_s
        end

        def qualification_issues(candidate_sha)
          issues = []
          issues << "qualification_control_untrusted" unless
            trusted_remote?
          issues << "qualification_control_not_independent" if
            payload.fetch("commit_sha") == candidate_sha.to_s
          issues.freeze
        end
      end
    end
  end
end
