require "fileutils"
require "json"
require "open3"
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
      REVIEW_STAGE = Hive::Workflows.for_verb("review").fetch(:target).freeze

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
        project_name = project.fetch("name")
        hive_state_path = project.fetch("hive_state_path")
        # Parse the identifier in its own narrow rescue (see parse_pr_number!)
        # so only an invalid identifier maps to a USAGE error; an ArgumentError
        # from anywhere else stays a genuine InternalError below.
        pr_number = parse_pr_number!
        slug = slug_for(pr_number)

        return reuse(slug, hive_state_path, project_name) if reusable_folder?(hive_state_path, slug, pr_number)

        refuse_if_owned!(hive_state_path, slug, pr_number)

        # Fetch PR metadata only once we know we will create — after the reuse
        # short-circuit and ownership check — so a re-run reuses offline and a
        # collision fails without a needless `gh pr view` round-trip. chdir to
        # the resolved project so `--project` queries the right repo, not cwd.
        metadata = Hive::Gh.pr_metadata(pr_number, chdir: project_root)

        task_folder = create_task!(hive_state_path, project_root, slug, pr_number, metadata, now)
        { slug: slug, project: project_name, task_folder: task_folder, reused: false }
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json
        raise wrapped
      end

      private

      def parse_pr_number!
        Hive::Pr.identifier_to_number(@pr_identifier)
      rescue ArgumentError => e
        raise Hive::InvalidTaskPath, e.message
      end

      def reuse(slug, hive_state_path, project_name)
        {
          slug: slug,
          project: project_name,
          task_folder: File.join(hive_state_path, "stages", REVIEW_STAGE, slug),
          reused: true
        }
      end

      def slug_for(pr_number)
        "adhoc-review-pr-#{pr_number}"
      end

      def reusable_folder?(hive_state_path, slug, pr_number)
        folder = File.join(hive_state_path, "stages", REVIEW_STAGE, slug)
        return false unless File.directory?(folder)

        validate_reusable!(folder, slug, pr_number)
        true
      end

      # A 6-review folder at the deterministic ad-hoc slug is only reusable when
      # it is actually this PR's ad-hoc review. A normal task (or a wrong-PR
      # task) that happens to carry the same slug would otherwise be silently
      # adopted and re-run as the ad-hoc review; refuse it instead, mirroring
      # the refuse-to-shadow guard in refuse_if_owned!.
      def validate_reusable!(folder, slug, pr_number)
        frontmatter = Hive::Gh.pr_frontmatter(File.join(folder, "pr.md"))
        source = frontmatter["source"].to_s.strip
        owned_pr = frontmatter["pr_number"].to_i
        return if source == SOURCE && owned_pr == pr_number.to_i

        raise CollisionError,
              "review folder #{slug} already exists but is not an ad-hoc review for PR ##{pr_number} " \
              "(source=#{source.inspect}, pr_number=#{owned_pr}); " \
              "run `hive drop #{slug}` before creating an ad-hoc review"
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
          next if stage == REVIEW_STAGE

          { stage: stage, slug: slug, folder: folder }
        end.first
      end

      def existing_pr_owner(hive_state_path, pr_number)
        Dir.glob(File.join(hive_state_path, "stages", "*", "*", "pr.md")).filter_map do |path|
          frontmatter = read_pr_frontmatter_for_scan(path)
          next unless frontmatter
          next unless frontmatter["pr_number"].to_i == pr_number.to_i

          folder = File.dirname(path)
          { stage: File.basename(File.dirname(folder)), slug: File.basename(folder), folder: folder }
        end.first
      end

      # pr_frontmatter rescues only Psych errors; a permission error or an
      # ENOENT TOCTOU race on another task's pr.md would otherwise abort the
      # whole ownership scan and block ad-hoc review for every PR. Skip the
      # unreadable file (loudly) so one bad sidecar can't wedge the command.
      def read_pr_frontmatter_for_scan(path)
        Hive::Gh.pr_frontmatter(path)
      rescue SystemCallError => e
        warn "[hive.review] ad-hoc collision scan skipping unreadable #{path.inspect}: #{e.class}: #{e.message}"
        nil
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
          path: worktree_path_for(project_root, slug),
          branch: branch_for(pr_number)
        )
      end

      def worktree_path_for(project_root, slug)
        File.join(Hive::Worktree.canonical_root(project_root), slug)
      end

      def branch_for(pr_number)
        "hive/review/pr-#{pr_number}"
      end

      def create_task!(hive_state_path, project_root, slug, pr_number, metadata, now)
        task_folder = File.join(hive_state_path, "stages", REVIEW_STAGE, slug)
        FileUtils.mkdir_p(File.join(task_folder, "reviews"))
        materialized = materialize(project_root, slug, pr_number)
        verify_head!(pr_number, metadata, materialized)
        write_sidecars(task_folder, slug, metadata, materialized, now)
        task_folder
      rescue StandardError
        cleanup_failed_task!(project_root, slug, pr_number, task_folder)
        raise
      end

      # Mirror Hive::Babysitter::Worktree#remove_existing!: a failure after
      # `git worktree add` succeeds — a verify_head! head-race (benign PR
      # re-push between metadata fetch and materialize) or a sidecar write
      # error — would otherwise orphan the worktree at canonical_root/<slug>
      # plus its `hive/review/pr-N` branch and `refs/hive/review/pr-N` ref, so
      # the next `hive review --pr N` wedges on "already exists in the worktree
      # list" until an operator runs `git worktree prune` by hand. Remove the
      # task folder, the worktree (force + prune), the branch, and the ref so a
      # retry starts clean. Best-effort: git non-zero exits are ignored so they
      # cannot mask the original failure being re-raised.
      def cleanup_failed_task!(project_root, slug, pr_number, task_folder)
        FileUtils.rm_rf(task_folder) if task_folder
        worktree_path = worktree_path_for(project_root, slug)
        branch = branch_for(pr_number)
        Open3.capture3("git", "-C", project_root, "worktree", "remove", "--force", worktree_path)
        Open3.capture3("git", "-C", project_root, "worktree", "prune")
        Open3.capture3("git", "-C", project_root, "branch", "-D", branch)
        Open3.capture3("git", "-C", project_root, "update-ref", "-d", "refs/#{branch}")
        FileUtils.rm_rf(worktree_path)
      end

      def verify_head!(pr_number, metadata, materialized)
        expected = metadata.head_ref_oid.to_s
        actual = materialized.fetch(:head_sha).to_s
        if expected.empty?
          warn "[hive.review] gh reported no head SHA for PR ##{pr_number}; " \
               "skipping the worktree-matches-PR head check"
          return
        end
        return if actual == expected

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

      # Emit the standard hive-stage-action error envelope on stdout so a
      # create-phase failure (bad identifier, not-invited, refuse-to-shadow
      # collision, gh/auth/worktree setup error) surfaces the same structured
      # JSON an agent gets from StageAction on the `hive review <slug> --json`
      # path. The caller re-raises afterwards so bin/hive still maps the exit
      # code and prints the stderr line; StageAction owns the envelope once the
      # task exists, so the two never double-emit.
      def emit_error_envelope(error)
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-stage-action",
          error: error,
          error_kind: error_kind_for(error),
          extras: { "verb" => "review" }
        )
        puts JSON.generate(payload)
      rescue Errno::EPIPE, JSON::GeneratorError
        # stdout closed or payload not serialisable; the re-raise still carries
        # the failure to bin/hive for the exit code + stderr line.
      end

      def error_kind_for(error)
        case error
        when CollisionError then "destination_collision"
        when Hive::InvalidTaskPath then "invalid_task_path"
        else "error"
        end
      end
    end
  end
end
