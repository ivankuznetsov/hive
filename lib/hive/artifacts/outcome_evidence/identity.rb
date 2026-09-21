require "digest"
require "pathname"
require "hive/agent_git_gate"
require "hive/draft_pr_receipt"
require "hive/git_ops"
require "hive/artifacts/outcome_evidence/document"
require "hive/worktree"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Resolves the only implementation identity accepted by outcome evidence.
      # Agent prose and the legacy visual-capture receipt never participate.
      class Identity
        OID = /\A[0-9a-f]{40,64}\z/i
        SAFE_PATH_BYTES = 4 * 1024
        MAX_GIT_OUTPUT_BYTES = 16 * 1024 * 1024

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

          head = oid!(git_read!(worktree, :head_oid).strip, "implementation head")
          base = controller_base(pointer, handoff)
          verify_controller_head!(head, handoff)
          if base
            git_read!(worktree, :commit_oid, oid: base)
            ancestor!(worktree, base, head)
          end
          base = Hive::AgentGitGate.change_base(
            worktree,
            branch: pointer["base_branch"] || Hive::GitOps.new(@task.project_root).default_branch,
            head_oid: head
          ) unless handoff
          merge_base = base

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
        rescue Hive::WorktreeError, Hive::AgentGitGate::Error => e
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
          status = git_read!(worktree, :status)
          raise ResolutionError, "implementation worktree must be clean" unless status.empty?
        end

        def ancestor!(worktree, base, head)
          result = Hive::AgentGitGate.read(
            worktree, :ancestor, base_oid: base, head_oid: head,
            max_stdout_bytes: MAX_GIT_OUTPUT_BYTES
          )
          return if result.success?

          raise ResolutionError, "controller base is not an ancestor of implementation head"
        rescue Hive::AgentGitGate::Error => e
          raise ResolutionError, "outcome-evidence Git failed: #{e.message}"
        end

        def changed_paths(worktree, base, head)
          source = git_read!(
            worktree, :raw_changed_paths, base_oid: base, head_oid: head
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

        def git_read!(worktree, operation, **parameters)
          result = Hive::AgentGitGate.read(
            worktree, operation,
            max_stdout_bytes: MAX_GIT_OUTPUT_BYTES,
            **parameters
          )
          return result.stdout if result.success?

          diagnostic = result.stderr.to_s.strip
          diagnostic = result.stdout.to_s.strip if diagnostic.empty?
          diagnostic = "bounded output exceeded" if result.overflow
          raise ResolutionError, "outcome-evidence Git failed: #{diagnostic}"
        rescue Hive::AgentGitGate::Error => e
          raise ResolutionError, "outcome-evidence Git failed: #{e.message}"
        end
      end
    end
  end
end
