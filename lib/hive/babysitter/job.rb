require "digest"
require "json"
require "time"
require "uri"
require "hive/repository_identity"

module Hive
  module Babysitter
    module Job
      SCHEMA = "hive-babysitter-job".freeze
      SCHEMA_VERSION = 1
      STATES = %w[inactive active superseded terminal].freeze
      TOP_LEVEL_KEYS = %w[
        schema schema_version job_id identity pr_url branch task_folder head_sha head_generation
        finalize_attempt_id state journal_handoff_event_id supersedes_job_id superseded_by_job_id
        replacement_proof claims created_at updated_at
      ].freeze
      IDENTITY_KEYS = %w[project task_id task_slug task_generation repository pr_number].freeze
      CLAIM_KEYS = %w[
        owner owner_pid owner_process_start_time claim_fence state claimed_at heartbeat_at expires_at
        finished_at outcome
      ].freeze

      class Invalid < Hive::Error; end

      module_function

      def identity(project:, task_id:, task_slug:, task_generation:, repository:, pr_number:)
        value = {
          "project" => project.to_s.strip.downcase,
          "task_id" => task_id.to_s.strip,
          "task_slug" => task_slug.to_s.strip,
          "task_generation" => task_generation,
          "repository" => canonical_repository(repository),
          "pr_number" => pr_number
        }
        missing = %w[project task_id task_slug repository].select { |key| value[key].to_s.empty? }
        raise Invalid, "babysitter job identity missing #{missing.join(', ')}" unless missing.empty?
        unless task_generation.is_a?(Integer) && task_generation >= 0
          raise Invalid, "babysitter task_generation must be a non-negative integer"
        end
        unless pr_number.is_a?(Integer) && pr_number.positive?
          raise Invalid, "babysitter pr_number must be positive"
        end
        value.freeze
      end

      def job_id(identity)
        canonical = IDENTITY_KEYS.map do |key|
          value = identity.fetch(key)
          "#{key.bytesize}:#{key}=#{value.to_s.bytesize}:#{value}"
        end.join("\0")
        "bsj-v1-#{::Digest::SHA256.hexdigest(canonical)[0, 32]}"
      rescue KeyError => e
        raise Invalid, "babysitter identity missing #{e.key}"
      end

      def build(identity:, pr_url:, branch:, task_folder:, head_sha:, head_generation:,
                finalize_attempt_id:, now:, supersedes_job_id: nil, replacement_proof: nil)
        timestamp = now.utc.iso8601(6)
        record = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "job_id" => job_id(identity),
          "identity" => identity.dup,
          "pr_url" => normalize_pr_url(pr_url, identity),
          "branch" => branch.to_s.strip,
          "task_folder" => File.expand_path(task_folder),
          "head_sha" => head_sha.to_s,
          "head_generation" => head_generation,
          "finalize_attempt_id" => finalize_attempt_id.to_s,
          "state" => "inactive",
          "journal_handoff_event_id" => nil,
          "supersedes_job_id" => supersedes_job_id,
          "superseded_by_job_id" => nil,
          "replacement_proof" => replacement_proof,
          "claims" => [],
          "created_at" => timestamp,
          "updated_at" => timestamp
        }
        validate!(record)
      end

      def validate!(record)
        unless record.is_a?(Hash) && record.keys.sort == TOP_LEVEL_KEYS.sort
          raise Invalid, "babysitter job has unknown or missing top-level fields"
        end
        unless record["schema"] == SCHEMA && record["schema_version"] == SCHEMA_VERSION
          raise Invalid, "unsupported babysitter job schema"
        end
        identity = record["identity"]
        unless identity.is_a?(Hash) && identity.keys.sort == IDENTITY_KEYS.sort
          raise Invalid, "babysitter job identity has invalid fields"
        end
        normalized = self.identity(
          project: identity["project"], task_id: identity["task_id"], task_slug: identity["task_slug"],
          task_generation: identity["task_generation"], repository: identity["repository"],
          pr_number: identity["pr_number"]
        )
        raise Invalid, "babysitter job_id does not match identity" unless record["job_id"] == job_id(normalized)
        raise Invalid, "unknown babysitter job state" unless STATES.include?(record["state"])
        raise Invalid, "babysitter job branch is required" if record["branch"].to_s.empty?
        raise Invalid, "babysitter job task_folder must be absolute" unless record["task_folder"].to_s.start_with?(File::SEPARATOR)
        validate_sha!(record["head_sha"])
        unless record["head_generation"].is_a?(Integer) && record["head_generation"].positive?
          raise Invalid, "babysitter head_generation must be positive"
        end
        raise Invalid, "babysitter finalize_attempt_id is required" if record["finalize_attempt_id"].to_s.empty?
        normalize_pr_url(record["pr_url"], normalized)
        Array(record["claims"]).each { |claim| validate_claim!(claim) }
        %w[created_at updated_at].each { |key| Time.iso8601(record.fetch(key)) }
        record
      rescue ArgumentError, TypeError, KeyError => e
        raise Invalid, "invalid babysitter job: #{e.message}"
      end

      def validate_claim!(claim)
        unless claim.is_a?(Hash) && claim.keys.sort == CLAIM_KEYS.sort
          raise Invalid, "babysitter claim has invalid fields"
        end
        raise Invalid, "babysitter claim owner is required" if claim["owner"].to_s.empty?
        unless claim["claim_fence"].is_a?(Integer) && claim["claim_fence"].positive?
          raise Invalid, "babysitter claim fence must be positive"
        end
        raise Invalid, "unknown babysitter claim state" unless %w[active released superseded].include?(claim["state"])
        %w[claimed_at heartbeat_at expires_at].each { |key| Time.iso8601(claim.fetch(key)) }
        Time.iso8601(claim["finished_at"]) if claim["finished_at"]
        true
      end

      def canonical_repository(value)
        raw = value.to_s.strip
        normalized = if raw.match?(%r{\A[a-z0-9.-]+/[a-z0-9_.-]+/[a-z0-9_.-]+\z}i)
          raw.downcase.sub(/\.git\z/i, "")
        else
          Hive::RepositoryIdentity.normalize(raw)
        end
        unless normalized&.match?(%r{\A[a-z0-9.-]+/[a-z0-9_.-]+/[a-z0-9_.-]+\z}i)
          raise Invalid, "babysitter repository must be a canonical host/owner/name identity"
        end
        normalized.downcase
      end

      def normalize_pr_url(value, identity)
        uri = URI.parse(value.to_s)
        repository = identity.fetch("repository")
        host, owner, name = repository.split("/", 3)
        expected_path = "/#{owner}/#{name}/pull/#{identity.fetch('pr_number')}"
        legacy_path = "/pr/#{identity.fetch('pr_number')}"
        normalized_path = uri.path.sub(%r{/+\z}, "")
        unless uri.scheme == "https" && uri.host&.downcase == host &&
               [ expected_path, legacy_path ].include?(normalized_path) &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise Invalid, "babysitter PR URL does not match canonical identity"
        end
        "https://#{host}#{normalized_path}"
      rescue URI::InvalidURIError, KeyError
        raise Invalid, "babysitter PR URL is invalid"
      end

      def validate_sha!(value)
        return if value.to_s.match?(/\A[0-9a-f]{7,64}\z/)

        raise Invalid, "babysitter head_sha must be a commit SHA"
      end
    end
  end
end
