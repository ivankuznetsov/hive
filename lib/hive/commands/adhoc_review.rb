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
      include Hive::Schemas::EnvelopeEmitter

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
        # call_with_envelope (Hive::Schemas::EnvelopeEmitter) owns the twin
        # Hive::Error / StandardError rescue + --json error-envelope emission so
        # this command can't drift from the shared emitter. `next` (not
        # `return`) yields the reuse short-circuit value back through the block.
        call_with_envelope do
          project = Hive::Config.registered_project!(name: @project_name, cwd: Dir.pwd)
          project_root = project.fetch("path")
          project_name = project.fetch("name")
          # Resolve hive_state_path through the SAME resolver registered_project!
          # validates with (project-relative entries are joined against the
          # project root). Consuming the raw registry value here would interpret
          # a hand-edited *relative* hive_state_path against the caller's cwd —
          # validation would pass while sidecars landed in the wrong place.
          hive_state_path = Hive::Config.project_hive_state_path(project)
          # Parse the identifier in its own narrow rescue (see parse_pr_number!)
          # so only an invalid identifier maps to a USAGE error; an ArgumentError
          # from anywhere else stays a genuine InternalError below.
          pr_number = parse_pr_number!
          slug = slug_for(pr_number)

          next reuse(slug, hive_state_path, project_name) if reusable_folder?(hive_state_path, slug, pr_number)

          refuse_if_owned!(hive_state_path, slug, pr_number)

          # Fetch PR metadata only once we know we will create — after the reuse
          # short-circuit and ownership check — so a re-run reuses offline and a
          # collision fails without a needless `gh pr view` round-trip. chdir to
          # the resolved project so `--project` queries the right repo, not cwd.
          # Thread the project cfg so the configured `gh.network_timeout_sec`
          # applies, matching the sibling gh helpers.
          cfg = Hive::Config.load(project_root)
          metadata = Hive::Gh.pr_metadata(pr_number, cfg: cfg, chdir: project_root)

          task_folder = create_task!(hive_state_path, project_root, slug, pr_number, metadata, now)
          { slug: slug, project: project_name, task_folder: task_folder, reused: false }
        end
      end

      # EnvelopeEmitter hooks — emit the standard hive-stage-action error
      # envelope on stdout under `--json` so a create-phase failure (bad
      # identifier, not-invited, refuse-to-shadow collision, gh/auth/worktree
      # setup error) surfaces the same structured JSON an agent gets from
      # StageAction. bin/hive still maps the exit code + prints the stderr line
      # after the re-raise; StageAction owns the envelope once the task exists,
      # so the two never double-emit.
      def envelope_schema
        "hive-stage-action"
      end

      def envelope_extras
        { "verb" => "review" }
      end

      def envelope_error_kind(error)
        error_kind_for(error)
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
          task_folder: review_task_folder(hive_state_path, slug),
          reused: true
        }
      end

      def slug_for(pr_number)
        "adhoc-review-pr-#{pr_number}"
      end

      # The deterministic 6-review folder for an ad-hoc slug. One home for the
      # path so `reuse`, `reusable_folder?`, and `create_task!` can't drift.
      def review_task_folder(hive_state_path, slug)
        File.join(hive_state_path, "stages", REVIEW_STAGE, slug)
      end

      def reusable_folder?(hive_state_path, slug, pr_number)
        folder = review_task_folder(hive_state_path, slug)
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
        # Read pr.md through the SystemCallError-guarded helper the collision
        # scan uses (not bare pr_frontmatter, which rescues only Psych) so a
        # permission/IO error on this one file surfaces as a clean collision
        # message rather than a wrapped InternalError. nil (unreadable) falls
        # through to the refuse branch, which already points at `hive drop`.
        frontmatter = read_pr_frontmatter_for_scan(File.join(folder, "pr.md")) || {}
        # casecmp? matches the review stage's reader (review.rb adhoc_task?):
        # a drifted `source: Ad-Hoc` must not route as ad-hoc there yet be
        # rejected here.
        source = frontmatter["source"].to_s.strip
        owned_pr = frontmatter["pr_number"].to_i
        unless source.casecmp?(SOURCE) && owned_pr == pr_number.to_i
          raise CollisionError,
                "review folder #{slug} already exists but is not an ad-hoc review for PR ##{pr_number} " \
                "(source=#{source.inspect}, pr_number=#{owned_pr}); " \
                "run `hive drop #{slug}` before creating an ad-hoc review"
        end

        verify_reusable_worktree!(folder, slug)
      end

      # The reuse path returns the existing task without re-materializing, so
      # its carried-over worktree must still be on disk. A pruned or
      # hand-removed worktree would otherwise pass enqueue and only fail deep
      # in the review stage ("worktree pointer present but worktree missing").
      # Surface it cleanly here, pointing at the explicit-teardown path.
      def verify_reusable_worktree!(folder, slug)
        pointer = Hive::Worktree.read_pointer(folder)
        worktree_path = pointer && pointer["path"]
        return if worktree_path && File.directory?(worktree_path)

        # Distinguish the three failure modes so the remediation hint matches
        # the real cause. read_pointer swallows a permission/parse error on
        # worktree.yml to nil, which previously surfaced an unreadable pointer
        # as "worktree is missing (no worktree.yml path)" — pointing at the
        # wrong cause.
        detail =
          if worktree_path
            "its worktree is missing (#{worktree_path})"
          elsif File.exist?(File.join(folder, "worktree.yml"))
            "its worktree pointer #{File.join(folder, 'worktree.yml')} is unreadable or has no path"
          else
            "its worktree pointer #{File.join(folder, 'worktree.yml')} is missing"
          end

        raise CollisionError,
              "ad-hoc review folder #{slug} exists but #{detail}; " \
              "run `hive drop #{slug}` and re-run to recreate it"
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

          { stage: stage, slug: slug }
        end.first
      end

      def existing_pr_owner(hive_state_path, pr_number)
        Dir.glob(File.join(hive_state_path, "stages", "*", "*", "pr.md")).filter_map do |path|
          frontmatter = read_pr_frontmatter_for_scan(path)
          next unless frontmatter
          next unless frontmatter["pr_number"].to_i == pr_number.to_i

          folder = File.dirname(path)
          { stage: File.basename(File.dirname(folder)), slug: File.basename(folder) }
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
        task_folder = review_task_folder(hive_state_path, slug)
        FileUtils.mkdir_p(File.join(task_folder, "reviews"))
        # Proactively clear an orphan worktree/branch/ref BEFORE materializing
        # (mirrors Hive::Babysitter::Worktree#remove_existing!): a prior
        # SIGKILL after `git worktree add` leaves `.git/worktrees/<slug>` admin
        # metadata that makes this run's add fail with "already exists in the
        # worktree list". Without this the first retry fails and only the
        # second self-heals; with it a single retry is clean.
        remove_orphan_worktree!(project_root, slug, pr_number)
        materialized = materialize(project_root, slug, pr_number)
        verify_head!(pr_number, metadata, materialized)
        write_sidecars(task_folder, slug, pr_number, metadata, materialized, now)
        task_folder
      rescue StandardError
        cleanup_failed_task!(project_root, slug, pr_number, task_folder)
        raise
      end

      # Roll back a partially-created task after a create-phase failure — a
      # verify_head! head-race (benign PR re-push between metadata fetch and
      # materialize) or a sidecar write error would otherwise orphan the
      # worktree at canonical_root/<slug> plus its `hive/review/pr-N` branch
      # and `refs/hive/review/pr-N` ref, wedging the next `hive review --pr N`
      # on "already exists in the worktree list". Guarded twice over:
      #   * the whole body is wrapped so cleanup's OWN spawn/IO errors
      #     (Errno::ENOENT from a missing git, Errno::EACCES from rm_rf) can
      #     never mask the original create-phase error create_task! re-raises
      #     immediately after — the "cannot mask the original failure"
      #     guarantee now covers exceptions, not just non-zero git exits;
      #   * after removal it checks for surviving residue (a stale
      #     `git worktree list` entry or the branch ref) and warns, so a
      #     partial cleanup failure is observable rather than silently
      #     re-wedging the next run.
      def cleanup_failed_task!(project_root, slug, pr_number, task_folder)
        FileUtils.rm_rf(task_folder) if task_folder
        remove_orphan_worktree!(project_root, slug, pr_number)
        residue = cleanup_residue(project_root, slug, pr_number)
        unless residue.empty?
          warn "[hive.review] ad-hoc cleanup could not fully remove #{residue.join(' and ')} for #{slug}; " \
               "run `git -C #{project_root} worktree prune` before retrying `hive review --pr #{pr_number}`"
        end
      rescue StandardError => e
        warn "[hive.review] ad-hoc cleanup after a failed create did not complete: " \
             "#{e.class}: #{e.message} — run `git -C #{project_root} worktree prune` if a retry wedges"
      end

      # Best-effort removal of any worktree + branch + fetch ref for this
      # slug/PR. Exit codes are intentionally ignored: the common (clean) case
      # has nothing to remove, so the proactive pre-materialize caller must not
      # warn, and the cleanup caller surfaces a genuine partial failure via
      # cleanup_residue instead.
      def remove_orphan_worktree!(project_root, slug, pr_number)
        worktree_path = worktree_path_for(project_root, slug)
        branch = branch_for(pr_number)
        Open3.capture3("git", "-C", project_root, "worktree", "remove", "--force", worktree_path)
        Open3.capture3("git", "-C", project_root, "worktree", "prune")
        Open3.capture3("git", "-C", project_root, "branch", "-D", branch)
        Open3.capture3("git", "-C", project_root, "update-ref", "-d", "refs/#{branch}")
        FileUtils.rm_rf(worktree_path)
      end

      # Artifacts that survived remove_orphan_worktree!: the stale
      # `git worktree list` entry (the actual "already exists in the worktree
      # list" wedge) and the `hive/review/pr-N` branch. Empty in the common
      # case (nothing was created, or everything was removed), so the cleanup
      # warning fires only on a genuine partial-cleanup failure.
      def cleanup_residue(project_root, slug, pr_number)
        residue = []
        worktree_path = worktree_path_for(project_root, slug)
        residue << "worktree #{worktree_path}" if worktree_listed?(project_root, worktree_path)
        branch = branch_for(pr_number)
        residue << "branch #{branch}" if Hive::Worktree.local_branch_ref_exists?(project_root, branch)
        residue
      end

      def worktree_listed?(project_root, worktree_path)
        out, _err, status = Open3.capture3("git", "-C", project_root, "worktree", "list", "--porcelain")
        return false unless status.success?

        expanded = File.expand_path(worktree_path)
        out.each_line.any? do |line|
          line.start_with?("worktree ") &&
            File.expand_path(line.delete_prefix("worktree ").strip) == expanded
        end
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

      # Thread the VALIDATED parsed pr_number (the same value the slug, branch,
      # and reuse check use) into every sidecar — never the gh-sourced
      # metadata.number (which coerces an absent `number` to 0) — so the
      # `…-pr-N` slug and the pr.md `pr_number` can't disagree and mis-fire
      # reuse detection.
      def write_sidecars(task_folder, slug, pr_number, metadata, materialized, now)
        write_meta(task_folder, slug, pr_number)
        write_idea_md(task_folder, slug, pr_number, now)
        write_task_md(task_folder, slug, pr_number, metadata, now)
        write_worktree_pointer(task_folder, materialized, now)
        write_pr_md(task_folder, pr_number, metadata)
      end

      def write_meta(task_folder, slug, pr_number)
        Hive::TaskMeta.write(
          task_folder,
          id: allocate_task_id,
          slug: slug,
          display_name: "Ad-hoc review: PR ##{pr_number}",
          workflow: Hive::Workflows::CODING_ID.to_s
        )
      end

      # Mirror the patrol handoff (Hive::Patrol::ReviewHandoff#allocate_task_id):
      # under >30s commit-lock contention TaskCounter.next! raises
      # ConcurrentRunError. Proceed with id: nil rather than discarding the
      # already-completed fetch + worktree; the daemon's TaskIdBackfiller
      # assigns a real id on a later tick.
      def allocate_task_id
        Hive::TaskCounter.next!
      rescue Hive::ConcurrentRunError
        nil
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

      def write_task_md(task_folder, slug, pr_number, metadata, now)
        write_frontmatter_md(
          File.join(task_folder, "task.md"),
          {
            "slug" => slug,
            "started_at" => now.utc.iso8601,
            "source" => SOURCE,
            "pr_url" => metadata.url
          },
          <<~MD
          # Ad-hoc review: PR ##{pr_number}

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

      def write_pr_md(task_folder, pr_number, metadata)
        write_frontmatter_md(
          File.join(task_folder, "pr.md"),
          {
            "pr_url" => metadata.url,
            "pr_number" => pr_number,
            "source" => SOURCE,
            "base_ref_name" => metadata.base_ref_name,
            "head_ref_oid" => metadata.head_ref_oid,
            "is_cross_repository" => metadata.is_cross_repository,
            "state" => metadata.state
          },
          <<~MD
          ## Summary
          Ad-hoc review for PR ##{pr_number}.

          ## Base
          #{metadata.base_ref_name}
        MD
        )
      end

      def write_frontmatter_md(path, data, body)
        File.write(path, "#{data.to_yaml}---\n\n#{body}")
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
