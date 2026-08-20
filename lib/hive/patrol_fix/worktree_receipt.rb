require "digest"
require "json"
require "hive/agent_git_gate"
require "hive/atomic_file"
require "hive/worktree"

module Hive
  module PatrolFix
    class WorktreeReceipt
      FILENAME = "patrol-fix-worktree.json".freeze
      MAX_RECEIPT_BYTES = 32 * 1024
      MAX_DIFF_BYTES = 2 * 1024 * 1024
      DIGEST = /\A[0-9a-f]{64}\z/
      OID = /\A[0-9a-f]{40}\z/
      class InvalidWorktree < Hive::Error; end

      def initialize(task_folder:, project_root:, slug:, worktree_root: nil)
        @task_folder = File.expand_path(task_folder)
        @project_root = File.expand_path(project_root)
        @slug = slug.to_s
        @worktree_root = worktree_root && File.expand_path(worktree_root)
        @path = File.join(@task_folder, FILENAME)
      end

      def prepare!(generation:, evidence_digest:, base_revision:)
        expected = identity(generation, evidence_digest, base_revision)
        if File.exist?(@path) || File.symlink?(@path)
          current = read
          invalid!("worktree ownership conflicts with the current generation") unless current == expected
          validate!(current)
          return current
        end
        worktree(expected).create_exact!(expected.fetch("branch"), base_sha: base_revision)
        validate!(expected)
        Hive::AtomicFile.write(@path, Hive::PatrolFix.canonical_json(expected), mode: 0o600)
        expected.freeze
      rescue Hive::WorktreeError, Hive::AgentGitGate::Error => e
        invalid!(e.message)
      end

      def capture!(generation:, evidence_digest:)
        owner = read
        invalid!("worktree generation changed") unless owner["generation"] == generation
        invalid!("worktree evidence revision changed") unless owner["evidence_digest"] == evidence_digest
        validate!(owner)
        head = read_git!(owner.fetch("worktree"), :head_oid).strip
        invalid!("fix worktree has no committed change") if head == owner.fetch("base_revision")
        invalid!("fix worktree is dirty; preserving it for recovery") unless read_git!(owner.fetch("worktree"), :status).empty?
        diff = Hive::AgentGitGate.read(
          owner.fetch("worktree"), :diff,
          base_oid: owner.fetch("base_revision"), head_oid: head,
          max_stdout_bytes: MAX_DIFF_BYTES
        )
        invalid!("fix diff is unavailable or exceeds #{MAX_DIFF_BYTES} bytes") unless diff.success? && !diff.overflow
        {
          "worktree_generation" => generation, "worktree" => owner.fetch("worktree"),
          "branch" => owner.fetch("branch"), "base_revision" => owner.fetch("base_revision"),
          "head_revision" => head, "diff_digest" => Digest::SHA256.hexdigest(diff.stdout)
        }
      rescue Hive::AgentGitGate::Error => e
        invalid!(e.message)
      end

      def read
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        bytes = File.open(@path, flags) do |file|
          stat = file.stat
          invalid!("worktree ownership must be a regular file") unless stat.file? && stat.nlink == 1
          invalid!("worktree ownership exceeds its size limit") if stat.size > MAX_RECEIPT_BYTES
          file.read(MAX_RECEIPT_BYTES + 1).to_s
        end
        invalid!("worktree ownership exceeds its size limit") if bytes.bytesize > MAX_RECEIPT_BYTES
        document = JSON.parse(bytes)
        keys = %w[schema schema_version slug generation evidence_digest base_revision branch worktree]
        invalid!("worktree ownership has an invalid field set") unless document.is_a?(Hash) && document.keys.sort == keys.sort
        invalid!("worktree ownership schema is invalid") unless document["schema"] == "hive-patrol-fix-worktree" && document["schema_version"] == 1
        invalid!("worktree ownership slug is invalid") unless document["slug"] == @slug
        invalid!("worktree ownership generation is invalid") unless document["generation"].is_a?(Integer) && document["generation"].positive?
        invalid!("worktree ownership digest is invalid") unless document["evidence_digest"].to_s.match?(DIGEST)
        invalid!("worktree ownership base is invalid") unless document["base_revision"].to_s.match?(OID)
        invalid!("worktree ownership branch is invalid") unless
          document["branch"].is_a?(String) && document["branch"].bytesize.between?(1, 512) &&
          !document["branch"].match?(/[\u0000-\u001f\u007f]/)
        invalid!("worktree ownership path is invalid") unless
          document["worktree"].is_a?(String) && document["worktree"].bytesize.between?(1, 4_096) &&
          !document["worktree"].match?(/[\u0000-\u001f\u007f]/)
        document.freeze
      rescue Errno::ENOENT then invalid!("worktree ownership is missing")
      rescue Errno::ELOOP then invalid!("worktree ownership must not be a symlink")
      rescue JSON::ParserError => e then invalid!("worktree ownership is malformed: #{e.message}")
      rescue SystemCallError, IOError => e then invalid!("worktree ownership is unreadable: #{e.message}")
      end

      def validate!(owner)
        expected_path = worktree(owner).path
        invalid!("worktree path is not controller-owned") unless owner.fetch("worktree") == expected_path
        wt = worktree(owner)
        invalid!("worktree is missing or unregistered") unless wt.exists?
        branch = read_git!(expected_path, :current_branch).strip
        invalid!("worktree branch is foreign") unless branch == owner.fetch("branch")
        head = read_git!(expected_path, :head_oid).strip
        ancestry = Hive::AgentGitGate.read(expected_path, :ancestor, base_oid: owner.fetch("base_revision"), head_oid: head)
        invalid!("worktree no longer descends from its controller base") unless ancestry.success?
        true
      end

      private

      def identity(generation, digest, base)
        invalid!("generation is invalid") unless generation.is_a?(Integer) && generation.positive?
        invalid!("evidence digest is invalid") unless digest.to_s.match?(DIGEST)
        invalid!("base revision is invalid") unless base.to_s.match?(OID)
        stem = "#{@slug}-patrol-fix-g#{generation}"
        wt = Hive::Worktree.new(@project_root, stem, worktree_root: @worktree_root)
        { "schema" => "hive-patrol-fix-worktree", "schema_version" => 1,
          "slug" => @slug, "generation" => generation, "evidence_digest" => digest,
          "base_revision" => base, "branch" => "hive/patrol-fix/#{@slug}/g#{generation}",
          "worktree" => wt.path }.freeze
      end

      def worktree(owner)
        Hive::Worktree.new(
          @project_root, File.basename(owner.fetch("worktree")), worktree_root: File.dirname(owner.fetch("worktree"))
        )
      end

      def read_git!(path, operation)
        result = Hive::AgentGitGate.read(path, operation)
        invalid!("hardened Git #{operation} failed") unless result.success?
        result.stdout
      end

      def invalid!(message) = raise(InvalidWorktree, message.to_s[0, 512])
    end
  end
end
