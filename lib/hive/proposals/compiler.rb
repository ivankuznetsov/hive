require "fileutils"
require "tmpdir"
require "hive/atomic_file"
require "hive/proposals/store"

module Hive
  module Proposals
    Compilation = Data.define(
      :index, :markdown, :source_commit, :projection_count, :diagnostic_count, :paths
    )

    class Compiler
      INDEX_SCHEMA = "hive-proposal-index".freeze
      JSON_PATH = "wiki/proposals.json".freeze
      MARKDOWN_PATH = "wiki/proposals.md".freeze
      PINNED_PREFIXES = %w[proposals/v1/records/ proposals/v1/events/].freeze

      def self.compile_at_ref(git_ops:, source_ref:, output_root:)
        PinnedSource.new(git_ops:, source_ref:).with_store do |store, source_commit|
          new(store:).compile(output_root:, source_commit:)
        end
      end

      def initialize(store:)
        @store = store
      end

      def compile(output_root:, source_commit: nil)
        source_commit = normalized_source_commit(source_commit)
        snapshot = @store.load
        proposals = snapshot.projections.map(&:to_h)
        diagnostics = snapshot.diagnostics.map(&:to_h)
        projection_digest = Proposals.digest(
          "proposals" => proposals, "diagnostics" => diagnostics
        )
        index = {
          "schema" => INDEX_SCHEMA, "schema_version" => 1,
          "source_commit" => source_commit, "proposals" => proposals,
          "diagnostics" => diagnostics, "projection_digest" => projection_digest
        }
        index["index_digest"] = Proposals.digest(index)
        json = Proposals.canonical(index)
        markdown = render_markdown(index)
        paths = write_pair(output_root, json:, markdown:)
        Compilation.new(
          index:, markdown:, source_commit:, projection_count: proposals.length,
          diagnostic_count: diagnostics.length, paths:
        )
      end

      private

      def normalized_source_commit(value)
        return nil if value.nil?

        Proposals.digest!(value, label: "proposal compiler source commit", git: true)
      end

      def write_pair(output_root, json:, markdown:)
        root = File.expand_path(output_root)
        paths = [ File.join(root, JSON_PATH), File.join(root, MARKDOWN_PATH) ]
        paths.each do |path|
          unless path.start_with?("#{root}/")
            raise Error, "proposal compiler output escapes its root"
          end
          FileUtils.mkdir_p(File.dirname(path), mode: 0o755)
        end
        Hive::AtomicFile.write(paths.first, json, mode: 0o644)
        Hive::AtomicFile.write(paths.last, markdown, mode: 0o644)
        paths.freeze
      end

      def render_markdown(index)
        terminal = index.fetch("proposals").reject { |proposal| proposal["status"] == "draft" }
        lines = [
          "# Proposal History", "",
          "Pinned state: #{markdown(index["source_commit"] || "unpublished bootstrap")}",
          "Projection digest: #{markdown(index.fetch("projection_digest"))}", ""
        ]
        if terminal.empty?
          lines << "No terminal proposals have been recorded."
        else
          terminal.each { |proposal| render_proposal(lines, proposal) }
        end
        unless index.fetch("diagnostics").empty?
          lines.concat([ "", "## Quarantine diagnostics", "" ])
          index.fetch("diagnostics").each do |diagnostic|
            lines << "- #{markdown(diagnostic.fetch('code'))}: " \
                     "#{markdown(diagnostic.fetch('path'))} " \
                     "(sha256 #{markdown(diagnostic.fetch('sha256'))}, " \
                     "#{diagnostic.fetch('bytes')} bytes)"
          end
        end
        "#{lines.join("\n")}\n"
      end

      def render_proposal(lines, proposal)
        subject = proposal.fetch("subject")
        lines.concat(
          [
            "", "## #{status_label(proposal.fetch('status'))}", "",
            "- Proposal: #{markdown(proposal.fetch('proposal_id'))}",
            "- Subject: #{markdown(subject.fetch('kind'))} #{markdown(subject.fetch('reference'))}",
            "- Revision: #{markdown(proposal.fetch('revision'))}",
            "- Change: #{markdown(proposal.fetch('proposed_change'))}",
            "- Motivation: #{markdown(proposal.fetch('motivation'))}",
            "- Projection digest: #{markdown(proposal.fetch('projection_digest'))}",
            "- Retention: #{markdown(proposal.dig('retention', 'policies').join(', '))}; enforcement none"
          ]
        )
        render_evidence(lines, proposal.fetch("evidence"))
        render_evaluations(lines, proposal.fetch("evaluations"))
        render_decision(lines, proposal["decision"])
        render_lineage(lines, proposal.fetch("lineage"))
        render_rollback(lines, proposal["rollback"])
      end

      def render_evidence(lines, evidence)
        return if evidence.empty?

        lines.concat([ "", "### Candidate evidence", "" ])
        evidence.each do |item|
          summary = item["summary"] ? ": #{markdown(item['summary'])}" : ""
          lines << "- #{markdown(item.fetch('label'))} (#{markdown(item.fetch('visibility'))}, " \
                   "sha256 #{markdown(item.fetch('digest'))})#{summary}"
        end
      end

      def render_evaluations(lines, evaluations)
        return if evaluations.empty?

        lines.concat([ "", "### Evaluations", "" ])
        evaluations.each do |evaluation|
          metrics = Proposals.canonical(evaluation.dig("result", "metrics"))
          lines << "- #{markdown(evaluation.fetch('occurred_at'))}: " \
                   "#{markdown(evaluation.dig('evaluator', 'id'))} via " \
                   "#{markdown(evaluation.dig('method', 'label'))} — " \
                   "#{markdown(evaluation.dig('result', 'outcome'))}; metrics #{markdown(metrics)}"
          lines << "  Rationale: #{markdown(evaluation.fetch('rationale'))}"
        end
      end

      def render_decision(lines, decision)
        return unless decision

        lines.concat(
          [
            "", "### Authoritative decision", "",
            "- Outcome: #{markdown(decision.fetch('outcome'))}",
            "- Authority: #{markdown(decision.dig('authority', 'id'))} " \
            "(#{markdown(decision.dig('authority', 'kind'))})",
            "- Rationale category: #{markdown(decision.fetch('rationale_category'))}",
            "- Rationale: #{markdown(decision.fetch('rationale'))}",
            "- Considered evaluations: " \
            "#{markdown(decision.fetch('considered_evaluation_ids').join(', '))}"
          ]
        )
      end

      def render_lineage(lines, lineage)
        facts = {
          "Retries" => lineage["retries"],
          "Requested predecessor" => lineage["requested_supersedes"],
          "Supersedes" => Array(lineage["supersedes"]).join(", "),
          "Superseded by" => lineage["superseded_by"]
        }.reject { |_label, value| value.nil? || value.empty? }
        return if facts.empty?

        lines.concat([ "", "### Lineage", "" ])
        facts.each { |label, value| lines << "- #{label}: #{markdown(value)}" }
      end

      def render_rollback(lines, rollback)
        return unless rollback

        lines.concat(
          [
            "", "### Rollback evidence", "",
            "- Reverted revision: #{markdown(rollback.fetch('reverted_revision'))}",
            "- Reason: #{markdown(rollback.fetch('reason'))}",
            "- External revert: #{markdown(rollback.dig('external_revert', 'kind'))} " \
            "#{markdown(rollback.dig('external_revert', 'reference'))}"
          ]
        )
      end

      def status_label(status)
        {
          "accepted" => "Accepted", "rejected" => "Rejected",
          "superseded" => "Superseded", "rolled_back" => "Rolled back"
        }.fetch(status)
      end

      def markdown(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
             .gsub(/[\\`*_{\[\]()#+.!|~-]/) { |character| "\\#{character}" }
             .gsub(/\s+/, " ").strip
      end

      class PinnedSource
        MAX_TREE_PATHS = 20_000
        MAX_BLOB_BYTES = Store::MAX_FILE_BYTES + 1

        def initialize(git_ops:, source_ref:)
          @git_ops = git_ops
          @source_ref = source_ref.to_s
        end

        def with_store
          source_commit = resolve_commit
          Dir.mktmpdir("hive-proposal-pinned-") do |directory|
            root = File.join(directory, "proposals", "v1")
            materialize(root, source_commit)
            yield Store.new(root:), source_commit
          end
        end

        private

        def resolve_commit
          commit = @git_ops.run_git!(
            "-C", @git_ops.hive_state_path, "rev-parse", "--verify",
            "#{@source_ref}^{commit}"
          ).strip
          Proposals.digest!(commit, label: "proposal compiler pinned commit", git: true)
        rescue Hive::GitError
          raise Error, "proposal compiler source ref is unavailable"
        end

        def materialize(root, source_commit)
          output = @git_ops.run_git!(
            "-C", @git_ops.hive_state_path, "ls-tree", "-rz", "--full-tree",
            source_commit, "--", "proposals/v1/records", "proposals/v1/events"
          )
          entries = output.split("\0").reject(&:empty?)
          raise QuotaExceeded, "proposal pinned tree has too many paths" if entries.length > MAX_TREE_PATHS

          entries.each { |entry| materialize_entry(root, source_commit, entry) }
        end

        def materialize_entry(root, source_commit, entry)
          metadata, path = entry.split("\t", 2)
          mode, type, = metadata.to_s.split(" ", 3)
          return unless type == "blob" && safe_tree_path?(path)

          relative = PINNED_PREFIXES.filter_map { |prefix| path.delete_prefix(prefix) if path.start_with?(prefix) }
                                    .first
          prefix = path.start_with?(PINNED_PREFIXES.first) ? "records" : "events"
          destination = File.join(root, prefix, relative)
          FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
          bytes = @git_ops.read_hive_state_blob_at(source_commit, path, max_bytes: MAX_BLOB_BYTES)
          bytes ||= "x" * MAX_BLOB_BYTES
          if mode == "120000"
            File.symlink(bytes.byteslice(0, 2_048), destination)
          else
            Hive::AtomicFile.write(destination, bytes, mode: 0o600)
          end
        end

        def safe_tree_path?(path)
          path && PINNED_PREFIXES.any? { |prefix| path.start_with?(prefix) } &&
            !path.split("/").include?("..")
        end
      end
    end
  end
end
