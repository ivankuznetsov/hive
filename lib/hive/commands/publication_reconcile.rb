require "json"
require "hive/config"
require "hive/lock"
require "hive/task_resolver"
require "hive/stages/open_pr"

module Hive
  module Commands
    # Explicit local-record repair only: never pushes, edits a PR, or clears a
    # failure marker. Ordinary retry owns subsequent workflow advancement.
    class PublicationReconcile
      def initialize(target, project: nil, pr:, head:, json: false)
        @target, @project, @pr, @head, @json = target, project, pr, head, json
      end

      def call
        task = Hive::TaskResolver.new(@target, project_filter: @project).resolve
        cfg = Hive::Config.load(task.project_root)
        result = Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "publication.reconcile") do
          unless File.file?(File.join(task.folder, "github-publication.json"))
            raise Hive::UsageError, "task has no coding publication record to reconcile"
          end
          git = Hive::Stages::OpenPr.default_git_gateway(cfg)
          controller = Hive::GithubPublication::Controller.new(
            state_path: File.join(task.folder, "github-publication.json"),
            git_gateway: git, github_gateway: Hive::GithubPublication::GithubGateway.new(cfg: cfg)
          )
          read_request = lambda do
            pointer = Hive::Worktree.read_owned_pointer(
              task.folder, project_root: task.project_root, slug: task.slug,
              expected_root: Hive::Worktree.canonical_root(task.project_root, config: cfg)
            )
            if !pointer["base_oid"] && (base = controller.creation_base_oid)
              pointer = pointer.merge("base_oid" => base)
            end
            authoring = Hive::Stages::OpenPr.read_authoring(File.join(task.folder, "pr-draft.json"))
            Hive::Stages::OpenPr.publication_request(task, cfg, pointer, authoring, git_gateway: git)
          end
          request = read_request.call
          controller.reconcile_inspected!(
            request, pr_url: @pr, inspected_head: @head,
            revalidate: ->(_) { read_request.call.to_h == request.to_h }
          )
        end
        @json ? puts(JSON.generate(result)) : puts("#{task.slug}: reconciled #{result.fetch('url')} at #{result.fetch('head_oid')}")
      end
    end
  end
end
