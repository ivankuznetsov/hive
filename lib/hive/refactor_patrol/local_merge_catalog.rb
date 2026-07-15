require "hive/git_ops"

module Hive
  module RefactorPatrol
    # Reconstructs PR-attributed first-parent commits from local history. Only
    # explicit squash/merge subject forms are accepted; ambiguous commits stay
    # diagnostic rather than being guessed or looked up over the network.
    class LocalMergeCatalog
      Result = Struct.new(:merges, :diagnostics, keyword_init: true)

      class CatalogError < Hive::GitError
        attr_reader :reason, :evidence

        def initialize(reason, message, evidence: {})
          super(message)
          @reason = reason
          @evidence = evidence
        end
      end

      def initialize(project_root, git: nil)
        @project_root = File.expand_path(project_root)
        @git = git || Hive::GitOps.new(@project_root)
      end

      def discover(checkpoint_sha:, head_sha:)
        checkpoint = @git.rev_parse(checkpoint_sha)
        head = @git.rev_parse(head_sha)
        unless @git.ancestor?(checkpoint, head)
          raise CatalogError.new("checkpoint_unreachable", "post-merge checkpoint is not an ancestor of the pinned trunk",
                                 evidence: { "checkpoint" => checkpoint, "head" => head })
        end

        merges = []
        diagnostics = []
        @git.first_parent_commits(checkpoint, head).each do |commit|
          pr_number = parse_pr_number(commit.fetch("subject"))
          unless pr_number
            diagnostics << {
              "reason" => "unattributed_first_parent_commit",
              "sha" => commit.fetch("sha"),
              "subject" => commit.fetch("subject")
            }
            next
          end

          base = commit.fetch("parents").first
          unless base
            diagnostics << { "reason" => "merge_without_first_parent", "sha" => commit.fetch("sha") }
            next
          end
          merges << {
            "pr_number" => pr_number,
            "merge_sha" => commit.fetch("sha"),
            "base_sha" => base,
            "subject" => commit.fetch("subject"),
            "changed_paths" => @git.changed_paths(base, commit.fetch("sha"))
          }
        end
        Result.new(merges: merges, diagnostics: diagnostics)
      rescue CatalogError
        raise
      rescue Hive::GitError => e
        raise CatalogError.new("checkpoint_unreachable", "local first-parent history cannot be read",
                               evidence: { "error" => e.message })
      end

      private

      def parse_pr_number(subject)
        match = subject.match(/\(#(\d+)\)\s*\z/) || subject.match(/\AMerge pull request #(\d+)\b/)
        match && Integer(match[1])
      end
    end
  end
end
