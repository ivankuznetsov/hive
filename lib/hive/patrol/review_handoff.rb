require "fileutils"
require "time"
require "yaml"
require "hive/task_meta"

module Hive
  module Patrol
    class ReviewHandoff
      MAX_SLUG_LENGTH = 64

      def initialize(project_root, cfg:, state:)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
      end

      def enqueue(finding:, patch:, pr_url:, now: Time.now)
        return nil if @cfg.dig("patrol", "review_prs") == false
        return nil if pr_url.to_s.strip.empty?

        slug = unique_slug(finding)
        task_folder = File.join(@project_root, ".hive-state", "stages", "6-review", slug)
        FileUtils.mkdir_p(File.join(task_folder, "reviews"))
        write_meta(task_folder, slug, finding)
        write_task_md(task_folder, slug, finding, patch, pr_url, now)
        write_worktree_pointer(task_folder, patch, now)
        write_pr_md(task_folder, finding, pr_url)
        task_folder
      end

      private

      def write_meta(task_folder, slug, finding)
        Hive::TaskMeta.write(
          task_folder,
          id: nil,
          slug: slug,
          display_name: display_name(finding)
        )
      end

      def write_task_md(task_folder, slug, finding, patch, pr_url, now)
        write_frontmatter_md(
          File.join(task_folder, "task.md"),
          {
            "slug" => slug,
            "started_at" => now.utc.iso8601,
            "source" => "patrol",
            "patrol_finding_id" => finding.id,
            "patrol_fingerprint" => finding.fingerprint,
            "pr_url" => pr_url
          },
          <<~MD
          # #{display_name(finding)}

          Patrol opened this PR from finding `#{finding.id}` and handed it to the standard 6-review flow.

          ## Finding

          #{finding.description}

          ## Recommendation

          #{finding.recommendation}

          ## Patch

          Branch: `#{patch.branch}`
          Fingerprint: `#{finding.fingerprint}`
        MD
        )
      end

      def write_worktree_pointer(task_folder, patch, now)
        data = {
          "path" => patch.worktree_path,
          "branch" => patch.branch,
          "created_at" => now.utc.iso8601
        }
        data["execute_base_head"] = patch.head_sha if patch.respond_to?(:head_sha) && patch.head_sha
        File.write(File.join(task_folder, "worktree.yml"), data.to_yaml)
      end

      def write_pr_md(task_folder, finding, pr_url)
        write_frontmatter_md(
          File.join(task_folder, "pr.md"),
          {
            "pr_url" => pr_url,
            "pr_number" => pr_number(pr_url),
            "source" => "patrol",
            "patrol_finding_id" => finding.id,
            "patrol_fingerprint" => finding.fingerprint
          },
          <<~MD
          ## Summary
          Patrol opened this PR for `#{finding.title || finding.id}`.

          ## Linked task
          #{task_folder}
        MD
        )
      end

      def write_frontmatter_md(path, data, body)
        File.write(path, "#{data.to_yaml}---\n\n#{body}")
      end

      def unique_slug(finding)
        base = base_slug(finding)
        slug = base
        counter = 2
        while File.exist?(File.join(@project_root, ".hive-state", "stages", "6-review", slug))
          suffix = "-#{counter}"
          slug = trim_slug(base, MAX_SLUG_LENGTH - suffix.length) + suffix
          counter += 1
        end
        slug
      end

      def base_slug(finding)
        feature = sanitize_slug_component(finding.feature_id)
        fingerprint = sanitize_slug_component(finding.fingerprint.to_s[0, 8])
        trim_slug([ "patrol", feature, fingerprint ].reject(&:empty?).join("-"), MAX_SLUG_LENGTH)
      end

      def sanitize_slug_component(value)
        value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      end

      def trim_slug(slug, max)
        trimmed = slug[0, max].to_s.gsub(/-+\z/, "")
        trimmed = "patrol-task" if trimmed.empty? || trimmed !~ /\A[a-z]/
        trimmed = "#{trimmed}x" unless trimmed[-1] =~ /[a-z0-9]/
        trimmed
      end

      def display_name(finding)
        "Patrol: #{finding.title || finding.id}"
      end

      def pr_number(pr_url)
        pr_url.to_s[%r{/pull/(\d+)\z}, 1]
      end
    end
  end
end
