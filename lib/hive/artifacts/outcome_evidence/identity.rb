require "digest"
require "pathname"
require "hive/draft_pr_receipt"
require "hive/artifacts/outcome_evidence/document"
require "hive/managed_git"
require "hive/worktree"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Resolves the only implementation identity accepted by outcome evidence.
      # Agent prose and the legacy visual-capture receipt never participate.
      class Identity
        OID = /\A[0-9a-f]{40,64}\z/i
        SAFE_PATH_BYTES = 4 * 1024

        def initialize(task:, project:, worktree_root: nil)
          @task = task
          @project = project.to_s
          @worktree_root = worktree_root || Hive::Worktree.canonical_root(task.project_root)
        end

        def resolve
          pointer = Hive::Worktree.read_owned_pointer(
            @task.folder,
            project_root: @task.project_root,
            slug: @task.slug,
            expected_root: @worktree_root
          )
          handoff = read_handoff(pointer)
          worktree = pointer.fetch("path")
          ensure_clean!(worktree)

          head = oid!(git(worktree, "rev-parse", "HEAD").strip, "implementation head")
          base = controller_base(pointer, handoff)
          verify_controller_head!(head, handoff)
          git(worktree, "rev-parse", "--verify", "#{base}^{commit}")
          ancestor!(worktree, base, head)
          merge_base = oid!(git(worktree, "merge-base", base, head).strip, "merge base")
          unless merge_base == base
            raise ResolutionError, "controller base is not the implementation merge base"
          end

          paths = changed_paths(worktree, base, head)
          if paths.empty?
            raise ResolutionError,
                  "controller implementation range is empty; a same-head value cannot establish evidence"
          end
          paths.each { |path| self.class.validate_changed_path!(path) }

          repository = controller_value(pointer, handoff, "repository")
          branch = controller_value(pointer, handoff, "branch", "task_branch") || pointer.fetch("branch")
          {
            "repository" => repository,
            "project" => @project,
            "branch" => branch,
            "implementation_base" => base,
            "merge_base" => merge_base,
            "implementation_head" => head,
            "changed_paths" => paths,
            "changed_paths_digest" => Digest::SHA256.hexdigest(paths.join("\0"))
          }
        rescue Hive::WorktreeError => e
          raise ResolutionError, e.message
        end

        def self.validate_changed_path!(path)
          text = path.to_s
          pathname = Pathname.new(text)
          invalid = text.empty? || text.bytesize > SAFE_PATH_BYTES || text.include?("\0") ||
                    pathname.absolute? || pathname.cleanpath.to_s != text ||
                    pathname.each_filename.any? { |part| part == "." || part == ".." }
          raise ResolutionError, "unsafe implementation path #{text.inspect}" if invalid

          text
        end

        private

        def read_handoff(pointer)
          path = Hive::DraftPrReceipt.path(@task.folder)
          return nil unless File.exist?(path) || File.symlink?(path)

          identity = {
            "version" => Hive::DraftPrReceipt::VERSION,
            "phase" => "worktree_created",
            "repository" => pointer["repository"],
            "base_branch" => pointer["base_branch"],
            "base_oid" => pointer["base_oid"],
            "task_branch" => pointer["branch"],
            "worktree_path" => pointer["path"]
          }
          if identity.values_at("repository", "base_branch", "base_oid").any? { |value| value.to_s.empty? }
            return Hive::DraftPrReceipt.read(
              @task.folder, worktree_root: @worktree_root
            )
          end

          Hive::DraftPrReceipt.read(
            @task.folder, expected_identity: identity, worktree_root: @worktree_root
          )
        end

        def controller_base(pointer, handoff)
          values = [ pointer["base_oid"], handoff&.fetch("base_oid", nil) ]
                   .compact.map { |value| oid!(value, "controller base") }.uniq
          raise ResolutionError, "controller implementation base is missing" if values.empty?
          raise ResolutionError, "controller implementation base contradicts saved PR identity" if values.length > 1

          values.first
        end

        def controller_value(pointer, handoff, pointer_key, handoff_key = pointer_key)
          values = [ pointer[pointer_key], handoff&.fetch(handoff_key, nil) ]
                   .compact.map(&:to_s).reject(&:empty?).uniq
          if values.length > 1
            raise ResolutionError, "controller #{pointer_key} contradicts saved PR identity"
          end

          values.first
        end

        def verify_controller_head!(actual, handoff)
          expected = handoff && handoff["head_oid"]
          return unless expected
          return if oid!(expected, "saved PR head") == actual

          raise ResolutionError, "worktree head contradicts saved PR head"
        end

        def ensure_clean!(worktree)
          status = git(
            worktree, "status", "--porcelain=v1", "-z",
            "--untracked-files=all", "--ignore-submodules=none"
          )
          raise ResolutionError, "implementation worktree must be clean" unless status.empty?
        end

        def ancestor!(worktree, base, head)
          git(worktree, "merge-base", "--is-ancestor", base, head)
        rescue ResolutionError
          raise ResolutionError, "controller base is not an ancestor of implementation head"
        end

        def changed_paths(worktree, base, head)
          source = git(
            worktree, "diff", "--raw", "--diff-filter=ACDMRTUXB",
            "-z", "#{base}..#{head}", "--"
          )
          fields = source.split("\0", -1)
          fields.pop while fields.last == ""
          paths = []
          until fields.empty?
            header = fields.shift
            match = header.match(
              /\A:(\d{6}) (\d{6}) [0-9a-f]+ [0-9a-f]+ ([A-Z])\d*\z/
            )
            raise ResolutionError, "outcome-evidence Git returned malformed raw diff" unless match

            count = %w[C R].include?(match[3]) ? 2 : 1
            entry_paths = fields.shift(count)
            if entry_paths.length != count || entry_paths.any?(&:nil?)
              raise ResolutionError, "outcome-evidence Git returned truncated raw diff"
            end
            if match[2] == "120000"
              raise ResolutionError,
                    "implementation path #{entry_paths.last.inspect} is a symlink"
            end
            paths << entry_paths.last
          end
          paths.uniq.sort
        end

        def oid!(value, label)
          oid = value.to_s.downcase
          raise ResolutionError, "#{label} is invalid" unless oid.match?(OID)

          oid
        end

        def git(worktree, *args)
          out, err, status = Hive::ManagedGit.capture3(worktree, *args)
          return out if status.success?

          diagnostic = err.to_s.strip
          diagnostic = out.to_s.strip if diagnostic.empty?
          raise ResolutionError, "outcome-evidence Git failed: #{diagnostic}"
        end
      end
    end
  end
end
