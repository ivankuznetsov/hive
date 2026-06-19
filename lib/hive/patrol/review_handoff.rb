require "fileutils"
require "time"
require "yaml"
require "hive/pr"
require "hive/task_counter"
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
        write_idea_md(task_folder, slug, finding, now)
        write_task_md(task_folder, slug, finding, patch, pr_url, now)
        write_worktree_pointer(task_folder, patch, now)
        write_pr_md(task_folder, finding, pr_url)
        task_folder
      end

      private

      def write_meta(task_folder, slug, finding)
        Hive::TaskMeta.write(
          task_folder,
          id: allocate_task_id,
          slug: slug,
          display_name: display_name(finding)
        )
      end

      def allocate_task_id
        Hive::TaskCounter.next!
      rescue Hive::ConcurrentRunError
        nil
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

      def write_idea_md(task_folder, slug, finding, now)
        # The TUI reads `original_text` from frontmatter; the body is the
        # human-facing copy. They are deliberately identical, so compute
        # the text once and interpolate into both positions.
        text = idea_text(finding)
        write_frontmatter_md(
          File.join(task_folder, "idea.md"),
          {
            "slug" => slug,
            "created_at" => now.utc.iso8601,
            "source" => "patrol",
            "patrol_finding_id" => finding.id,
            "patrol_fingerprint" => finding.fingerprint,
            "original_text" => text
          },
          <<~MD
          #{text}
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
        while slug_taken?(slug)
          suffix = "-#{counter}"
          slug = trim_slug(base, MAX_SLUG_LENGTH - suffix.length) + suffix
          counter += 1
        end
        slug
      end

      # A slug must be unique across ALL stage dirs, not just 6-review: a
      # synthetic task that has already advanced (e.g. to 7-artifacts /
      # 9-done) or a re-handed-off finding would otherwise reuse the slug
      # and collide on the slug-derived worktree and log-dir paths.
      def slug_taken?(slug)
        !Dir.glob(File.join(@project_root, ".hive-state", "stages", "*", slug)).empty?
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

      def idea_text(finding)
        parts = []
        parts << "# #{display_name(finding)}"
        parts << "## Finding\n\n#{finding.description}" unless finding.description.to_s.strip.empty?
        parts << "## Recommendation\n\n#{finding.recommendation}" unless finding.recommendation.to_s.strip.empty?
        evidence = Array(finding.evidence)
        parts << "## Evidence\n\n#{evidence_text(evidence)}" unless evidence.empty?
        parts.join("\n\n")
      end

      def evidence_text(evidence)
        Array(evidence).map do |entry|
          entry = {} unless entry.is_a?(Hash)
          location = [ entry["file"], entry["line"] ].compact.join(":")
          snippet = entry["snippet"].to_s.strip
          line = location.empty? ? "- evidence" : "- `#{location}`"
          snippet.empty? ? line : "#{line}: #{snippet}"
        end.join("\n")
      end

      # Delegate to the canonical parser (stripping the `#` it prefixes) so
      # the `pr_number` written into pr.md frontmatter can't drift from the
      # `#NNN` every display surface shows. The old end-anchored regex here
      # disagreed with Hive::Pr.number on trailing-slash/query URLs.
      def pr_number(pr_url)
        Hive::Pr.number(pr_url)&.delete_prefix("#")
      end
    end
  end
end
