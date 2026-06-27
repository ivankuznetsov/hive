require "fileutils"
require "time"
require "yaml"
require "hive/config"
require "hive/gh"
require "hive/pr"
require "hive/task_counter"
require "hive/task_meta"
require "hive/workflows"
require "hive/worktree"

module Hive
  module Commands
    class AdhocReview
      class CollisionError < Hive::Error; end

      SOURCE = "ad-hoc".freeze

      def initialize(pr:, project: nil, json: false)
        @pr_identifier = pr
        @project_name = project
        @json = json
      end

      def call
        enqueue.fetch(:slug)
      end

      def enqueue(now: Time.now)
        project = Hive::Config.registered_project!(name: @project_name, cwd: Dir.pwd)
        project_root = project.fetch("path")
        hive_state_path = project.fetch("hive_state_path")
        pr_number = Hive::Pr.identifier_to_number(@pr_identifier)
        metadata = Hive::Gh.pr_metadata(pr_number)
        slug = slug_for(pr_number)

        return reuse(slug, hive_state_path) if reusable_folder?(hive_state_path, slug)

        refuse_if_owned!(hive_state_path, slug, pr_number)

        task_folder = create_task!(hive_state_path, project_root, slug, pr_number, metadata, now)
        { slug: slug, task_folder: task_folder, reused: false }
      rescue Hive::Error
        raise
      rescue ArgumentError => e
        raise Hive::InvalidTaskPath, e.message
      rescue StandardError => e
        raise Hive::InternalError, "internal error: #{e.class}: #{e.message}"
      end

      private

      def reuse(slug, hive_state_path)
        { slug: slug, task_folder: File.join(hive_state_path, "stages", "6-review", slug), reused: true }
      end

      def slug_for(pr_number)
        "adhoc-review-pr-#{pr_number}"
      end

      def reusable_folder?(hive_state_path, slug)
        File.directory?(File.join(hive_state_path, "stages", "6-review", slug))
      end

      def refuse_if_owned!(hive_state_path, slug, pr_number)
        slug_owner = existing_slug_owner(hive_state_path, slug)
        raise_collision!(pr_number, slug_owner) if slug_owner

        pr_owner = existing_pr_owner(hive_state_path, pr_number)
        raise_collision!(pr_number, pr_owner) if pr_owner && pr_owner.fetch(:slug) != slug
      end

      def existing_slug_owner(hive_state_path, slug)
        Dir.glob(File.join(hive_state_path, "stages", "*", slug)).filter_map do |folder|
          stage = File.basename(File.dirname(folder))
          next if stage == "6-review"

          { stage: stage, slug: slug, folder: folder }
        end.first
      end

      def existing_pr_owner(hive_state_path, pr_number)
        Dir.glob(File.join(hive_state_path, "stages", "*", "*", "pr.md")).filter_map do |path|
          frontmatter = Hive::Gh.pr_frontmatter(path)
          next unless frontmatter["pr_number"].to_i == pr_number.to_i

          folder = File.dirname(path)
          { stage: File.basename(File.dirname(folder)), slug: File.basename(folder), folder: folder }
        end.first
      end

      def raise_collision!(pr_number, owner)
        slug = owner.fetch(:slug)
        stage = owner.fetch(:stage)
        raise CollisionError,
              "PR ##{pr_number} is already owned by hive task #{slug} at #{stage}; " \
              "run `hive review #{slug}` to continue it or `hive drop #{slug}` before creating an ad-hoc review"
      end

      def materialize(project_root, slug, pr_number)
        Hive::Worktree.materialize_pr(
          repo_root: project_root,
          pr_number: pr_number,
          path: File.join(Hive::Worktree.canonical_root(project_root), slug),
          branch: "hive/review/pr-#{pr_number}"
        )
      end

      def create_task!(hive_state_path, project_root, slug, pr_number, metadata, now)
        task_folder = File.join(hive_state_path, "stages", "6-review", slug)
        FileUtils.mkdir_p(File.join(task_folder, "reviews"))
        materialized = materialize(project_root, slug, pr_number)
        verify_head!(pr_number, metadata, materialized)
        write_sidecars(task_folder, slug, metadata, materialized, now)
        task_folder
      rescue StandardError
        FileUtils.rm_rf(task_folder) if task_folder
        raise
      end

      def verify_head!(pr_number, metadata, materialized)
        expected = metadata.head_ref_oid.to_s
        actual = materialized.fetch(:head_sha).to_s
        return if expected.empty? || actual == expected

        raise Hive::WorktreeError,
              "PR ##{pr_number} materialized at #{actual}, but GitHub reported head #{expected}"
      end

      def write_sidecars(task_folder, slug, metadata, materialized, now)
        pr_number = metadata.number
        write_meta(task_folder, slug, pr_number)
        write_idea_md(task_folder, slug, pr_number, now)
        write_task_md(task_folder, slug, metadata, now)
        write_worktree_pointer(task_folder, materialized, now)
        write_pr_md(task_folder, metadata)
      end

      def write_meta(task_folder, slug, pr_number)
        Hive::TaskMeta.write(
          task_folder,
          id: Hive::TaskCounter.next!,
          slug: slug,
          display_name: "Ad-hoc review: PR ##{pr_number}",
          workflow: Hive::Workflows::CODING_ID.to_s
        )
      end

      def write_idea_md(task_folder, slug, pr_number, now)
        text = "review PR ##{pr_number}"
        write_frontmatter_md(
          File.join(task_folder, "idea.md"),
          {
            "slug" => slug,
            "created_at" => now.utc.iso8601,
            "source" => SOURCE,
            "original_text" => text
          },
          <<~MD
          #{text}
        MD
        )
      end

      def write_task_md(task_folder, slug, metadata, now)
        write_frontmatter_md(
          File.join(task_folder, "task.md"),
          {
            "slug" => slug,
            "started_at" => now.utc.iso8601,
            "source" => SOURCE,
            "pr_url" => metadata.url
          },
          <<~MD
          # Ad-hoc review: PR ##{metadata.number}

          This task runs the standard 6-review flow against #{metadata.url}.
        MD
        )
      end

      def write_worktree_pointer(task_folder, materialized, now)
        File.write(
          File.join(task_folder, "worktree.yml"),
          {
            "path" => materialized.fetch(:path),
            "branch" => materialized.fetch(:branch),
            "created_at" => now.utc.iso8601,
            "execute_base_head" => materialized.fetch(:head_sha)
          }.to_yaml
        )
      end

      def write_pr_md(task_folder, metadata)
        write_frontmatter_md(
          File.join(task_folder, "pr.md"),
          {
            "pr_url" => metadata.url,
            "pr_number" => metadata.number,
            "source" => SOURCE,
            "base_ref_name" => metadata.base_ref_name,
            "head_ref_oid" => metadata.head_ref_oid,
            "is_cross_repository" => metadata.is_cross_repository,
            "state" => metadata.state
          },
          <<~MD
          ## Summary
          Ad-hoc review for PR ##{metadata.number}.

          ## Base
          #{metadata.base_ref_name}
        MD
        )
      end

      def write_frontmatter_md(path, data, body)
        File.write(path, "#{data.to_yaml}---\n\n#{body}")
      end
    end
  end
end
