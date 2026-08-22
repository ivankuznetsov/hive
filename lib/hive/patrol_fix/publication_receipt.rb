require "digest"
require "time"
require "uri"
require "hive/gh/repository_identity"
require "hive/git_ref"
require "hive/patrol_fix"
require "hive/patrol_fix/receipt_store"

module Hive
  module PatrolFix
    # Exact pull-request completion evidence. This value is built from a
    # reconciled lower-level GithubPublication observation or an already strict
    # controller migration/admission payload; never from a create response or
    # model-authored identity.
    module PublicationReceipt
      module_function

      FIELDS = %w[
        id publication_id number url host repository base_branch
        creation_base_revision branch head_revision diff_digest title_digest
        body_digest marker_digest state observed_at
      ].freeze
      STATES = %w[open draft closed merged].freeze
      OID = /\A[0-9a-f]{40}\z/
      DIGEST = /\A[0-9a-f]{64}\z/
      PUBLICATION_ID = /\Apub-[0-9a-f]{32}\z/

      class InvalidPublication < Hive::Error; end

      def build(task:, evidence_revision:, publication:)
        adopt(
          task: task, evidence_revision: evidence_revision,
          payload: normalize(publication)
        )
      end

      # Migration/admission may already hold a strict canonical observation.
      # Adopting it wraps those exact bytes and performs no GitHub operation.
      def adopt(task:, evidence_revision:, payload:)
        payload = validate_payload!(payload)
        identity = Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "task" => task, "evidence_revision" => evidence_revision,
          "payload" => payload
        ))
        {
          "schema" => ReceiptStore::SCHEMA,
          "schema_version" => ReceiptStore::SCHEMA_VERSION,
          "receipt_id" => "publication-#{identity[0, 24]}",
          "kind" => "publication", "stage" => "publish",
          "task" => PatrolFix.deep_copy(task),
          "evidence_revision" => PatrolFix.deep_copy(evidence_revision),
          "recorded_at" => payload.fetch("observed_at"),
          "payload" => payload
        }
      end

      def normalize(publication)
        unless publication.is_a?(Hash)
          invalid!("publication observation must be an object")
        end
        {
          "id" => "github:#{publication['repository']}##{publication['number']}",
          "publication_id" => publication["publication_id"],
          "number" => publication["number"], "url" => publication["url"],
          "host" => publication["host"], "repository" => publication["repository"],
          "base_branch" => publication["base_branch"],
          "creation_base_revision" => publication["creation_base_oid"],
          "branch" => publication["branch"], "head_revision" => publication["head_oid"],
          "diff_digest" => publication["diff_digest"],
          "title_digest" => publication["title_digest"],
          "body_digest" => publication["body_digest"],
          "marker_digest" => publication["marker_digest"],
          "state" => publication["hosted_state"],
          "observed_at" => publication["observed_at"]
        }
      end

      def validate_payload!(payload)
        unless payload.is_a?(Hash) && payload.keys.sort == FIELDS.sort
          invalid!("publication receipt fields must be exactly #{FIELDS.join(', ')}")
        end
        string!(payload.fetch("publication_id"), "publication_id", 36, PUBLICATION_ID)
        number = payload.fetch("number")
        invalid!("publication receipt number is invalid") unless number.is_a?(Integer) && number.positive?
        string!(payload.fetch("id"), "id", 272)
        string!(payload.fetch("url"), "url", 4_096)
        string!(payload.fetch("host"), "host", 253)
        string!(payload.fetch("repository"), "repository", 255)
        string!(payload.fetch("base_branch"), "base_branch", 241)
        string!(payload.fetch("branch"), "branch", 241)
        string!(payload.fetch("observed_at"), "observed_at", 64)
        host = Hive::Gh::RepositoryIdentity.validated_github_host(payload.fetch("host"))
        repository = Hive::Gh::RepositoryIdentity.validated_repository_slug(payload.fetch("repository"))
        expected_id = "github:#{repository}##{number}"
        invalid!("publication receipt id is invalid") unless payload.fetch("id") == expected_id
        validate_url!(payload.fetch("url"), host, repository, number)
        %w[base_branch branch].each { |key| Hive::GitRef.validate_branch_name(payload.fetch(key)) }
        %w[creation_base_revision head_revision].each do |key|
          string!(payload.fetch(key), key, 40, OID)
        end
        %w[diff_digest title_digest body_digest marker_digest].each do |key|
          string!(payload.fetch(key), key, 64, DIGEST)
        end
        invalid!("publication receipt state is invalid") unless STATES.include?(payload.fetch("state"))
        Time.iso8601(payload.fetch("observed_at"))
        PatrolFix.deep_freeze(PatrolFix.deep_copy(payload))
      rescue Hive::GhError, ArgumentError, KeyError, TypeError => e
        invalid!(e.message)
      end

      def validate_url!(value, host, repository, number)
        uri = URI.parse(value.to_s)
        expected = "/#{repository}/pull/#{number}"
        unless uri.scheme == "https" && uri.host&.casecmp?(host) &&
               uri.path.casecmp?(expected) && uri.userinfo.nil? &&
               uri.query.nil? && uri.fragment.nil?
          invalid!("publication receipt URL is invalid")
        end
      rescue URI::InvalidURIError
        invalid!("publication receipt URL is invalid")
      end

      def string!(value, label, max, pattern = nil)
        unless value.is_a?(String) && !value.empty? && value.bytesize <= max &&
               !value.match?(/[\u0000-\u001f\u007f]/) && (!pattern || value.match?(pattern))
          invalid!("publication receipt #{label} is invalid")
        end
      end

      def invalid!(message)
        raise InvalidPublication, message.to_s[0, 512]
      end
      private_class_method :normalize, :validate_url!, :string!, :invalid!
    end
  end
end
