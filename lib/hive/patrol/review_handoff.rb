require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"
require "yaml"
require "hive/atomic_file"
require "hive/pr"
require "hive/task_counter"
require "hive/task_meta"
require "hive/workflows"

module Hive
  module Patrol
    class ReviewHandoff
      class Conflict < StandardError; end

      MAX_SLUG_LENGTH = 64
      WORKFLOW = Hive::Workflows::CODING_ID.to_s.freeze
      REQUIRED_FILES = %w[meta.yml idea.md task.md worktree.yml pr.md].freeze
      CONTEXT_FILE = "architecture-thesis.json"

      def initialize(project_root, cfg:, state:, write_hook: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @write_hook = write_hook
      end

      def enqueue(finding:, patch:, pr_url:, now: Time.now, mandatory: false, context: nil)
        return nil if !mandatory && @cfg.dig("patrol", "review_prs") == false
        return nil if pr_url.to_s.strip.empty?

        expected = expected_metadata(finding, patch, pr_url, context, mandatory: mandatory)
        with_fingerprint_lock(expected.fetch("fingerprint")) do |lock_id|
          quarantine_interrupted_staging(lock_id)
          if (existing = reconcile_existing!(expected))
            return existing
          end

          publish_task(finding, patch, pr_url, now, expected, lock_id)
        end
      end

      private

      def expected_metadata(finding, patch, pr_url, context, mandatory:)
        expected = {
          "fingerprint" => finding.fingerprint.to_s.strip,
          "pr_url" => pr_url.to_s.strip,
          "branch" => patch.branch.to_s.strip,
          "worktree_path" => patch.worktree_path.to_s.strip,
          "head_sha" => patch_head(patch).to_s.strip,
          "workflow" => WORKFLOW,
          "context" => normalize_context(context)
        }
        required = %w[fingerprint pr_url branch worktree_path]
        required << "head_sha" if mandatory
        missing = required.select { |key| expected.fetch(key).empty? }
        raise ArgumentError, "patrol review handoff requires #{missing.join(', ')}" unless missing.empty?

        expected
      end

      def normalize_context(context)
        return nil if context.nil?

        JSON.parse(JSON.generate(context))
      rescue JSON::GeneratorError, TypeError => e
        raise ArgumentError, "patrol review context must be JSON serializable: #{e.message}"
      end

      def patch_head(patch)
        patch.head_sha if patch.respond_to?(:head_sha)
      end

      def with_fingerprint_lock(fingerprint)
        FileUtils.mkdir_p(review_root)
        lock_id = ::Digest::SHA256.hexdigest(fingerprint)
        lock_path = File.join(review_root, ".handoff-#{lock_id}.lock")
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield lock_id
        end
      end

      def reconcile_existing!(expected)
        candidates = existing_task_folders.select do |folder|
          folder_fingerprints(folder).include?(expected.fetch("fingerprint"))
        end
        inspections = candidates.map { |folder| [ folder, inspect_existing(folder, expected) ] }
        conflicts = inspections.select { |_folder, inspection| inspection.first == :conflict }
        unless conflicts.empty?
          details = conflicts.map { |folder, inspection| "#{folder} (#{inspection.last})" }.join(", ")
          raise Conflict, "patrol review handoff conflict: #{details}"
        end

        complete = inspections.select { |_folder, inspection| inspection.first == :complete }.map(&:first)
        if complete.length > 1
          raise Conflict, "patrol review handoff conflict: duplicate complete tasks for #{expected.fetch('fingerprint')}"
        end

        inspections.each do |folder, inspection|
          quarantine(folder, inspection.last) if inspection.first == :incomplete
        end
        complete.first
      end

      def inspect_existing(folder, expected)
        missing = REQUIRED_FILES.reject { |name| File.file?(File.join(folder, name)) }
        missing << "reviews/" unless File.directory?(File.join(folder, "reviews"))
        if !expected["context"].nil? && !File.file?(File.join(folder, CONTEXT_FILE))
          missing << CONTEXT_FILE
        end

        actual = read_existing_metadata(folder, include_context: !expected["context"].nil?)
        return [ :incomplete, "missing or malformed metadata" ] unless actual

        comparisons = {
          "task fingerprint" => [ actual.dig("task", "patrol_fingerprint"), expected["fingerprint"] ],
          "idea fingerprint" => [ actual.dig("idea", "patrol_fingerprint"), expected["fingerprint"] ],
          "PR fingerprint" => [ actual.dig("pr", "patrol_fingerprint"), expected["fingerprint"] ],
          "task PR URL" => [ actual.dig("task", "pr_url"), expected["pr_url"] ],
          "PR URL" => [ actual.dig("pr", "pr_url"), expected["pr_url"] ],
          "branch" => [ actual.dig("worktree", "branch"), expected["branch"] ],
          "worktree path" => [ actual.dig("worktree", "path"), expected["worktree_path"] ],
          "head SHA" => [ actual.dig("worktree", "execute_base_head"), expected["head_sha"] ],
          "workflow" => [ actual.dig("meta", "workflow"), expected["workflow"] ],
          "slug" => [ actual.dig("meta", "slug"), File.basename(folder) ]
        }
        unless expected["context"].nil?
          comparisons["architecture context"] = [ actual["context"], expected["context"] ]
        end
        conflicts = comparisons.filter_map do |label, (found, wanted)|
          "#{label}=#{found.inspect}, expected #{wanted.inspect}" if !found.nil? && found != wanted
        end
        return [ :conflict, conflicts.join("; ") ] unless conflicts.empty?

        absent = comparisons.filter_map { |label, (found, _wanted)| label if found.nil? }
        missing.concat(absent)
        return [ :incomplete, "missing #{missing.uniq.join(', ')}" ] unless missing.empty?

        [ :complete, nil ]
      end

      def read_existing_metadata(folder, include_context:)
        data = {
          "meta" => read_yaml_hash(File.join(folder, "meta.yml")),
          "idea" => read_frontmatter(File.join(folder, "idea.md")),
          "task" => read_frontmatter(File.join(folder, "task.md")),
          "worktree" => read_yaml_hash(File.join(folder, "worktree.yml")),
          "pr" => read_frontmatter(File.join(folder, "pr.md"))
        }
        data["context"] = read_context(File.join(folder, CONTEXT_FILE)) if include_context
        return nil if data.values.any?(&:nil?)

        data
      end

      def read_context(path)
        content = read_if_present(path)
        return nil if content.nil?

        JSON.parse(content)
      rescue JSON::ParserError
        nil
      end

      def existing_task_folders
        Dir.glob(File.join(stages_root, "*", "*")).select do |path|
          File.directory?(path) && !File.basename(path).start_with?(".")
        end.sort
      end

      def folder_fingerprints(folder)
        %w[idea.md task.md pr.md].filter_map do |name|
          read_frontmatter(File.join(folder, name))&.fetch("patrol_fingerprint", nil).to_s.strip
        end.reject(&:empty?).uniq
      end

      def read_yaml_hash(path)
        content = read_if_present(path)
        return nil if content.nil?

        value = YAML.safe_load(content)
        value if value.is_a?(Hash)
      rescue Psych::Exception
        nil
      end

      def read_frontmatter(path)
        content = read_if_present(path)
        return nil if content.nil?

        match = content.match(/\A---\s*\n(.*?)\n---/m)
        return nil unless match

        value = YAML.safe_load(match[1])
        value if value.is_a?(Hash)
      rescue Psych::Exception
        nil
      end

      # An absent file is deterministic task state (incomplete → quarantine
      # and rebuild), but a transient read failure is not: coercing EACCES or
      # EIO to nil either published a duplicate review task for the same
      # fingerprint or renamed a possibly-live task out of 6-review. Let
      # SystemCallError/IOError propagate — the handoff attempt is retryable
      # and callers convert the failure into a pending outcome.
      def read_if_present(path)
        return nil unless File.file?(path)

        File.read(path)
      end

      def publish_task(finding, patch, pr_url, now, expected, lock_id)
        slug = unique_slug(finding)
        final_folder = File.join(review_root, slug)
        staging = File.join(review_root, ".handoff-#{lock_id}-staging-#{Process.pid}-#{SecureRandom.hex(6)}")
        FileUtils.mkdir_p(File.join(staging, "reviews"))
        Hive::AtomicFile.fsync_directory(File.join(staging, "reviews"))
        notify_write(:reviews, File.join(staging, "reviews"))
        write_meta(staging, slug, finding)
        write_idea_md(staging, slug, finding, now, context: expected["context"])
        write_task_md(staging, slug, finding, patch, pr_url, now, context: expected["context"])
        write_worktree_pointer(staging, patch, now)
        write_pr_md(staging, finding, pr_url, linked_task_path: final_folder)
        write_context(staging, expected.fetch("context")) unless expected["context"].nil?
        Hive::AtomicFile.fsync_directory(staging)
        raise Conflict, "patrol review handoff conflict: destination already exists at #{final_folder}" if File.exist?(final_folder)

        File.rename(staging, final_folder)
        Hive::AtomicFile.fsync_directory(review_root)
        final_folder
      end

      def quarantine_interrupted_staging(lock_id)
        Dir.glob(File.join(review_root, ".handoff-#{lock_id}-staging-*"), File::FNM_DOTMATCH).sort.each do |path|
          quarantine(path, "interrupted staging write") if File.directory?(path)
        end
      end

      def quarantine(path, reason)
        FileUtils.mkdir_p(quarantine_root)
        basename = File.basename(path)
        destination = File.join(
          quarantine_root,
          "#{basename}-#{Time.now.utc.strftime('%Y%m%d%H%M%S%6N')}-#{SecureRandom.hex(4)}"
        )
        File.rename(path, destination)
        durable_write(File.join(destination, "quarantine.yml"), { "reason" => reason.to_s }.to_yaml, :quarantine)
        Hive::AtomicFile.fsync_directory(destination)
        Hive::AtomicFile.fsync_directory(quarantine_root)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        destination
      end

      def write_meta(task_folder, slug, finding)
        Hive::TaskMeta.write(
          task_folder,
          id: allocate_task_id,
          slug: slug,
          display_name: display_name(finding),
          workflow: WORKFLOW
        )
        path = File.join(task_folder, "meta.yml")
        fsync_file(path)
        notify_write(:meta_yml, path)
      end

      def allocate_task_id
        Hive::TaskCounter.next!
      rescue Hive::ConcurrentRunError
        nil
      end

      def write_task_md(task_folder, slug, finding, patch, pr_url, now, context:)
        context_section = context_link(context)
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
          <<~MD,
          # #{display_name(finding)}

          Patrol opened this PR from finding `#{finding.id}` and handed it to the standard 6-review flow.

          ## Finding

          #{finding.description}

          ## Recommendation

          #{finding.recommendation}

          ## Patch

          Branch: `#{patch.branch}`
          Fingerprint: `#{finding.fingerprint}`#{context_section}
        MD
          :task_md
        )
      end

      def write_idea_md(task_folder, slug, finding, now, context:)
        text = idea_text(finding, context: context)
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
          "#{text}\n",
          :idea_md
        )
      end

      def write_worktree_pointer(task_folder, patch, now)
        data = {
          "path" => patch.worktree_path,
          "branch" => patch.branch,
          "created_at" => now.utc.iso8601
        }
        data["execute_base_head"] = patch_head(patch) if patch_head(patch)
        durable_write(File.join(task_folder, "worktree.yml"), data.to_yaml, :worktree_yml)
      end

      def write_pr_md(task_folder, finding, pr_url, linked_task_path:)
        write_frontmatter_md(
          File.join(task_folder, "pr.md"),
          {
            "pr_url" => pr_url,
            "pr_number" => pr_number(pr_url),
            "source" => "patrol",
            "patrol_finding_id" => finding.id,
            "patrol_fingerprint" => finding.fingerprint
          },
          <<~MD,
          ## Summary
          Patrol opened this PR for `#{finding.title || finding.id}`.

          ## Linked task
          #{linked_task_path}
        MD
          :pr_md
        )
      end

      def write_context(task_folder, context)
        durable_write(
          File.join(task_folder, CONTEXT_FILE),
          "#{JSON.pretty_generate(context)}\n",
          :architecture_thesis_json
        )
      end

      def write_frontmatter_md(path, data, body, artifact)
        durable_write(path, "#{data.to_yaml}---\n\n#{body}", artifact)
      end

      def durable_write(path, contents, artifact)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |file|
          file.write(contents)
          file.flush
          file.fsync
        end
        notify_write(artifact, path)
        path
      end

      def fsync_file(path)
        File.open(path, File::RDONLY) { |file| file.fsync }
      end

      def notify_write(artifact, path)
        @write_hook&.call(artifact, path)
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

      def slug_taken?(slug)
        !Dir.glob(File.join(stages_root, "*", slug)).empty?
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

      def idea_text(finding, context:)
        parts = []
        parts << "# #{display_name(finding)}"
        parts << "## Finding\n\n#{finding.description}" unless finding.description.to_s.strip.empty?
        parts << "## Recommendation\n\n#{finding.recommendation}" unless finding.recommendation.to_s.strip.empty?
        evidence = Array(finding.evidence)
        parts << "## Evidence\n\n#{evidence_text(evidence)}" unless evidence.empty?
        unless context.nil?
          parts << "## Architecture thesis context\n\n[Open the complete architecture thesis](#{CONTEXT_FILE})."
        end
        parts.join("\n\n")
      end

      def context_link(context)
        return "" if context.nil?

        "\n\n## Architecture thesis context\n\n[Open the complete architecture thesis](#{CONTEXT_FILE})."
      end

      def evidence_text(evidence)
        Array(evidence).map do |entry|
          entry = {} unless entry.is_a?(Hash)
          location = [ entry["file"], entry["line"] ].compact.join(":")
          details = [ entry["claim"], entry["snippet"] ].map { |value| value.to_s.strip }.reject(&:empty?)
          line = location.empty? ? "- evidence" : "- `#{location}`"
          details.empty? ? line : "#{line}: #{details.join(' — ')}"
        end.join("\n")
      end

      def pr_number(pr_url)
        Hive::Pr.number(pr_url)&.delete_prefix("#")
      end

      def stages_root
        File.join(@project_root, ".hive-state", "stages")
      end

      def review_root
        File.join(stages_root, "6-review") # coding-scoped: refactor PRs enter normal code review
      end

      def quarantine_root
        File.join(review_root, ".handoff-quarantine")
      end
    end
  end
end
