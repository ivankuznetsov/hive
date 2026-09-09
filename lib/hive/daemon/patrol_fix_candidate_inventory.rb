require "digest"
require "hive/patrol_fix"
require "hive/patrol_fix/source_snapshot"
require "hive/patrol_fix/task_manifest"
require "hive/secret_patterns"
require "hive/secret_scanner"

module Hive
  module Daemon
    # Read-only, bounded relevance retrieval over the one Patrol Fix-owned
    # task manifest in each workflow task folder. It never opens unrelated
    # task metadata. The returned context is small enough for one semantic
    # decision, while inventory_digest binds every owned canonical manifest.
    class PatrolFixCandidateInventory
      MAX_OWNED_CANDIDATES = 8_192
      MAX_CANDIDATES = 64
      MAX_CANDIDATE_BYTES = 6 * 1024
      MAX_CONTEXT_BYTES = 192 * 1024
      MAX_EVIDENCE = 3
      MAX_EVIDENCE_BYTES = 768
      MAX_AFFECTED_CODE = 12
      MAX_PATH_BYTES = 256
      MAX_REMEDIATION_BYTES = 1_536

      class InvalidInventory < Hive::Error; end

      def initialize(hive_state_path:)
        @hive_state_path = File.expand_path(hive_state_path)
      end

      def call(snapshot)
        source = snapshot.is_a?(Hive::PatrolFix::SourceSnapshot) ?
          snapshot : Hive::PatrolFix::SourceSnapshot.new(snapshot)
        owned = owned_manifests
        entries = owned.map { |path| candidate(path, source) }
        ordered = entries.sort_by do |entry|
          [ -entry.fetch(:relevance), entry.dig(:context, "kind"),
            entry.dig(:context, "identity") ]
        end
        selected = bounded_context(ordered)
        inventory_members = entries.map { |entry| entry.fetch(:inventory_member) }
                                   .sort_by { |entry| [ entry.fetch("kind"), entry.fetch("identity") ] }
        context_digest = Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(selected))
        Hive::PatrolFix.deep_freeze(
          "inventory_count" => inventory_members.length,
          "inventory_digest" => Digest::SHA256.hexdigest(
            Hive::PatrolFix.canonical_json(inventory_members)
          ),
          "context_digest" => context_digest,
          "truncated" => inventory_members.length > selected.length,
          "candidates" => selected
        )
      rescue Hive::PatrolFix::TaskManifest::InvalidManifest => error
        invalid!("owned Patrol Fix manifest is invalid: #{error.message}")
      end

      private

      def owned_manifests
        pattern = File.join(
          @hive_state_path, "stages", "*", "*",
          Hive::PatrolFix::TaskManifest::FILENAME
        )
        paths = Dir.glob(pattern).sort
        invalid!("owned Patrol Fix inventory exceeds #{MAX_OWNED_CANDIDATES} tasks") if
          paths.length > MAX_OWNED_CANDIDATES
        paths
      end

      def candidate(path, source)
        folder = File.dirname(path)
        reject_unsafe_folder!(folder)
        manifest_snapshot = Hive::PatrolFix::TaskManifest.new(task_folder: folder).read_snapshot
        if Hive::SecretScanner.match?(manifest_snapshot.canonical_bytes)
          invalid!("owned Patrol Fix manifest contains secret-like material")
        end
        manifest = manifest_snapshot.document
        context = candidate_context(manifest, manifest_digest: manifest_snapshot.digest)
        canonical_context = Hive::PatrolFix.canonical_json(context)
        invalid!("owned Patrol Fix candidate context exceeds its byte limit") if
          canonical_context.bytesize > MAX_CANDIDATE_BYTES
        {
          context: context,
          relevance: relevance(context, manifest, source),
          inventory_member: context.slice(
            "kind", "identity", "evidence_digest", "target_revision",
            "manifest_digest", "context_digest"
          )
        }
      end

      def bounded_context(ordered)
        selected = []
        ordered.first(MAX_CANDIDATES).each do |entry|
          trial = selected + [ entry.fetch(:context) ]
          break if Hive::PatrolFix.canonical_json(trial).bytesize > MAX_CONTEXT_BYTES

          selected = trial
        end
        selected.sort_by { |entry| [ entry.fetch("kind"), entry.fetch("identity") ] }
      end

      def reject_unsafe_folder!(folder)
        stage = File.dirname(folder)
        invalid!("owned Patrol Fix task folder must be a real directory") unless
          File.directory?(folder) && !File.symlink?(folder) &&
          File.directory?(stage) && !File.symlink?(stage)
      rescue SystemCallError => error
        invalid!("owned Patrol Fix task folder is unreadable: #{error.message}")
      end

      def candidate_context(manifest, manifest_digest:)
        sources = manifest.fetch("sources")
        evidence = sources.flat_map { |item| item.fetch("evidence") }
                          .uniq.first(MAX_EVIDENCE)
                          .map { |value| bounded_text(value, MAX_EVIDENCE_BYTES) }
        affected_code = sources.flat_map { |item| item.fetch("affected_code") }
                               .uniq.first(MAX_AFFECTED_CODE)
                               .map { |value| bounded_text(value, MAX_PATH_BYTES) }
        remediation = sources.map { |item| item.fetch("reproduction_guidance") }
                             .find { |value| !value.empty? }.to_s
        core = {
          "kind" => "task",
          "identity" => manifest.dig("task", "slug"),
          "evidence_digest" => manifest.dig("evidence_revision", "digest"),
          "target_revision" => manifest.fetch("target_revision"),
          "manifest_digest" => manifest_digest,
          "evidence" => evidence,
          "affected_code" => affected_code,
          "remediation" => bounded_text(remediation, MAX_REMEDIATION_BYTES)
        }
        core.merge(
          "context_digest" => Digest::SHA256.hexdigest(Hive::PatrolFix.canonical_json(core))
        )
      end

      def relevance(candidate, manifest, source)
        source_doc = source.to_h
        source_identity = source_doc.fetch("identity")
        exact_aliases = manifest.fetch("sources").map { |entry| entry.fetch("identity") } +
          manifest.fetch("aliases").map { |entry| entry.fetch("value") }
        identity_score = exact_aliases.include?(source_identity) ? 10_000 : 0
        source_lineage = source_doc.fetch("semantic_lineage")
        candidate_lineage = manifest.fetch("sources").flat_map do |entry|
          entry.fetch("semantic_lineage")
        end
        lineage_score = (source_lineage & candidate_lineage).length * 1_000
        source_paths = source_doc.fetch("affected_code")
        candidate_paths = candidate.fetch("affected_code")
        path_score = source_paths.product(candidate_paths).sum do |left, right|
          if left == right
            100
          elsif left.start_with?("#{right}/") || right.start_with?("#{left}/")
            40
          else
            0
          end
        end
        source_tokens = tokens([
          source_doc.fetch("title"), source_doc.fetch("summary"),
          *source_doc.fetch("evidence"), source_doc.fetch("reproduction_guidance")
        ])
        candidate_tokens = tokens([
          *candidate.fetch("evidence"), candidate.fetch("remediation"),
          *candidate.fetch("affected_code")
        ])
        identity_score + lineage_score + path_score + (source_tokens & candidate_tokens).length
      end

      def tokens(values)
        values.join(" ").downcase.scan(/[a-z0-9_]{3,}/).uniq.first(512)
      end

      def bounded_text(value, max_bytes)
        text = Hive::SecretPatterns.redact(value.to_s)
        return text if text.bytesize <= max_bytes

        bytes = 0
        text.each_char.take_while do |character|
          next_bytes = bytes + character.bytesize
          next false if next_bytes > max_bytes

          bytes = next_bytes
          true
        end.join
      end

      def invalid!(message)
        raise InvalidInventory, Hive::SecretPatterns.redact(message.to_s)[0, 512]
      end
    end
  end
end
