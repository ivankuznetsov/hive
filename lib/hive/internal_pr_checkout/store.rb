require "digest"
require "fileutils"
require "json"
require "time"
require "hive/artifact_firewall"
require "hive/atomic_file"
require "hive/canonical_json"
require "hive/internal_pr_checkout/identity"
require "hive/internal_pr_checkout/result"

module Hive
  module InternalPrCheckout
    # Durable controller-owned store for internal PR review checkout generations,
    # pending transitions, controller-authored candidate receipts, and
    # constant-anchor chained archive manifests + O(1) bucketed grant lookup.
    class Store
      CURRENT_SCHEMA = "hive.internal-pr-checkout.current".freeze
      PENDING_SCHEMA = "hive.internal-pr-checkout.pending".freeze
      CANDIDATE_SCHEMA = "hive.internal-pr-checkout.candidate".freeze
      HISTORY_ROOT_SCHEMA = "hive.internal-pr-checkout.history-root".freeze
      GRANT_INDEX_SCHEMA = "hive.internal-pr-checkout.grant-index".freeze
      GRANT_BUCKET_SCHEMA = "hive.internal-pr-checkout.grant-bucket".freeze
      LABEL_PAGE_SCHEMA = "hive.internal-pr-checkout.label-page".freeze
      ARCHIVE_MANIFEST_SCHEMA = "hive.internal-pr-checkout.archive-manifest".freeze

      PENDING_PHASES = %w[prepared fetched checked_out confirmed archived projected].freeze
      CANDIDATE_KINDS = %w[fixed approved ci_repaired clean].freeze
      MAX_RECORD_BYTES = Identity::JSON_RECORD_MAX_BYTES
      LABEL_PAGE_LIMIT = 200
      MANIFEST_PAGE_ENTRIES = 200
      MAX_ARCHIVE_DEPTH = 16
      MAX_ARCHIVE_PATH_BYTES = 4_096
      DIGEST_MODULUS = 1 << 256
      SHA256_RE = /\A[0-9a-f]{64}\z/
      OID_RE = Identity::OID_PATTERN
      GRANT_FILE_RE = /\Areview-grant-([0-9a-f]{64})\.json\z/

      class StrictHash < Hash
        def []=(key, value)
          raise JSON::ParserError, "duplicate JSON key #{key.inspect}" if key?(key)

          super
        end
      end

      CustodyCapture = Data.define(
        :task_folder,
        :path_custody,
        :indexed,
        :expected_archive_membership_digest,
        :expected_manifests_membership_digest,
        :archive_before,
        :manifests_before
      )

      attr_reader :task_folder

      def initialize(task_folder)
        @task_folder = File.expand_path(task_folder.to_s)
      end

      def store_dir = Identity.store_dir(@task_folder)
      def current_path = Identity.current_path(@task_folder)
      def pending_path = Identity.pending_path(@task_folder)
      def candidate_path = Identity.candidate_path(@task_folder)
      def history_root_path = Identity.history_root_path(@task_folder)
      def grant_index_path = Identity.grant_index_path(@task_folder)
      def manifests_dir = Identity.manifests_dir(@task_folder)
      def reviews_dir = File.join(@task_folder, "reviews")
      def archive_dir = File.join(reviews_dir, "archive")

      # Constant 6-entry protected anchor set independent of history length.
      def fixed_anchor_paths
        {
          "pr.md" => File.join(@task_folder, "pr.md"),
          "internal-pr-checkout/current.json" => current_path,
          "internal-pr-checkout/pending.json" => pending_path,
          "internal-pr-checkout/candidate.json" => candidate_path,
          "internal-pr-checkout/history-root.json" => history_root_path,
          "internal-pr-checkout/grant-index.json" => grant_index_path
        }.freeze
      end

      def current_present?
        File.exist?(current_path) || File.symlink?(current_path)
      end

      def pending_present?
        File.exist?(pending_path) || File.symlink?(pending_path)
      end

      def candidate_present?
        File.exist?(candidate_path) || File.symlink?(candidate_path)
      end

      def history_root_present?
        File.exist?(history_root_path) || File.symlink?(history_root_path)
      end

      def read_current
        return nil unless current_present?

        doc = read_private_json!(current_path, label: "current.json", error_reason: "sidecar_inconsistent")
        validate_current!(doc)
        doc
      end

      def write_current!(document)
        normalized = Hive::CanonicalJSON.normalize(document)
        validate_current!(normalized)
        write_private_json!(current_path, normalized)
        normalized
      end

      def read_pending
        return nil unless pending_present?

        doc = read_private_json!(pending_path, label: "pending.json", error_reason: "pending_invalid")
        validate_pending!(doc)
        doc
      end

      def write_pending!(document)
        normalized = Hive::CanonicalJSON.normalize(document)
        validate_pending!(normalized)
        write_private_json!(pending_path, normalized)
        normalized
      end

      def clear_pending!
        return false unless pending_present?

        stat = File.lstat(pending_path)
        unless stat.file? && !stat.symlink?
          raise PendingInvalid, "pending.json must be a regular file"
        end
        File.unlink(pending_path)
        Hive::AtomicFile.fsync_directory(store_dir)
        true
      rescue Errno::ENOENT
        false
      end

      def read_candidate
        check_no_stray_candidate_files!
        return nil unless candidate_present?

        doc = read_private_json!(candidate_path, label: "candidate.json", error_reason: "candidate_unproven")
        validate_candidate!(doc)
        doc
      end

      def write_candidate!(document)
        normalized = Hive::CanonicalJSON.normalize(document)
        validate_candidate!(normalized)
        write_private_json!(candidate_path, normalized)
        normalized
      end

      def clear_candidate!
        return false unless candidate_present?

        stat = File.lstat(candidate_path)
        unless stat.file? && !stat.symlink?
          raise Error.new("candidate_unproven", "candidate.json must be a regular file")
        end
        File.unlink(candidate_path)
        Hive::AtomicFile.fsync_directory(store_dir)
        true
      rescue Errno::ENOENT
        false
      end

      def read_history_root
        return nil unless history_root_present?

        doc = read_private_json!(history_root_path, label: "history-root.json", error_reason: "custody_mismatch")
        validate_history_root!(doc)
        doc
      end

      def history_root_sha256
        return nil unless history_root_present?

        file_sha256(history_root_path)
      end

      def read_grant_index
        return nil unless File.exist?(grant_index_path) || File.symlink?(grant_index_path)

        doc = read_private_json!(grant_index_path, label: "grant-index.json", error_reason: "custody_mismatch")
        validate_grant_index!(doc)
        doc
      end

      # Compute the stable head-transition digest that contributes to Attempts
      # generation resolution (R12 / KTD3). Nil for legacy implicit generation 1
      # and initial gen-1 tasks before any head transition.
      def self.head_transition_digest(pr_url:, pr_number:, branch:, reviewed_oid:,
                                      generation:, previous_generation:, retirement_label:,
                                      transaction_id:)
        return nil if previous_generation.nil? && retirement_label.nil?

        Hive::CanonicalJSON.digest(
          "schema" => "hive.internal-pr-checkout.head-transition-v1",
          "pr_url" => pr_url.to_s,
          "pr_number" => Integer(pr_number),
          "branch" => branch.to_s,
          "reviewed_oid" => reviewed_oid.to_s.downcase,
          "generation" => Integer(generation),
          "previous_generation" => previous_generation ? Integer(previous_generation) : nil,
          "retirement_label" => retirement_label&.to_s,
          "transaction_id" => transaction_id.to_s
        )
      end

      # Initialize a brand-new task's generation-1 checkout store (called by U3).
      def initialize_generation_one!(task_id:, task_slug:, project:, pr_host:, pr_repository:,
                                     pr_number:, pr_url:, base_ref_name:, head_ref_name:,
                                     head_repository:, is_cross_repository:, pr_state:,
                                     branch:, head_oid:, committed_at:)
        ensure_private_store_dirs!
        history_root = ensure_empty_history_root!
        current = {
          "schema" => CURRENT_SCHEMA,
          "schema_version" => 1,
          "task_id" => task_id&.to_s,
          "task_slug" => task_slug.to_s,
          "project" => project.to_s,
          "pr_host" => pr_host.to_s.downcase,
          "pr_repository" => pr_repository.to_s.downcase,
          "pr_number" => Integer(pr_number),
          "pr_url" => pr_url.to_s,
          "base_ref_name" => base_ref_name,
          "head_ref_name" => head_ref_name,
          "head_repository" => head_repository,
          "is_cross_repository" => is_cross_repository == true,
          "pr_state" => pr_state.to_s.upcase,
          "branch" => branch.to_s,
          "reviewed_oid" => head_oid.to_s.downcase,
          "candidate_oid" => head_oid.to_s.downcase,
          "generation" => 1,
          "previous_generation" => nil,
          "previous_reviewed_oid" => nil,
          "retirement_label" => nil,
          "candidate_archive_ref" => nil,
          "transaction_id" => "initial",
          "head_transition_digest" => nil,
          "history_root_digest" => file_sha256(history_root_path),
          "committed_at" => committed_at.utc.iso8601(6)
        }
        write_current!(current)
        [ current, history_root ]
      end

      # Seal one newly retired directory `reviews/archive/<label>/` into the
      # paged manifest chain, grant bucket index, and constant-size
      # `history-root.json`. On the first seal of a legacy task that already
      # has preexisting `reviews/archive/*` directories, incorporates all
      # validated preexisting labels in sorted order first.
      def seal_retirement!(label:)
        ensure_private_store_dirs!
        safe_label = validate_archive_label!(label)
        target_dir = File.join(archive_dir, safe_label)
        unless directory_no_follow?(target_dir)
          raise CustodyError.new("custody_mismatch", "retired archive directory #{safe_label.inspect} is missing or unsafe")
        end

        unless history_root_present?
          bootstrap_legacy_history!(excluding: safe_label)
        end

        root = read_history_root
        if root["latest_label"] == safe_label
          # Replay idempotency: verify live membership matches sealed root.
          verify_live_history_membership!(root)
          return [ root, file_sha256(history_root_path) ]
        end

        root = append_label_to_history!(root, safe_label)
        [ root, file_sha256(history_root_path) ]
      end

      # Rebuilds `history-root.json` and `grant-index.json` cleanly after a
      # failed rewind's `PassArchive.restore!` removes an archive directory
      # under the task lease (KTD3 / Output Structure).
      def rebuild_history_after_restore!
        return nil unless history_root_present? || current_present?

        ensure_private_store_dirs!
        clear_manifests_dir!
        root = ensure_empty_history_root!(force_reset: true)
        if directory_no_follow?(archive_dir)
          existing_labels = Dir.children(archive_dir).sort.select do |name|
            directory_no_follow?(File.join(archive_dir, name))
          end
          existing_labels.each do |lbl|
            root = append_label_to_history!(root, lbl)
          end
        end
        sync_current_history_root_digest!
        root
      end

      def sync_current_history_root_digest!
        return nil unless current_present? && history_root_present?

        current = read_current
        digest = file_sha256(history_root_path)
        return current if current["history_root_digest"] == digest

        write_current!(current.merge("history_root_digest" => digest))
      end

      # Verify that live `reviews/archive` and `internal-pr-checkout/manifests`
      # match the sealed `history-root.json`, and `current.json` (if present)
      # agrees on `history_root_digest`.
      def verify_history_integrity!
        return true unless history_root_present?

        root = read_history_root
        grant_index_bytes = read_private_bytes!(grant_index_path, label: "grant-index.json", error_reason: "custody_mismatch")
        unless Digest::SHA256.hexdigest(grant_index_bytes) == root.fetch("grant_index_digest")
          raise CustodyError.new("custody_mismatch", "grant-index.json digest does not match history-root.json")
        end
        validate_grant_index!(parse_strict_json!(grant_index_bytes, label: "grant-index.json", error_reason: "custody_mismatch"))

        if current_present?
          current = read_current
          unless current["history_root_digest"] == file_sha256(history_root_path)
            raise CustodyError.new("custody_mismatch", "current.json history_root_digest does not match history-root.json")
          end
        end

        verify_live_history_membership!(root)
        true
      end

      # Bounded O(1) authenticated grant lookup for `ReviewBudget::Store#archived_grant`.
      # Returns `:not_indexed` when no `history-root.json` exists yet so legacy
      # tasks keep their existing scan path.
      # Otherwise returns an Array of verified raw JSON Strings (possibly empty).
      def lookup_archived_grant_bytes(token)
        return :not_indexed unless history_root_present?
        unless token.is_a?(String) && token.match?(SHA256_RE)
          raise CustodyError.new("custody_mismatch", "grant lookup token must be a SHA-256 digest")
        end

        root = read_history_root
        grant_index_bytes = read_private_bytes!(grant_index_path, label: "grant-index.json", error_reason: "custody_mismatch")
        unless Digest::SHA256.hexdigest(grant_index_bytes) == root.fetch("grant_index_digest")
          raise CustodyError.new("custody_mismatch", "grant-index.json digest mismatch")
        end
        grant_index = parse_strict_json!(grant_index_bytes, label: "grant-index.json", error_reason: "custody_mismatch")
        validate_grant_index!(grant_index)

        prefix = token[0, 2]
        expected_bucket_digest = grant_index.fetch("buckets")[prefix]
        return [] unless expected_bucket_digest

        bucket_path = File.join(manifests_dir, "grant-bucket-#{prefix}.json")
        bucket_bytes = read_private_bytes!(bucket_path, label: "grant-bucket-#{prefix}.json", error_reason: "custody_mismatch")
        unless Digest::SHA256.hexdigest(bucket_bytes) == expected_bucket_digest
          raise CustodyError.new("custody_mismatch", "grant bucket #{prefix} digest mismatch")
        end
        bucket = parse_strict_json!(bucket_bytes, label: "grant-bucket-#{prefix}.json", error_reason: "custody_mismatch")
        unless bucket.is_a?(Hash) && bucket["schema"] == GRANT_BUCKET_SCHEMA && bucket["schema_version"] == 1 &&
               bucket["prefix"] == prefix && bucket["entries"].is_a?(Hash)
          raise CustodyError.new("custody_mismatch", "grant bucket #{prefix} schema is invalid")
        end

        matches = Array(bucket.fetch("entries")[token])
        matches.map do |entry|
          label = validate_archive_label!(entry.fetch("label"))
          filename = entry.fetch("file").to_s
          unless filename == "review-grant-#{token}.json"
            raise CustodyError.new("custody_mismatch", "indexed grant filename is invalid")
          end
          expected_sha = entry.fetch("sha256").to_s
          unless expected_sha.match?(SHA256_RE)
            raise CustodyError.new("custody_mismatch", "indexed grant digest is invalid")
          end
          verify_manifest_member!(
            label: label,
            relative_path: filename,
            expected_sha256: expected_sha,
            manifest_file: entry.fetch("manifest_file").to_s,
            manifest_digest: entry.fetch("manifest_digest").to_s
          )
          grant_path = File.join(archive_dir, label, filename)
          bytes = read_private_bytes!(grant_path, label: filename, error_reason: "custody_mismatch")
          unless Digest::SHA256.hexdigest(bytes) == expected_sha
            raise CustodyError.new("custody_mismatch", "archived grant #{label}/#{filename} bytes do not match sealed manifest")
          end
          bytes
        end
      end

      # Verify an individual archived file against its sealed manifest when
      # history is indexed.
      def verify_archived_file!(label:, relative_path:)
        return true unless history_root_present?

        safe_label = validate_archive_label!(label)
        entry = find_label_entry(safe_label)
        unless entry
          raise CustodyError.new("custody_mismatch", "archive label #{safe_label.inspect} is not in sealed history")
        end
        manifest_entry = find_manifest_entry(
          manifest_head_file: entry.fetch("manifest_head_file"),
          manifest_head_digest: entry.fetch("manifest_head_digest"),
          relative_path: relative_path
        )
        unless manifest_entry
          raise CustodyError.new("custody_mismatch", "file #{relative_path.inspect} is not in sealed manifest for #{safe_label}")
        end

        full = File.join(archive_dir, safe_label, relative_path)
        actual_sha = file_sha256(full)
        unless actual_sha == manifest_entry.fetch("sha256")
          raise CustodyError.new("custody_mismatch", "archived file #{safe_label}/#{relative_path} digest mismatch")
        end
        true
      end

      # Capture constant-anchor custody + streaming directory-tree digests
      # before an untrusted agent spawn (U2.9).
      def capture_custody
        verify_history_integrity! if history_root_present?
        path_custody = Hive::ArtifactFirewall::PathCustody.new(fixed_anchor_paths)
        archive_before = tree_digest!(archive_dir)
        manifests_before = tree_digest!(manifests_dir)

        root = history_root_present? ? read_history_root : nil
        CustodyCapture.new(
          task_folder: @task_folder,
          path_custody: path_custody,
          indexed: !root.nil?,
          expected_archive_membership_digest: root ? root.fetch("archive_membership_digest") : archive_before.fetch(:membership_digest),
          expected_manifests_membership_digest: root ? root.fetch("manifests_membership_digest") : manifests_before.fetch(:membership_digest),
          archive_before: archive_before,
          manifests_before: manifests_before
        )
      end

      # Verify constant-anchor custody + streaming directory-tree digests after
      # an untrusted agent spawn (U2.9). Restores only proven fixed-anchor
      # original bytes; never rebaselines unexpected archive/manifest changes.
      def verify_custody!(capture)
        unless capture.is_a?(CustodyCapture) && capture.task_folder == @task_folder
          raise CustodyError.new("custody_mismatch", "custody capture does not belong to this task")
        end

        changed_anchors = []
        restore_error = nil
        begin
          changed_anchors = capture.path_custody.restore_changes!
        rescue Hive::ArtifactFirewall::Error, SystemCallError => e
          restore_error = e
        end

        archive_after = tree_digest!(archive_dir)
        manifests_after = tree_digest!(manifests_dir)

        archive_tampered = archive_after.fetch(:stat_digest) != capture.archive_before.fetch(:stat_digest) ||
                           archive_after.fetch(:membership_digest) != capture.expected_archive_membership_digest
        manifests_tampered = manifests_after.fetch(:stat_digest) != capture.manifests_before.fetch(:stat_digest) ||
                             manifests_after.fetch(:membership_digest) != capture.expected_manifests_membership_digest

        if restore_error
          raise CustodyError.new(
            "custody_mismatch",
            "protected internal PR checkout anchor restoration failed (#{restore_error.class})"
          )
        end
        if archive_tampered || manifests_tampered
          raise CustodyError.new(
            "custody_mismatch",
            "agent modified sealed review archive or manifest history; evidence is unusable until repaired"
          )
        end
        unless changed_anchors.empty?
          raise CustodyError.new(
            "custody_mismatch",
            "agent modified protected internal PR checkout anchors (#{changed_anchors.join(', ')}); original bytes were restored"
          )
        end

        true
      end

      # List every archive label known to the sealed history root (walking
      # chained label pages cleanly).
      def sealed_labels
        return [] unless history_root_present?

        root = read_history_root
        labels = []
        page_ref = root["label_chain_head"]
        while page_ref
          page = read_verified_label_page!(page_ref.fetch("file"), page_ref.fetch("digest"))
          labels.unshift(*page.fetch("entries").map { |entry| entry.fetch("label") })
          page_ref = page["previous_page"]
        end
        labels
      end

      private

      def verify_live_history_membership!(root)
        archive_live = tree_digest!(archive_dir)
        manifests_live = tree_digest!(manifests_dir)
        if archive_live[:non_directory] || manifests_live[:non_directory]
          raise CustodyError.new("custody_mismatch", "archive or manifests root is not a real directory")
        end
        unless archive_live.fetch(:membership_digest) == root.fetch("archive_membership_digest")
          raise CustodyError.new(
            "custody_mismatch",
            "live reviews/archive membership does not match sealed history-root.json"
          )
        end
        unless manifests_live.fetch(:membership_digest) == root.fetch("manifests_membership_digest")
          raise CustodyError.new(
            "custody_mismatch",
            "live internal-pr-checkout/manifests membership does not match sealed history-root.json"
          )
        end
        true
      end

      def tree_digest!(path)
        Hive::ArtifactFirewall.tree_inventory_digest(
          path, max_depth: MAX_ARCHIVE_DEPTH, max_path_bytes: MAX_ARCHIVE_PATH_BYTES
        )
      rescue Hive::ArtifactFirewall::LimitExceeded => e
        raise CustodyError.new("custody_limit_exceeded", e.message)
      rescue Hive::ArtifactFirewall::Error => e
        raise CustodyError.new("custody_mismatch", e.message)
      end

      def bootstrap_legacy_history!(excluding:)
        root = ensure_empty_history_root!
        return root unless directory_no_follow?(archive_dir)

        prior_labels = Dir.children(archive_dir).sort.reject { |name| name == excluding }.select do |name|
          path = File.join(archive_dir, name)
          stat = File.lstat(path)
          if stat.symlink?
            raise CustodyError.new("custody_mismatch", "legacy reviews/archive contains symlink #{name.inspect}")
          end
          stat.directory?
        end
        prior_labels.each do |prior|
          root = append_label_to_history!(root, prior)
        end
        root
      end

      def ensure_empty_history_root!(force_reset: false)
        if !force_reset && history_root_present? && File.exist?(grant_index_path)
          return read_history_root
        end

        ensure_private_store_dirs!
        grant_index = {
          "schema" => GRANT_INDEX_SCHEMA,
          "schema_version" => 1,
          "buckets" => {}
        }
        write_private_json!(grant_index_path, grant_index)
        grant_index_digest = file_sha256(grant_index_path)

        archive_present = directory_no_follow?(archive_dir)
        empty_archive_digest = Hive::ArtifactFirewall.fold_membership_digest([], present: archive_present)
        empty_manifests_digest = Hive::ArtifactFirewall.fold_membership_digest([], present: true)
        root = {
          "schema" => HISTORY_ROOT_SCHEMA,
          "schema_version" => 1,
          "generation_count" => 0,
          "next_ordinal" => 1,
          "latest_label" => nil,
          "label_chain_head" => nil,
          "grant_index_digest" => grant_index_digest,
          "archive_membership_state" => { "present" => archive_present, "count" => 0, "sum" => "0", "xor" => "0" },
          "archive_membership_digest" => empty_archive_digest,
          "manifests_membership_state" => { "present" => true, "count" => 0, "sum" => "0", "xor" => "0" },
          "manifests_membership_digest" => empty_manifests_digest
        }
        write_private_json!(history_root_path, root)
        root
      end

      def append_label_to_history!(root, label)
        safe_label = validate_archive_label!(label)
        target_dir = File.join(archive_dir, safe_label)
        entries, grant_candidates = scan_archive_label!(target_dir, safe_label)

        manifests_state = root.fetch("manifests_membership_state").dup
        manifest_prefix = "archive-#{Digest::SHA256.hexdigest(safe_label)[0, 16]}"
        manifest_head_file, manifest_head_digest, file_to_manifest = write_archive_manifest_pages!(
          safe_label, manifest_prefix, entries, manifests_state
        )

        # Update grant buckets for any retired review-grant-*.json files.
        grant_index = read_grant_index
        grant_index_changed = false
        grant_candidates.each do |candidate|
          token = candidate.fetch("token")
          prefix = token[0, 2]
          bucket_file = "grant-bucket-#{prefix}.json"
          bucket_path = File.join(manifests_dir, bucket_file)
          existed = File.file?(bucket_path) && !File.symlink?(bucket_path)
          bucket = if existed
            expected = grant_index.fetch("buckets").fetch(prefix)
            raw = read_private_bytes!(bucket_path, label: bucket_file, error_reason: "custody_mismatch")
            unless Digest::SHA256.hexdigest(raw) == expected
              raise CustodyError.new("custody_mismatch", "grant bucket #{prefix} digest mismatch")
            end
            parse_strict_json!(raw, label: bucket_file, error_reason: "custody_mismatch")
          else
            { "schema" => GRANT_BUCKET_SCHEMA, "schema_version" => 1, "prefix" => prefix, "entries" => {} }
          end

          m_file, m_digest = file_to_manifest.fetch(candidate.fetch("file"))
          record = {
            "label" => safe_label,
            "file" => candidate.fetch("file"),
            "sha256" => candidate.fetch("sha256"),
            "manifest_file" => m_file,
            "manifest_digest" => m_digest
          }
          list = Array(bucket["entries"][token])
          list << record unless list.include?(record)
          bucket["entries"][token] = list
          write_private_json!(bucket_path, bucket)
          add_membership_entry!(manifests_state, bucket_file, "file") unless existed
          grant_index["buckets"][prefix] = file_sha256(bucket_path)
          grant_index_changed = true
        end
        write_private_json!(grant_index_path, grant_index) if grant_index_changed
        grant_index_digest = file_sha256(grant_index_path)

        # Append label record to chained label pages.
        retirement_receipt_path = File.join(target_dir, "retirement.json")
        receipt_digest = if File.file?(retirement_receipt_path) && !File.symlink?(retirement_receipt_path)
          file_sha256(retirement_receipt_path)
        end
        ordinal = root.fetch("generation_count") + 1
        label_entry = {
          "ordinal" => ordinal,
          "label" => safe_label,
          "manifest_head_file" => manifest_head_file,
          "manifest_head_digest" => manifest_head_digest,
          "retirement_receipt_digest" => receipt_digest,
          "entry_count" => entries.length
        }
        new_chain_head = append_label_page!(root["label_chain_head"], label_entry, manifests_state)

        # Fold this retired directory and its entries into archive_membership_state.
        archive_state = root.fetch("archive_membership_state").dup
        archive_state["present"] = true
        add_membership_entry!(archive_state, safe_label, "directory")
        entries.each do |entry|
          add_membership_entry!(archive_state, "#{safe_label}/#{entry.fetch('path')}", entry.fetch("kind"))
        end

        updated_root = {
          "schema" => HISTORY_ROOT_SCHEMA,
          "schema_version" => 1,
          "generation_count" => ordinal,
          "next_ordinal" => ordinal + 1,
          "latest_label" => safe_label,
          "label_chain_head" => new_chain_head,
          "grant_index_digest" => grant_index_digest,
          "archive_membership_state" => archive_state,
          "archive_membership_digest" => finalize_membership_state(archive_state),
          "manifests_membership_state" => manifests_state,
          "manifests_membership_digest" => finalize_membership_state(manifests_state)
        }
        write_private_json!(history_root_path, updated_root)
        updated_root
      end

      def scan_archive_label!(label_dir, label)
        entries = []
        grants = []
        stack = [ [ label_dir, "", 1 ] ]
        until stack.empty?
          current_dir, prefix, depth = stack.pop
          if depth > MAX_ARCHIVE_DEPTH
            raise CustodyError.new("custody_limit_exceeded", "archive #{label} depth exceeds #{MAX_ARCHIVE_DEPTH}")
          end

          Dir.children(current_dir).sort.each do |name|
            rel = prefix.empty? ? name : "#{prefix}/#{name}"
            full_rel = "#{label}/#{rel}"
            if full_rel.bytesize > MAX_ARCHIVE_PATH_BYTES
              raise CustodyError.new("custody_limit_exceeded", "archive path exceeds #{MAX_ARCHIVE_PATH_BYTES} bytes")
            end

            full = File.join(current_dir, name)
            stat = File.lstat(full)
            if stat.symlink?
              entries << {
                "path" => rel,
                "kind" => "symlink",
                "mode" => stat.mode & 0o7777,
                "link_target" => File.readlink(full)
              }
            elsif stat.directory?
              entries << {
                "path" => rel,
                "kind" => "directory",
                "mode" => stat.mode & 0o7777
              }
              stack << [ full, rel, depth + 1 ]
            elsif stat.file?
              sha = file_sha256(full)
              entries << {
                "path" => rel,
                "kind" => "file",
                "mode" => stat.mode & 0o7777,
                "size" => stat.size,
                "sha256" => sha
              }
              if prefix.empty? && (match = name.match(GRANT_FILE_RE))
                grants << { "token" => match[1], "file" => name, "sha256" => sha }
              end
            else
              raise CustodyError.new("custody_mismatch", "archive #{label} contains unsupported file type #{stat.ftype}")
            end
          end
        end
        [ entries.sort_by { |e| e.fetch("path") }, grants ]
      end

      def write_archive_manifest_pages!(label, prefix, entries, manifests_state)
        chunks = entries.empty? ? [ [] ] : entries.each_slice(MANIFEST_PAGE_ENTRIES).to_a
        prev_file = nil
        prev_digest = nil
        file_to_manifest = {}

        chunks.each_with_index do |slice, idx|
          page_file = "#{prefix}-p#{format('%04d', idx)}.json"
          page_path = File.join(manifests_dir, page_file)
          existed = File.file?(page_path) && !File.symlink?(page_path)
          doc = {
            "schema" => ARCHIVE_MANIFEST_SCHEMA,
            "schema_version" => 1,
            "label" => label,
            "page" => idx,
            "previous_page" => prev_file ? { "file" => prev_file, "digest" => prev_digest } : nil,
            "entries" => slice
          }
          write_private_json!(page_path, doc)
          add_membership_entry!(manifests_state, page_file, "file") unless existed
          digest = file_sha256(page_path)
          slice.each do |entry|
            file_to_manifest[entry.fetch("path")] = [ page_file, digest ]
          end
          prev_file = page_file
          prev_digest = digest
        end

        [ prev_file, prev_digest, file_to_manifest ]
      end

      def append_label_page!(current_head, label_entry, manifests_state)
        if current_head.nil?
          page_index = 0
          page_file = "label-page-0000.json"
          page_path = File.join(manifests_dir, page_file)
          existed = File.file?(page_path) && !File.symlink?(page_path)
          doc = {
            "schema" => LABEL_PAGE_SCHEMA,
            "schema_version" => 1,
            "page" => page_index,
            "previous_page" => nil,
            "entries" => [ label_entry ]
          }
          write_private_json!(page_path, doc)
          add_membership_entry!(manifests_state, page_file, "file") unless existed
          return { "file" => page_file, "digest" => file_sha256(page_path), "count" => 1 }
        end

        head_file = current_head.fetch("file")
        head_page = read_verified_label_page!(head_file, current_head.fetch("digest"))
        existing_entries = head_page.fetch("entries")
        if existing_entries.length < LABEL_PAGE_LIMIT
          updated = head_page.merge("entries" => existing_entries + [ label_entry ])
          encoded = "#{Hive::CanonicalJSON.generate(updated)}\n"
          if encoded.bytesize <= MAX_RECORD_BYTES / 2
            page_path = File.join(manifests_dir, head_file)
            write_private_json!(page_path, updated)
            return { "file" => head_file, "digest" => file_sha256(page_path), "count" => updated["entries"].length }
          end
        end

        next_index = head_page.fetch("page") + 1
        next_file = "label-page-#{format('%04d', next_index)}.json"
        next_path = File.join(manifests_dir, next_file)
        existed = File.file?(next_path) && !File.symlink?(next_path)
        doc = {
          "schema" => LABEL_PAGE_SCHEMA,
          "schema_version" => 1,
          "page" => next_index,
          "previous_page" => { "file" => head_file, "digest" => current_head.fetch("digest") },
          "entries" => [ label_entry ]
        }
        write_private_json!(next_path, doc)
        add_membership_entry!(manifests_state, next_file, "file") unless existed
        { "file" => next_file, "digest" => file_sha256(next_path), "count" => 1 }
      end

      def read_verified_label_page!(filename, expected_digest)
        safe = validate_manifest_filename!(filename)
        path = File.join(manifests_dir, safe)
        bytes = read_private_bytes!(path, label: safe, error_reason: "custody_mismatch")
        unless Digest::SHA256.hexdigest(bytes) == expected_digest
          raise CustodyError.new("custody_mismatch", "label page #{safe} digest mismatch")
        end
        page = parse_strict_json!(bytes, label: safe, error_reason: "custody_mismatch")
        unless page.is_a?(Hash) && page["schema"] == LABEL_PAGE_SCHEMA &&
               page["schema_version"] == 1 && page["entries"].is_a?(Array)
          raise CustodyError.new("custody_mismatch", "label page #{safe} schema is invalid")
        end
        page
      end

      def verify_manifest_member!(label:, relative_path:, expected_sha256:, manifest_file:, manifest_digest:)
        safe_file = validate_manifest_filename!(manifest_file)
        path = File.join(manifests_dir, safe_file)
        bytes = read_private_bytes!(path, label: safe_file, error_reason: "custody_mismatch")
        unless Digest::SHA256.hexdigest(bytes) == manifest_digest
          raise CustodyError.new("custody_mismatch", "archive manifest #{safe_file} digest mismatch")
        end
        doc = parse_strict_json!(bytes, label: safe_file, error_reason: "custody_mismatch")
        unless doc.is_a?(Hash) && doc["schema"] == ARCHIVE_MANIFEST_SCHEMA &&
               doc["schema_version"] == 1 && doc["label"] == label && doc["entries"].is_a?(Array)
          raise CustodyError.new("custody_mismatch", "archive manifest #{safe_file} schema is invalid")
        end
        entry = doc.fetch("entries").find { |item| item["path"] == relative_path && item["kind"] == "file" }
        unless entry && entry["sha256"] == expected_sha256
          raise CustodyError.new("custody_mismatch", "archive manifest #{safe_file} does not match #{relative_path}")
        end
        true
      end

      def find_label_entry(label)
        root = read_history_root
        page_ref = root["label_chain_head"]
        while page_ref
          page = read_verified_label_page!(page_ref.fetch("file"), page_ref.fetch("digest"))
          found = page.fetch("entries").find { |entry| entry["label"] == label }
          return found if found

          page_ref = page["previous_page"]
        end
        nil
      end

      def find_manifest_entry(manifest_head_file:, manifest_head_digest:, relative_path:)
        file = manifest_head_file
        digest = manifest_head_digest
        while file
          safe_file = validate_manifest_filename!(file)
          bytes = read_private_bytes!(File.join(manifests_dir, safe_file), label: safe_file, error_reason: "custody_mismatch")
          unless Digest::SHA256.hexdigest(bytes) == digest
            raise CustodyError.new("custody_mismatch", "archive manifest #{safe_file} digest mismatch")
          end
          doc = parse_strict_json!(bytes, label: safe_file, error_reason: "custody_mismatch")
          found = doc.fetch("entries").find { |item| item["path"] == relative_path }
          return found if found

          prev = doc["previous_page"]
          file = prev&.fetch("file")
          digest = prev&.fetch("digest")
        end
        nil
      end

      def add_membership_entry!(state, relative, kind)
        token = "m\0#{relative}\0#{kind}"
        h1 = Digest::SHA256.digest(token).unpack1("H*").to_i(16)
        h2 = Digest::SHA256.digest("x\0#{token}").unpack1("H*").to_i(16)
        sum = (state.fetch("sum").to_i(16) + h1) % DIGEST_MODULUS
        xor = state.fetch("xor").to_i(16) ^ h2
        state["count"] = state.fetch("count").to_i + 1
        state["sum"] = sum.to_s(16)
        state["xor"] = xor.to_s(16)
      end

      def finalize_membership_state(state)
        return Digest::SHA256.hexdigest("hive-tree-missing-v1") unless state.fetch("present")

        Digest::SHA256.hexdigest(
          "hive-tree-membership-v1\0#{state.fetch('count')}\0#{state.fetch('sum')}\0#{state.fetch('xor')}"
        )
      end

      def clear_manifests_dir!
        return unless directory_no_follow?(manifests_dir)

        Dir.children(manifests_dir).each do |name|
          path = File.join(manifests_dir, name)
          stat = File.lstat(path)
          raise CustodyError.new("custody_mismatch", "unexpected non-file in manifests: #{name}") unless stat.file? && !stat.symlink?

          File.unlink(path)
        end
        Hive::AtomicFile.fsync_directory(manifests_dir)
      end

      def check_no_stray_candidate_files!
        return unless directory_no_follow?(store_dir)

        strays = Dir.children(store_dir).select do |name|
          name.start_with?("candidate") && name != Identity::CANDIDATE_FILE
        end
        return if strays.empty?

        raise Error.new(
          "candidate_unproven",
          "multiple or unexpected candidate receipts exist in internal-pr-checkout/: #{strays.join(', ')}"
        )
      end

      def ensure_private_store_dirs!
        verify_dir_chain!(@task_folder)
        mkdir_private!(store_dir)
        mkdir_private!(manifests_dir)
      end

      def mkdir_private!(path)
        begin
          Dir.mkdir(path, 0o700)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
        rescue Errno::EEXIST
          unless directory_no_follow?(path)
            raise CustodyError.new("custody_mismatch", "#{File.basename(path)} must be a real directory")
          end
        end
        File.chmod(0o700, path)
        stat = File.lstat(path)
        unless stat.directory? && !stat.symlink? && (stat.mode & 0o077).zero?
          raise CustodyError.new("custody_mismatch", "#{File.basename(path)} must be a private directory")
        end
      end

      def verify_dir_chain!(path)
        current = File::SEPARATOR
        File.expand_path(path).split(File::SEPARATOR).reject(&:empty?).each do |part|
          current = File.join(current, part)
          stat = File.lstat(current)
          unless stat.directory? && !stat.symlink?
            raise CustodyError.new("custody_mismatch", "parent directory #{part.inspect} must be a real directory")
          end
        end
      rescue Errno::ENOENT
        raise CustodyError.new("custody_mismatch", "directory #{path} is missing")
      end

      def directory_no_follow?(path)
        stat = File.lstat(path)
        stat.directory? && !stat.symlink?
      rescue Errno::ENOENT
        false
      end

      def write_private_json!(path, doc)
        ensure_private_store_dirs!
        bytes = "#{Hive::CanonicalJSON.generate(doc)}\n"
        if bytes.bytesize > MAX_RECORD_BYTES
          raise CustodyError.new("custody_limit_exceeded", "#{File.basename(path)} exceeds #{MAX_RECORD_BYTES} bytes")
        end
        Hive::AtomicFile.write(path, bytes, mode: 0o600, fsync: true)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def read_private_json!(path, label:, error_reason:)
        bytes = read_private_bytes!(path, label: label, error_reason: error_reason)
        parse_strict_json!(bytes, label: label, error_reason: error_reason)
      end

      def read_private_bytes!(path, label:, error_reason:)
        verify_dir_chain!(File.dirname(path))
        stat = File.lstat(path)
        if stat.symlink? || !stat.file?
          raise error_for(error_reason, "#{label} must be a regular file, not a symlink")
        end
        if path.start_with?("#{store_dir}#{File::SEPARATOR}") && !(stat.mode & 0o077).zero?
          raise error_for(error_reason, "#{label} must be owner-private (mode 0600)")
        end

        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise error_for(error_reason, "#{label} changed while opening")
          end
          bytes = file.read(MAX_RECORD_BYTES + 1) || ""
          if bytes.bytesize > MAX_RECORD_BYTES
            raise CustodyError.new("custody_limit_exceeded", "#{label} exceeds #{MAX_RECORD_BYTES} bytes")
          end
          bytes
        end
      rescue Errno::ENOENT
        raise error_for(error_reason, "#{label} is missing")
      rescue Errno::ELOOP
        raise error_for(error_reason, "#{label} must be a regular file, not a symlink")
      rescue SystemCallError, IOError => e
        raise error_for(error_reason, "#{label} could not be read (#{e.class})")
      end

      def parse_strict_json!(bytes, label:, error_reason:)
        parsed = JSON.parse(bytes, object_class: StrictHash, allow_duplicate_key: false)
        de_strict_json(parsed)
      rescue JSON::ParserError => e
        raise error_for(error_reason, "#{label} is malformed JSON: #{e.message}")
      end

      def de_strict_json(value)
        case value
        when StrictHash
          value.each_with_object({}) { |(k, v), acc| acc[k] = de_strict_json(v) }
        when Array
          value.map { |item| de_strict_json(item) }
        else
          value
        end
      end

      def error_for(reason, message)
        return PendingInvalid.new(message) if reason == "pending_invalid"
        return CustodyError.new(reason, message) if reason.start_with?("custody_")

        Error.new(reason, message)
      end

      def file_sha256(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          raise CustodyError.new("custody_mismatch", "#{File.basename(path)} must be a regular file")
        end
        digest = Digest::SHA256.new
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise CustodyError.new("custody_mismatch", "#{File.basename(path)} changed while hashing")
          end
          while (chunk = file.read(64 * 1024))
            digest << chunk
          end
        end
        digest.hexdigest
      end

      def validate_current!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == CURRENT_SCHEMA && doc["schema_version"] == 1
          raise Error.new("sidecar_inconsistent", "current.json schema or version is invalid")
        end
        unless doc["pr_number"].is_a?(Integer) && doc["pr_number"].positive? &&
               doc["generation"].is_a?(Integer) && doc["generation"].positive? &&
               doc["reviewed_oid"].to_s.match?(OID_RE) &&
               doc["candidate_oid"].to_s.match?(OID_RE) &&
               !doc["task_slug"].to_s.empty? &&
               !doc["pr_url"].to_s.empty? &&
               !doc["branch"].to_s.empty? &&
               !doc["transaction_id"].to_s.empty?
          raise Error.new("sidecar_inconsistent", "current.json fields are invalid or incomplete")
        end
        if doc["head_transition_digest"] && !doc["head_transition_digest"].to_s.match?(SHA256_RE)
          raise Error.new("sidecar_inconsistent", "current.json head_transition_digest is invalid")
        end
        if doc["history_root_digest"] && !doc["history_root_digest"].to_s.match?(SHA256_RE)
          raise Error.new("sidecar_inconsistent", "current.json history_root_digest is invalid")
        end
        expected_digest = self.class.head_transition_digest(
          pr_url: doc["pr_url"],
          pr_number: doc["pr_number"],
          branch: doc["branch"],
          reviewed_oid: doc["reviewed_oid"],
          generation: doc["generation"],
          previous_generation: doc["previous_generation"],
          retirement_label: doc["retirement_label"],
          transaction_id: doc["transaction_id"]
        )
        unless doc["head_transition_digest"] == expected_digest
          raise Error.new("sidecar_inconsistent", "current.json head_transition_digest does not match committed transition fields")
        end
        true
      end

      def validate_pending!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == PENDING_SCHEMA && doc["schema_version"] == 1
          raise PendingInvalid, "pending.json schema or version is invalid"
        end
        unless PENDING_PHASES.include?(doc["phase"].to_s) &&
               doc["transaction_id"].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/) &&
               doc["pr_number"].is_a?(Integer) && doc["pr_number"].positive? &&
               doc["old_generation"].is_a?(Integer) && doc["old_generation"].positive? &&
               doc["after_generation"].is_a?(Integer) && doc["after_generation"] == doc["old_generation"] + 1 &&
               doc["old_reviewed_oid"].to_s.match?(OID_RE) &&
               doc["old_candidate_oid"].to_s.match?(OID_RE) &&
               doc["target_oid"].to_s.match?(OID_RE) &&
               doc["quarantine_ref"].to_s == Identity.quarantine_ref_for(doc["transaction_id"]) &&
               doc["retirement_label"].to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/) &&
               doc["branch"].to_s == Identity.branch_for(doc["pr_number"]) &&
               !doc["worktree_path"].to_s.empty? &&
               doc["remote_fingerprint"].to_s.match?(SHA256_RE)
          raise PendingInvalid, "pending.json transaction fields are invalid"
        end
        if %w[confirmed archived projected].include?(doc["phase"])
          confirmed = doc["confirmed_observation"]
          unless confirmed.is_a?(Hash) && confirmed["head_oid"] == doc["target_oid"] &&
                 confirmed["number"] == doc["pr_number"] && confirmed["url"] == doc["pr_url"]
            raise PendingInvalid, "pending.json phase #{doc['phase']} is missing valid confirmed_observation"
          end
        end
        true
      end

      def validate_candidate!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == CANDIDATE_SCHEMA && doc["schema_version"] == 1
          raise Error.new("candidate_unproven", "candidate.json schema or version is invalid")
        end
        unless doc["pr_number"].is_a?(Integer) && doc["pr_number"].positive? &&
               doc["generation"].is_a?(Integer) && doc["generation"].positive? &&
               doc["pass"].is_a?(Integer) && doc["pass"].positive? &&
               CANDIDATE_KINDS.include?(doc["kind"].to_s) &&
               doc["reviewed_oid"].to_s.match?(OID_RE) &&
               doc["candidate_oid"].to_s.match?(OID_RE) &&
               !doc["task_slug"].to_s.empty? &&
               !doc["pr_url"].to_s.empty? &&
               !doc["pr_host"].to_s.empty? &&
               !doc["pr_repository"].to_s.empty?
          raise Error.new("candidate_unproven", "candidate.json fields are invalid or incomplete")
        end
        true
      end

      def validate_history_root!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == HISTORY_ROOT_SCHEMA && doc["schema_version"] == 1 &&
               doc["generation_count"].is_a?(Integer) && doc["generation_count"] >= 0 &&
               doc["next_ordinal"].is_a?(Integer) && doc["next_ordinal"] == doc["generation_count"] + 1 &&
               doc["grant_index_digest"].to_s.match?(SHA256_RE) &&
               doc["archive_membership_digest"].to_s.match?(SHA256_RE) &&
               doc["manifests_membership_digest"].to_s.match?(SHA256_RE) &&
               doc["archive_membership_state"].is_a?(Hash) &&
               doc["manifests_membership_state"].is_a?(Hash)
          raise CustodyError.new("custody_mismatch", "history-root.json schema or fields are invalid")
        end
        true
      end

      def validate_grant_index!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == GRANT_INDEX_SCHEMA && doc["schema_version"] == 1 &&
               doc["buckets"].is_a?(Hash) &&
               doc["buckets"].all? { |k, v| k.is_a?(String) && k.match?(/\A[0-9a-f]{2}\z/) && v.is_a?(String) && v.match?(SHA256_RE) }
          raise CustodyError.new("custody_mismatch", "grant-index.json schema or bucket digests are invalid")
        end
        true
      end

      def validate_archive_label!(label)
        value = label.to_s
        if value.empty? || value.include?("/") || value.include?("\\") || value == "." || value == ".." ||
           value.match?(/[\0\r\n]/)
          raise CustodyError.new("custody_mismatch", "archive label #{label.inspect} is invalid")
        end
        value
      end

      def validate_manifest_filename!(name)
        value = name.to_s
        unless value.match?(/\A[A-Za-z0-9._-]+\.json\z/) && !value.include?("..")
          raise CustodyError.new("custody_mismatch", "manifest filename #{name.inspect} is invalid")
        end
        value
      end
    end
  end
end
