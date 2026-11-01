require "hive/agent_git_gate"
require "hive/gh"
require "hive/config"
require "hive/worktree"
require "hive/review_publication_recovery"

module Hive
  module Stages
    module Review
      # Publication is independent of optional CI. A receipt proves branch-ref
      # equality; the API cross-check is separately required for completion.
      class Publication
        class Stop < Hive::Error
          attr_reader :reason
          def initialize(reason)
            @reason = reason
            super(reason)
          end
        end
        attr_reader :evidence, :identity

        def initialize(task:, cfg:, ctx:, pr_url:, gh: Hive::Gh, gate: Hive::AgentGitGate)
          @task, @cfg, @ctx, @pr_url, @gh, @gate = task, cfg, ctx, pr_url, gh, gate
          @evidence = { "worktree" => ctx.worktree_path, "publication" => "unknown",
                        "verification" => "pending", "pr_url" => pr_url }
        end

        def publish!(expected_head:, withheld: nil)
          @evidence["local_head"] = expected_head
          if withheld
            pointer = Hive::Worktree.read_owned_pointer(@task.folder, project_root: @task.project_root,
              slug: @task.slug, expected_root: Hive::Worktree.canonical_root(@task.project_root))
            unless File.realpath(pointer.fetch("path")) == File.realpath(@ctx.worktree_path)
              raise Hive::WorktreeError, "review context does not match the owned worktree"
            end
            @evidence["branch"] = pointer.fetch("branch")
            @evidence.merge!("publication" => "unpublished", "failure_reason" => withheld)
            return self
          end
          @identity = resolve_identity!
          @evidence.merge!("branch" => identity[:branch], "pr_number" => identity[:number],
                           "pr_state" => identity[:state], "is_draft" => identity[:is_draft],
                           "remote_head" => identity[:remote_head])
          verify_local!(expected_head)
          classification = Hive::ReviewPublicationRecovery.classify(
            worktree: @ctx.worktree_path, reference_oid: identity[:remote_head], head: expected_head
          )
          @evidence.merge!(classification.reject { |k, _| k == "head_delivered" })
          raise Stop, "pr_reference_unavailable" if classification["classification"] == "unknown"
          raise Hive::AgentGitGate::RemoteConflict, "divergent history" if classification["classification"] == "divergent"
          # Safe gate uses an exact lease; require ahead-only history above so
          # it can never turn operator guidance into a forceful rewrite.
          receipt = @gate.publish_local_branch(
            repository_path: @ctx.worktree_path, branch: identity[:branch],
            expected_remote_oid: identity[:remote_head], expected_local_oid: expected_head
          )
          raise Stop, "publication_receipt_mismatch" unless receipt.after_oid == expected_head
          @evidence.merge!("publication" => "published", "remote_head" => receipt.after_oid,
                           "unpushed_shas" => [], "classification" => "equal", "failure_reason" => nil)
          verify_local!(expected_head)
          confirm!(expected_head)
          self
        rescue Hive::AgentGitGate::RemoteConflict
          @evidence["failure_reason"] = "remote_conflict"
          self
        rescue Hive::AgentGitGate::PublicationFailed
          # This exception also covers unobservable pushes. Only a fresh
          # independent ref observation can establish a rejected publication.
          confirm_absence(expected_head)
          @evidence["failure_reason"] = "publication_failed"
          self
        rescue Stop => e
          @evidence["failure_reason"] = e.reason
          self
        rescue Hive::AgentGitGate::Error, Hive::GhError, Hive::WorktreeError,
               KeyError, SystemCallError, IOError, ArgumentError
          @evidence["failure_reason"] = "publication_identity_unavailable"
          self
        ensure
          @evidence["observed_at"] = Time.now.utc.iso8601
          commands!
        end

        def confirm!(head)
          verify_local!(head)
          current = resolve_identity!
          @evidence["remote_head"] = current[:remote_head]
          @evidence["observed_at"] = Time.now.utc.iso8601
          raise Stop, "pr_head_moved" unless current[:remote_head] == head
          if @identity && current.values_at(:number, :url, :branch) != @identity.values_at(:number, :url, :branch)
            raise Stop, "pr_identity_moved"
          end
          @identity = current
          @evidence["failure_reason"] = nil
          true
        rescue Hive::GhError, Hive::WorktreeError, KeyError, SystemCallError, IOError, ArgumentError
          raise Stop, "pr_confirmation_unavailable"
        end

        private

        def verify_local!(head)
          current = Hive::ReviewPublicationRecovery.git(@ctx.worktree_path, "rev-parse", "HEAD")&.strip
          branch = Hive::ReviewPublicationRecovery.git(@ctx.worktree_path, "symbolic-ref", "--short", "HEAD")&.strip
          raise Stop, "local_head_moved" unless current == head
          raise Stop, "local_branch_moved" if @identity && branch != @identity[:branch]
        end

        def confirm_absence(head)
          target = @gh.origin_push_url(@ctx.worktree_path, cfg: @cfg, managed: true)
          remote_identity = Hive::Gh.repository_identity_from_remote(target)
          pr_identity = Hive::Gh.parse_pull_request_url(@pr_url)
          return unless remote_identity.fetch("host").downcase == pr_identity.fetch("host") &&
                        remote_identity.fetch("repository").downcase == pr_identity.fetch("repository")
          observation = @gate.observe_remote_branch(repository_path: @ctx.worktree_path,
            branch: @identity.fetch(:branch), remote: target)
          return unless observation.oid && observation.oid != head
          data = Hive::ReviewPublicationRecovery.classify(worktree: @ctx.worktree_path,
            reference_oid: observation.oid, head: head)
          @evidence.merge!(data.reject { |k, _| k == "head_delivered" })
          @evidence["remote_head"] = observation.oid
          @evidence["publication"] = "unpublished" if data["classification"] == "ahead"
        rescue Hive::AgentGitGate::Error, Hive::GhError, Hive::WorktreeError, KeyError, SystemCallError, IOError, ArgumentError
          nil
        end

        def commands!
          return unless @identity
          path, branch, head = @ctx.worktree_path, @identity[:branch], @evidence["local_head"]
          if @evidence["failure_reason"] != "remote_conflict" && @evidence["classification"] == "ahead" && head.to_s.match?(Hive::ReviewPublicationRecovery::OID)
            # Immutable source and ordinary (non-force) push, after checking
            # the task branch still names the retained commit.
            @evidence["push_command"] = "cd #{Shellwords.escape(path)} && test \"$(git rev-parse #{Shellwords.escape("refs/heads/#{branch}")})\" = #{Shellwords.escape(head)} && " +
              Shellwords.join([ "git", "push", "origin", "#{head}:refs/heads/#{branch}" ])
          end
          registrations = Hive::Config.registered_projects.select do |entry|
            File.expand_path(entry.fetch("path")) == File.expand_path(@task.project_root)
          end
          if registrations.one?
            target = "#{registrations.first.fetch('name')}:#{@task.slug}"
            @evidence["verification_recipe"] = Hive::ReviewPublicationRecovery.retry_recipe(target: target, worktree: path)
          else
            @evidence["recovery_reason"] = "project_registration_missing_or_ambiguous"
          end
          if @evidence["is_draft"] == true && @evidence["pr_state"] == "OPEN"
            @evidence["ready_command"] = "cd #{Shellwords.escape(path)} && " + Shellwords.join([ "gh", "pr", "ready", @identity[:number].to_s, "--repo", @pr_url.sub(%r{/pull/\d+\z}, "") ])
          end
        rescue Hive::ConfigError, KeyError, SystemCallError, IOError
          @evidence["recovery_reason"] = "project_registration_unavailable"
        end

        def resolve_identity!
          parsed = @gh.parse_pull_request_url(@pr_url)
          raise Hive::GhError, "pr.md contains an invalid pull-request URL" unless parsed

          root = Hive::Worktree.canonical_root(@task.project_root)
          pointer = Hive::Worktree.read_owned_pointer(
            @task.folder,
            project_root: @task.project_root,
            slug: @task.slug,
            expected_root: root
          )
          unless File.realpath(pointer.fetch("path")) == File.realpath(@ctx.worktree_path)
            raise Hive::WorktreeError, "review context does not match the owned worktree"
          end

          @evidence["branch"] = pointer.fetch("branch")
          @evidence["pr_number"] = parsed.fetch("number")
          repository = @gh.repository_identity(@ctx.worktree_path, cfg: @cfg)
          unless parsed.fetch("host") == repository.fetch("host").downcase &&
                 parsed.fetch("repository") == repository.fetch("repository").downcase
            raise Hive::GhError, "pull request is outside the task repository"
          end

          metadata = @gh.pr_metadata(
            parsed.fetch("number"), cfg: @cfg, chdir: @ctx.worktree_path
          )
          @evidence["pr_state"] = metadata.state.to_s.upcase
          @evidence["is_draft"] = metadata.is_draft
          unless metadata.number == parsed.fetch("number") &&
                 @gh.parse_pull_request_url(metadata.url) == parsed &&
                 metadata.state.to_s.upcase == "OPEN" &&
                 metadata.is_cross_repository == false
            raise Hive::GhError, "pull-request identity is stale or unsupported"
          end

          branch = pointer.fetch("branch")
          matches = @gh.lookup_prs_for_branch(
            @ctx.worktree_path, branch, cfg: @cfg
          ).select do |candidate|
            candidate["number"].to_i == parsed.fetch("number") &&
              candidate["state"].to_s.upcase == "OPEN" &&
              candidate["headRefName"].to_s == branch &&
              @gh.parse_pull_request_url(candidate["url"]) == parsed
          end
          raise Hive::GhError, "task branch does not resolve to one open pull request" unless matches.one?

          remote_head = metadata.head_ref_oid.to_s.downcase
          unless remote_head.match?(/\A[0-9a-f]{40,64}\z/)
            raise Hive::GhError, "pull-request head OID is unavailable"
          end

          {
            number: parsed.fetch("number"), url: parsed.fetch("url"),
            branch: branch, remote_head: remote_head, state: metadata.state.to_s.upcase,
            is_draft: metadata.is_draft
          }
        end

        public :resolve_identity!
      end
    end
  end
end
