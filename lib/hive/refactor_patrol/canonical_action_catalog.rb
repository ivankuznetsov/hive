require "digest"
require "fileutils"
require "json"
require "time"
require "uri"
require "hive/atomic_file"
require "hive/config"
require "hive/paths"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/pr_manifest"

module Hive
  module RefactorPatrol
    # Global locator for terminal repository-wide actions. The catalog JSON is
    # disposable; immutable per-action proof archives are written only from a
    # validated terminal aggregate (or its exact materialized link), so proof
    # survives deregistration without making the projection authoritative.
    class CanonicalActionCatalog
      SCHEMA = "hive-refactor-patrol-canonical-action-catalog".freeze
      SCHEMA_VERSION = 1
      CATALOG_KEYS = %w[schema schema_version actions updated_at].freeze
      ENTRY_KEYS = %w[
        canonical_action_id host repository kind identity owner outcome proof
        proof_digest witnesses
      ].freeze
      ARCHIVE_SCHEMA = "hive-refactor-patrol-terminal-proof".freeze
      ARCHIVE_SCHEMA_VERSION = 1
      ARCHIVE_CORE_KEYS = (ENTRY_KEYS - [ "witnesses" ]).freeze
      ARCHIVE_KEYS = (%w[schema schema_version] + ARCHIVE_CORE_KEYS).freeze
      OWNER_KEYS = %w[
        registration project_root job_id pr_number merge_sha
      ].freeze
      WITNESS_KEYS = %w[project_root job_id].freeze
      PROOF_KEYS = %w[
        pr_url review_task_path issue_url issue_number duplicate_issue_urls
      ].freeze
      REMOTE_PR_OUTCOMES = %w[pr_opened merged].freeze
      CLOSED_PR_OUTCOMES = %w[closed_without_merge].freeze
      REMOTE_ISSUE_OUTCOMES = %w[
        issue_created issue_linked_open issue_closed_suppressed
      ].freeze
      REVIEW_TASK_STAGE_DIRS = %w[
        6-review 7-artifacts 8-finalize 9-done
      ].freeze # coding-scoped: patrol review tasks can advance through remaining coding stages

      class Error < StandardError; end
      class CorruptCatalog < Error; end
      class CorruptArchive < Error; end
      class ProofConflict < Error; end
      class ProofUnresolved < Error; end

      attr_reader :root, :path, :archive_root

      def initialize(state_home: Hive::Paths.state_home,
                     registry: -> { Hive::Config.registered_projects },
                     job_store_factory: nil,
                     clock: -> { Time.now })
        @state_root = File.join(File.expand_path(state_home), "refactor_patrol", "v2")
        @root = File.join(@state_root, "indexes")
        @path = File.join(@root, "canonical-actions.json")
        @archive_root = File.join(@state_root, "terminal-proofs")
        @lock_path = File.join(@state_root, "canonical-actions.lock")
        @registry = registry
        @job_store_factory = job_store_factory || lambda do |project_root|
          expanded = File.expand_path(project_root)
          entry = Array(@registry.call).find do |candidate|
            File.expand_path(candidate.fetch("path")) == expanded
          end
          unless entry
            raise ProofUnresolved,
                  "cannot scan an unregistered canonical action owner"
          end
          JobStore.new(
            expanded,
            hive_state_path: entry["hive_state_path"],
            project: entry
          )
        end
        @clock = clock
      end

      def resolve(action_ids:, expected_identity:, dry_run: false)
        ids = Array(action_ids).map(&:to_s).uniq.sort
        return {} if ids.empty?

        identity = normalize_identity(expected_identity)
        catalog = snapshot(dry_run: dry_run)
        ids.each_with_object({}) do |action_id, result|
          entry = catalog.fetch("actions")[action_id]
          next unless entry
          unless entry.fetch("host") == identity.fetch("host") &&
                 entry.fetch("repository") == identity.fetch("repository")
            raise ProofConflict, "canonical action #{action_id.inspect} belongs to another repository"
          end

          result[action_id] = terminal_proof(entry)
        end
      end

      def rebuild!
        snapshot(dry_run: false)
      end

      private

      def snapshot(dry_run:)
        return build_snapshot(existing_catalog, archived_entries) if dry_run

        FileUtils.mkdir_p([ @root, @archive_root ])
        File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          catalog = build_snapshot(existing_catalog, archived_entries)
          persist_archive_entries!(catalog.fetch("actions"))
          Hive::AtomicFile.write(@path, "#{JSON.pretty_generate(catalog)}\n", mode: 0o600)
          Hive::AtomicFile.fsync_directory(@root)
          catalog
        end
      end

      def build_snapshot(existing, archived)
        roots = registered_roots
        entries = archived.transform_values { |entry| archive_witness_entry(entry) }
        scan_roots(roots.uniq.sort).each do |action_id, candidate|
          entries[action_id] = merge_entry(entries[action_id], candidate)
        end
        ensure_existing_proofs_resolved!(existing, entries) if existing
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "actions" => entries.sort.to_h,
          "updated_at" => @clock.call.utc.iso8601
        }
      end

      def registered_roots
        Array(@registry.call).map do |entry|
          unless entry.is_a?(Hash) && entry["path"].is_a?(String) && !entry["path"].empty?
            raise ProofUnresolved, "registered project is missing a canonical path"
          end

          File.expand_path(entry.fetch("path"))
        end
      rescue Error
        raise
      rescue StandardError => e
        raise ProofUnresolved, "cannot enumerate registered projects: #{e.class}: #{e.message}"
      end

      def archive_witness_entry(entry)
        owner = entry.fetch("owner")
        entry.merge(
          "witnesses" => [
            {
              "project_root" => owner.fetch("project_root"),
              "job_id" => owner.fetch("job_id")
            }
          ]
        )
      end

      def scan_roots(roots)
        entries = {}
        roots.each do |project_root|
          next unless File.directory?(project_root)

          store = @job_store_factory.call(project_root)
          store.each_job do |aggregate|
            aggregate.fetch("actions").each do |action|
              next unless action.fetch("terminal") == true
              next unless action.fetch("owner_job_id") == aggregate.fetch("job_id")

              candidate = entry_for_action(store, project_root, aggregate, action)
              entries[candidate.fetch("canonical_action_id")] = merge_entry(
                entries[candidate.fetch("canonical_action_id")], candidate
              )
            end
          end
        rescue JobStore::Error, SystemCallError, IOError => e
          raise ProofUnresolved,
                "cannot rebuild canonical actions from #{project_root}: #{e.class}: #{e.message}"
        end
        entries
      end

      def entry_for_action(store, project_root, aggregate, action)
        source = aggregate.fetch("source")
        identity = source_identity(source)
        action_identity = if action.fetch("kind") == "issue"
          action.fetch("family_id")
        else
          action.fetch("thesis_fingerprint")
        end
        expected_id = store.canonical_action_id(
          repository: identity.fetch("repository"), host: identity.fetch("host"),
          kind: action.fetch("kind"), identity: action_identity
        )
        unless action.fetch("canonical_action_id") == expected_id
          raise ProofConflict, "terminal canonical action identity does not match its source"
        end

        witness = {
          "project_root" => project_root,
          "job_id" => aggregate.fetch("job_id")
        }
        link = action.dig("receipts", "canonical_action_link")
        core = if link
          validate_terminal_proof!(link, expected_action_id: expected_id)
          unless link.fetch("outcome") == action.fetch("outcome")
            raise ProofConflict, "materialized canonical action outcome conflicts with its link"
          end
          link.slice("canonical_action_id", "owner", "outcome", "proof", "proof_digest")
        else
          proof = terminal_receipts(action)
          owner = owner_occurrence(project_root, aggregate)
          payload = {
            "canonical_action_id" => expected_id,
            "owner" => owner,
            "outcome" => action.fetch("outcome"),
            "proof" => proof
          }
          payload.merge("proof_digest" => proof_digest(payload))
        end
        validate_remote_proof!(core, identity)
        {
          "canonical_action_id" => expected_id,
          "host" => identity.fetch("host"),
          "repository" => identity.fetch("repository"),
          "kind" => action.fetch("kind"),
          "identity" => action_identity,
          "owner" => json_copy(core.fetch("owner")),
          "outcome" => core.fetch("outcome"),
          "proof" => json_copy(core.fetch("proof")),
          "proof_digest" => core.fetch("proof_digest"),
          "witnesses" => [ witness ]
        }
      rescue KeyError => e
        raise ProofConflict, "terminal canonical action is missing #{e.key.inspect}"
      end

      def merge_entry(existing, candidate)
        return candidate unless existing

        comparable = ENTRY_KEYS - [ "witnesses" ]
        unless existing.slice(*comparable) == candidate.slice(*comparable)
          raise ProofConflict,
                "canonical action #{candidate.fetch('canonical_action_id').inspect} has conflicting terminal proof"
        end

        existing.merge(
          "witnesses" => (existing.fetch("witnesses") + candidate.fetch("witnesses"))
            .uniq.sort_by { |item| [ item.fetch("project_root"), item.fetch("job_id") ] }
        )
      end

      def ensure_existing_proofs_resolved!(existing, entries)
        existing.fetch("actions").each_key do |action_id|
          unless entries.key?(action_id)
            raise ProofUnresolved,
                  "canonical action #{action_id.inspect} has no readable authoritative aggregate"
          end
        end
      end

      def terminal_receipts(action)
        receipts = action.fetch("receipts")
        receipts.slice(*PROOF_KEYS).compact
      end

      def owner_occurrence(project_root, aggregate)
        source = aggregate.fetch("source")
        {
          "registration" => source.fetch("registration"),
          "project_root" => project_root,
          "job_id" => aggregate.fetch("job_id"),
          "pr_number" => source.fetch("number"),
          "merge_sha" => source.fetch("merge_sha")
        }
      end

      def terminal_proof(entry)
        entry.slice(
          "canonical_action_id", "owner", "outcome", "proof", "proof_digest"
        )
      end

      def validate_terminal_proof!(proof, expected_action_id:)
        unless proof.is_a?(Hash) &&
               proof.keys.sort == %w[canonical_action_id outcome owner proof proof_digest]
          raise ProofConflict, "canonical action link has an invalid shape"
        end
        unless proof.fetch("canonical_action_id") == expected_action_id
          raise ProofConflict, "canonical action link points to another action"
        end
        owner = proof.fetch("owner")
        valid_owner = owner.is_a?(Hash) && owner.keys.sort == OWNER_KEYS.sort &&
                      %w[registration project_root job_id].all? { |key|
                        owner[key].is_a?(String) && !owner[key].empty?
                      } && owner["project_root"] == File.expand_path(owner["project_root"]) &&
                      owner["pr_number"].is_a?(Integer) && owner["pr_number"].positive? &&
                      owner["merge_sha"].to_s.match?(/\A[0-9a-f]{40,64}\z/)
        unless valid_owner
          raise ProofConflict, "canonical action link owner is invalid"
        end
        unless proof.fetch("proof").is_a?(Hash) &&
               (proof.fetch("proof").keys - PROOF_KEYS).empty?
          raise ProofConflict, "canonical action link proof is invalid"
        end
        expected = proof_digest(proof.reject { |key, _| key == "proof_digest" })
        unless proof.fetch("proof_digest").to_s.match?(/\A[a-f0-9]{64}\z/) &&
               proof.fetch("proof_digest") == expected
          raise ProofConflict, "canonical action link digest is invalid"
        end
        proof
      rescue ArgumentError
        raise ProofConflict, "canonical action link owner is invalid"
      end

      def validate_remote_proof!(entry, identity)
        outcome = entry.fetch("outcome")
        proof = entry.fetch("proof")
        if REMOTE_PR_OUTCOMES.include?(outcome)
          validate_object_url!(proof.fetch("pr_url"), identity, "pull")
          validate_review_task_path!(proof.fetch("review_task_path"), entry.fetch("owner"))
        elsif CLOSED_PR_OUTCOMES.include?(outcome)
          validate_object_url!(proof.fetch("pr_url"), identity, "pull")
        elsif REMOTE_ISSUE_OUTCOMES.include?(outcome)
          issue_url = proof.fetch("issue_url")
          issue_number = validate_object_url!(issue_url, identity, "issues")
          if proof.key?("issue_number") &&
             (!proof.fetch("issue_number").is_a?(Integer) ||
              proof.fetch("issue_number") != issue_number)
            raise ProofConflict, "terminal issue proof number does not match its URL"
          end
          validate_duplicate_issue_urls!(
            proof.fetch("duplicate_issue_urls", []), issue_url, identity
          )
        end
      rescue KeyError => e
        raise ProofConflict, "terminal outcome #{outcome.inspect} lacks #{e.key.inspect} proof"
      end

      def validate_object_url!(url, identity, kind)
        uri = URI.parse(url.to_s)
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/#{kind}/([1-9]\d*)\z})
        valid = uri.is_a?(URI::HTTP) && uri.host&.casecmp?(identity.fetch("host")) &&
                match && match[1].casecmp?(identity.fetch("repository")) &&
                uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ProofConflict, "terminal remote proof URL has the wrong repository identity" unless valid

        match[2].to_i
      rescue URI::InvalidURIError
        raise ProofConflict, "terminal remote proof URL is invalid"
      end

      def validate_review_task_path!(value, owner)
        path = value.to_s
        normalized = File.expand_path(path)
        stages_root = File.join(owner.fetch("project_root"), ".hive-state", "stages")
        task_root = File.dirname(normalized)
        stage = File.basename(task_root)
        task_slug = File.basename(normalized)
        valid = !path.empty? && path == normalized &&
                File.dirname(task_root) == stages_root &&
                REVIEW_TASK_STAGE_DIRS.include?(stage) &&
                !task_slug.empty? && !%w[. ..].include?(task_slug)
        unless valid
          raise ProofConflict,
                "published PR terminal proof has an invalid mandatory review handoff"
        end
      rescue ArgumentError
        raise ProofConflict,
              "published PR terminal proof has an invalid mandatory review handoff"
      end

      def validate_duplicate_issue_urls!(urls, primary_url, identity)
        valid = urls.is_a?(Array) && urls.all? { |url| url.is_a?(String) } &&
                urls == urls.uniq.sort && !urls.include?(primary_url)
        raise ProofConflict, "terminal issue duplicate URLs are invalid" unless valid

        urls.each { |url| validate_object_url!(url, identity, "issues") }
      end

      def source_identity(source)
        uri = URI.parse(source.fetch("url").to_s)
        repository = source.fetch("repository").to_s
        match = uri.path.match(%r{\A/([^/]+/[^/]+)/pull/([1-9]\d*)\z})
        valid = uri.is_a?(URI::HTTP) && uri.host && match &&
                match[1].casecmp?(repository) && match[2].to_i == source.fetch("number") &&
                uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ProofConflict, "terminal action source identity is invalid" unless valid

        normalize_identity("host" => uri.host, "repository" => repository)
      rescue KeyError, URI::InvalidURIError
        raise ProofConflict, "terminal action source identity is invalid"
      end

      def normalize_identity(identity)
        unless identity.is_a?(Hash)
          raise ProofConflict, "repository identity must be an object"
        end
        host = (identity["host"] || identity[:host]).to_s.strip.downcase
        repository = (identity["repository"] || identity[:repository]).to_s.strip.downcase
        uri = URI.parse("https://#{host}")
        valid_host = !host.empty? && uri.host == host && uri.path.empty? &&
                     uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        segments = repository.split("/", -1)
        valid_repository = segments.size == 2 && segments.all? do |segment|
          segment.match?(/\A[a-z0-9_.-]+\z/) && !%w[. ..].include?(segment)
        end
        unless valid_host && valid_repository
          raise ProofConflict, "repository identity is invalid"
        end

        { "host" => host, "repository" => repository }
      rescue URI::InvalidURIError
        raise ProofConflict, "repository identity is invalid"
      end


      def archived_entries
        return {} unless File.directory?(@archive_root)

        Dir.glob(File.join(@archive_root, "*.json")).sort.to_h do |path|
          unless File.file?(path)
            raise CorruptArchive, "terminal proof archive entry is not a regular file: #{path}"
          end

          action_id = File.basename(path, ".json")
          data = JSON.parse(File.binread(path))
          [ action_id, validate_archive_entry!(data, action_id, path) ]
        rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
          raise CorruptArchive,
                "terminal proof archive entry is unreadable: #{path} (#{e.class}: #{e.message})"
        end
      end

      def validate_archive_entry!(entry, action_id, path)
        unless action_id.match?(/\A(?:fix|issue)-[a-f0-9]{64}\z/) &&
               entry.is_a?(Hash) && entry.keys.sort == ARCHIVE_KEYS.sort &&
               entry.fetch("schema") == ARCHIVE_SCHEMA &&
               entry.fetch("schema_version") == ARCHIVE_SCHEMA_VERSION &&
               entry.fetch("canonical_action_id") == action_id &&
               JobStore::ACTION_KINDS.include?(entry.fetch("kind")) &&
               !entry.fetch("identity").to_s.empty?
          raise CorruptArchive, "terminal proof archive entry has an invalid shape: #{path}"
        end
        core = entry.slice(*ARCHIVE_CORE_KEYS)
        normalized = normalize_identity(
          "host" => core.fetch("host"), "repository" => core.fetch("repository")
        )
        unless normalized.fetch("host") == core.fetch("host") &&
               normalized.fetch("repository") == core.fetch("repository")
          raise CorruptArchive, "terminal proof archive repository identity is not canonical: #{path}"
        end
        proof = terminal_proof(core)
        validate_terminal_proof!(proof, expected_action_id: action_id)
        expected_id = JobStore.canonical_action_id(
          repository: core.fetch("repository"), host: core.fetch("host"),
          kind: core.fetch("kind"), identity: core.fetch("identity")
        )
        unless expected_id == action_id
          raise CorruptArchive, "terminal proof archive action identity is invalid: #{path}"
        end
        validate_remote_proof!(proof, normalized)
        core
      rescue KeyError, JobStore::Error, ProofConflict => e
        raise CorruptArchive,
              "terminal proof archive entry is invalid: #{path} (#{e.class}: #{e.message})"
      end

      def persist_archive_entries!(entries)
        wrote = false
        entries.each do |action_id, entry|
          archived = entry.slice(*ARCHIVE_CORE_KEYS)
          document = {
            "schema" => ARCHIVE_SCHEMA,
            "schema_version" => ARCHIVE_SCHEMA_VERSION
          }.merge(archived)
          path = File.join(@archive_root, "#{action_id}.json")
          if File.exist?(path)
            existing = validate_archive_entry!(JSON.parse(File.binread(path)), action_id, path)
            unless existing == archived
              raise ProofConflict,
                    "terminal proof archive entry #{action_id.inspect} is immutable"
            end
            next
          end

          Hive::AtomicFile.write(path, "#{JSON.pretty_generate(document)}\n", mode: 0o600)
          wrote = true
        rescue JSON::ParserError, EncodingError, SystemCallError, IOError => e
          raise CorruptArchive,
                "terminal proof archive entry is unreadable: #{path} (#{e.class}: #{e.message})"
        end
        Hive::AtomicFile.fsync_directory(@archive_root) if wrote
      end

      def existing_catalog
        return nil unless File.file?(@path)

        data = JSON.parse(File.binread(@path))
        validate_catalog!(data)
      rescue CorruptCatalog, JSON::ParserError, EncodingError, SystemCallError, IOError
        nil
      end

      def validate_catalog!(data)
        unless data.is_a?(Hash) && data.keys.sort == CATALOG_KEYS.sort &&
               data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION &&
               data["actions"].is_a?(Hash)
          raise CorruptCatalog, "canonical action catalog is invalid"
        end
        Time.iso8601(data.fetch("updated_at"))
        data.fetch("actions").each do |action_id, entry|
          unless entry.is_a?(Hash) && entry.keys.sort == ENTRY_KEYS.sort &&
                 action_id == entry["canonical_action_id"] &&
                 entry["witnesses"].is_a?(Array) && entry["witnesses"].all? do |witness|
                   witness.is_a?(Hash) && witness.keys.sort == WITNESS_KEYS.sort
                 end
            raise CorruptCatalog, "canonical action catalog entry is invalid"
          end
          validate_terminal_proof!(terminal_proof(entry), expected_action_id: action_id)
        end
        data
      rescue ArgumentError, KeyError, ProofConflict
        raise CorruptCatalog, "canonical action catalog is invalid"
      end

      def proof_digest(payload)
        ::Digest::SHA256.hexdigest(PrManifest.canonical_json(payload))
      end

      def json_copy(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
