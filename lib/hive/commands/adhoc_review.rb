require "fileutils"
require "json"
require "securerandom"
require "thread"
require "time"
require "yaml"
require "hive/agent_git_gate"
require "hive/atomic_file"
require "hive/config"
require "hive/gh"
require "hive/internal_pr_checkout"
require "hive/lock"
require "hive/pr"
require "hive/task_counter"
require "hive/task"
require "hive/task_journal"
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
      CLAIMS_DIR = ".adhoc-review-claims".freeze
      CLAIM_SCHEMA = "hive.adhoc-review.creation-claim".freeze
      DEFAULT_CLAIM_WAIT_SEC = 30.0
      CLAIM_POLL_INTERVAL_SEC = 0.02

      ACTIVE_CLAIMS_MUTEX = Mutex.new
      ACTIVE_CLAIMS = {}

      def initialize(pr:, project: nil, json: false, gh: Hive::Gh, gate: Hive::AgentGitGate,
                     allow_local_transport: nil, claim_wait_timeout: DEFAULT_CLAIM_WAIT_SEC,
                     failpoint: nil)
        @pr_identifier = pr
        @project_name = project
        @json = json
        @gh = gh
        @gate = gate
        @allow_local_transport = allow_local_transport
        @claim_wait_timeout = Float(claim_wait_timeout)
        @failpoint = failpoint
      end

      def call
        enqueue.fetch(:slug)
      end

      def enqueue(now: Time.now)
        call_with_envelope do
          project = Hive::Config.registered_project!(name: @project_name, cwd: Dir.pwd)
          project_root = project.fetch("path")
          project_name = project.fetch("name")
          hive_state_path = Hive::Config.project_hive_state_path(project)
          pr_number = parse_pr_number!
          slug = Hive::InternalPrCheckout::Identity.slug_for(pr_number)

          cfg = Hive::Config.load(project_root)
          worktree_root = Hive::Worktree.canonical_root(project_root, config: cfg)
          worktree_path = Hive::InternalPrCheckout::Identity.worktree_path_for(project_root, slug, config: cfg)
          branch = Hive::InternalPrCheckout::Identity.branch_for(pr_number)

          disposition, claim = acquire_or_reuse!(
            hive_state_path: hive_state_path,
            project_root: project_root,
            project_name: project_name,
            worktree_root: worktree_root,
            worktree_path: worktree_path,
            slug: slug,
            pr_number: pr_number,
            branch: branch,
            now: now
          )
          next disposition if disposition

          task_folder = create_claimed_task!(
            hive_state_path: hive_state_path,
            project_root: project_root,
            project_name: project_name,
            worktree_root: worktree_root,
            cfg: cfg,
            claim: claim,
            now: now
          )
          { slug: slug, project: project_name, task_folder: task_folder, reused: false }
        end
      end

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

      def review_task_folder(hive_state_path, slug)
        File.join(hive_state_path, "stages", REVIEW_STAGE, slug)
      end

      def claims_dir(hive_state_path)
        File.join(hive_state_path, CLAIMS_DIR)
      end

      def claim_path_for(hive_state_path, slug)
        File.join(claims_dir(hive_state_path), "#{slug}.json")
      end

      # Reserve `(project, pr_number, slug)` under the short project commit lock
      # before allocating an ID, fetching PR metadata, or touching Git state.
      # Concurrent callers seeing a live claim wait outside the commit lock and
      # reuse the published winner or claim after a failed owner rolls back.
      def acquire_or_reuse!(hive_state_path:, project_root:, project_name:, worktree_root:,
                            worktree_path:, slug:, pr_number:, branch:, now:)
        wait_deadline = monotonic_now + @claim_wait_timeout
        claim_path = claim_path_for(hive_state_path, slug)

        loop do
          @failpoint&.call(:before_claim_lock, slug: slug, pr_number: pr_number)
          outcome = Hive::Lock.with_commit_lock(hive_state_path) do
            folder = review_task_folder(hive_state_path, slug)
            if File.directory?(folder)
              validate_reusable!(folder, slug, pr_number)
              next [ :reuse, reuse(slug, hive_state_path, project_name) ]
            end

            refuse_if_owned!(hive_state_path, slug, pr_number)

            existing = read_claim(claim_path)
            if existing
              if claim_owner_alive?(claim_path, existing)
                next [ :wait, nil ]
              end

              # Stale claim from a dead owner: clean ONLY proven owner-acquired resources.
              rollback_owned_resources!(
                project_root: project_root,
                worktree_root: worktree_root,
                claim: existing,
                strict: true
              )
              remove_claim_file!(claim_path, expected_token: existing["owner_token"])
            end

            owner_token = SecureRandom.hex(12)
            staging_dir = File.join(claims_dir(hive_state_path), "#{slug}.staging-#{owner_token}")
            quarantine_ref = Hive::InternalPrCheckout::Identity.quarantine_ref_for("create-#{owner_token}")
            claim = {
              "schema" => CLAIM_SCHEMA,
              "schema_version" => 1,
              "owner_token" => owner_token,
              "pid" => Process.pid,
              "process_start_time" => Hive::Lock.process_start_time(Process.pid),
              "project" => project_name,
              "pr_number" => pr_number,
              "slug" => slug,
              "branch" => branch,
              "worktree_path" => worktree_path,
              "quarantine_ref" => quarantine_ref,
              "staging_dir" => staging_dir,
              "task_folder" => folder,
              "head_oid" => nil,
              "resources" => {},
              "created_at" => now.utc.iso8601(6)
            }
            write_claim!(claim_path, claim)
            register_in_process_claim(claim_path, owner_token)
            [ :claimed, claim ]
          end

          case outcome.first
          when :reuse
            return [ outcome.last, nil ]
          when :claimed
            @failpoint&.call(:after_claim_acquired, outcome.last)
            return [ nil, outcome.last ]
          when :wait
            if monotonic_now >= wait_deadline
              raise Hive::ConcurrentRunError.new(
                "another hive review --pr #{pr_number} creation is in progress for #{slug}",
                lock_path: claim_path
              )
            end
            sleep CLAIM_POLL_INTERVAL_SEC
          end
        end
      end

      # Validate deterministic task/PR ownership only — never run permissive
      # worktree inspection or make checkout decisions here. U2 owns all
      # existing-task checkout verification and reconciliation.
      def validate_reusable!(folder, slug, pr_number)
        pr_path = File.join(folder, "pr.md")
        frontmatter = read_reusable_pr_frontmatter!(pr_path, slug, pr_number)
        source = frontmatter["source"].to_s.strip
        owned_pr = frontmatter["pr_number"].to_i
        unless source.casecmp?(SOURCE) && owned_pr == pr_number.to_i
          raise CollisionError,
                "review folder #{slug} already exists but is not an ad-hoc review for PR ##{pr_number} " \
                "(source=#{source.inspect}, pr_number=#{owned_pr}); " \
                "run `hive drop #{slug}` before creating an ad-hoc review"
        end
        true
      end

      def read_reusable_pr_frontmatter!(pr_path, slug, pr_number)
        unless File.exist?(pr_path) || File.symlink?(pr_path)
          raise CollisionError,
                "review folder #{slug} already exists but is missing pr.md for PR ##{pr_number}; " \
                "run `hive drop #{slug}` before creating an ad-hoc review"
        end
        stat = File.lstat(pr_path)
        if stat.symlink? || !stat.file?
          raise CollisionError,
                "review folder #{slug} has an unsafe pr.md (not a regular file); " \
                "run `hive drop #{slug}` before creating an ad-hoc review"
        end
        frontmatter = read_pr_frontmatter_for_scan(pr_path)
        unless frontmatter.is_a?(Hash) && !frontmatter.empty?
          raise CollisionError,
                "review folder #{slug} has unreadable pr.md frontmatter for PR ##{pr_number}; " \
                "run `hive drop #{slug}` before creating an ad-hoc review"
        end
        frontmatter
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

      def create_claimed_task!(hive_state_path:, project_root:, project_name:, worktree_root:,
                               cfg:, claim:, now:)
        claim_path = claim_path_for(hive_state_path, claim.fetch("slug"))
        owner_token = claim.fetch("owner_token")
        pr_number = claim.fetch("pr_number")
        slug = claim.fetch("slug")
        branch = claim.fetch("branch")
        worktree_path = claim.fetch("worktree_path")
        quarantine_ref = claim.fetch("quarantine_ref")
        staging_dir = claim.fetch("staging_dir")
        task_folder = claim.fetch("task_folder")
        allow_local = allow_local_transport?(cfg)
        published = false

        # Slow provider + Git operations run OUTSIDE the short project commit lock.
        @gate.verify_repository_config!(project_root)
        remote_info = validate_origin_remote!(project_root, allow_local: allow_local)
        deadline = monotonic_now + network_timeout_sec(cfg)

        metadata = @gh.validated_pr_metadata(
          pr_number,
          expected_host: remote_info[:host],
          expected_repository: remote_info[:repository],
          cfg: cfg,
          chdir: project_root,
          deadline: deadline
        )
        head_oid = validated_provider_head!(pr_number, metadata)
        parsed_url = Hive::Gh.parse_pull_request_url(metadata.url)
        unless parsed_url && parsed_url.fetch("number") == pr_number
          raise Hive::GhError, "PR ##{pr_number} metadata URL #{metadata.url.inspect} is not canonical"
        end

        claim = claim.merge("head_oid" => head_oid)
        persist_claim_if_owned!(hive_state_path, claim_path, claim)

        ensure_no_preexisting_git_residue!(project_root, worktree_path: worktree_path, branch: branch)

        claim = record_claim_resource!(
          hive_state_path, claim_path, claim,
          "quarantine_ref", { "ref" => quarantine_ref, "oid" => head_oid }
        )
        @gate.fetch_pull_request_commit(
          repository_path: project_root,
          pr_number: pr_number,
          expected_oid: head_oid,
          quarantine_ref: quarantine_ref,
          expected_remote_fingerprint: remote_info.fetch(:fingerprint),
          allow_local_transport: allow_local,
          deadline: deadline
        )
        @failpoint&.call(:after_fetch, claim)

        claim = record_claim_resource!(
          hive_state_path, claim_path, claim,
          "branch", { "ref" => "refs/heads/#{branch}", "oid" => head_oid }
        )
        claim = record_claim_resource!(
          hive_state_path, claim_path, claim,
          "worktree", { "path" => worktree_path, "branch" => branch, "oid" => head_oid }
        )
        if File.symlink?(worktree_root)
          raise Hive::WorktreeError, "worktree root #{worktree_root} must be a real directory, not a symlink"
        end
        FileUtils.mkdir_p(worktree_root) unless File.directory?(worktree_root)

        receipt = @gate.materialize_owned_branch(
          repository_path: project_root,
          branch: branch,
          oid: head_oid,
          destination: worktree_path,
          destination_root: worktree_root
        )
        unless receipt.oid == head_oid
          raise Hive::WorktreeError,
                "PR ##{pr_number} materialized at #{receipt.oid}, but GitHub reported head #{head_oid}"
        end
        @failpoint&.call(:after_materialize, claim)

        # Stage complete task folder + generation 1 before atomic publication.
        claim = record_claim_resource!(
          hive_state_path, claim_path, claim,
          "staging_dir", { "path" => staging_dir }
        )
        build_staged_task_folder!(
          staging_dir: staging_dir,
          slug: slug,
          project_name: project_name,
          pr_number: pr_number,
          parsed_url: parsed_url,
          metadata: metadata,
          head_oid: head_oid,
          worktree_path: receipt.destination,
          branch: branch,
          now: now
        )
        @failpoint&.call(:before_publish, claim)

        # Publish atomically under short project commit lock.
        Hive::Lock.with_commit_lock(hive_state_path) do
          current_claim = read_claim(claim_path)
          unless current_claim && current_claim["owner_token"] == owner_token
            raise Hive::ConcurrentRunError.new("creation claim ownership lost for #{slug}", lock_path: claim_path)
          end
          if File.exist?(task_folder) || File.symlink?(task_folder)
            raise CollisionError, "review folder #{slug} appeared before publication"
          end
          refuse_if_owned!(hive_state_path, slug, pr_number)

          FileUtils.mkdir_p(File.dirname(task_folder))
          File.rename(staging_dir, task_folder)
          Hive::AtomicFile.fsync_directory(File.dirname(task_folder))
          published = true

          cleanup_quarantine_ref_safely(project_root, quarantine_ref: quarantine_ref, expected_oid: head_oid)
          remove_claim_file!(claim_path, expected_token: owner_token)
          deregister_in_process_claim(claim_path, owner_token)
        end

        task_folder
      rescue StandardError
        unless published
          rollback_claimed_creation!(
            hive_state_path: hive_state_path,
            project_root: project_root,
            worktree_root: worktree_root,
            claim_path: claim_path,
            owner_token: owner_token
          )
        end
        raise
      end

      def validate_origin_remote!(project_root, allow_local:)
        urls = @gate.remote_urls(repository_path: project_root, remote: "origin", push: false)
        unless urls.one?
          raise Hive::WorktreeError, "origin remote must resolve to exactly one fetch URL (found #{urls.size})"
        end
        url = urls.first
        fingerprint = @gate.remote_target_fingerprint(
          repository_path: project_root,
          remote: "origin",
          push: false,
          allow_local_transport: allow_local
        )
        github_shaped = url.match?(/\A(?:https?|ssh|git):\/\//i) ||
                        (url.match?(/\A(?:[^@\/]+@)?[^:\/]+:.+\z/) && !url.start_with?("/"))
        host = nil
        repository = nil
        if !allow_local || github_shaped
          remote_id = Hive::Gh.repository_identity_from_remote(url)
          host = remote_id.fetch("host").downcase
          repository = remote_id.fetch("repository").downcase
        end
        { url: url, fingerprint: fingerprint, host: host, repository: repository }
      rescue Hive::AgentGitGate::Error => e
        raise Hive::WorktreeError, e.message
      end

      def validated_provider_head!(pr_number, metadata)
        head = metadata.head_ref_oid.to_s.strip.downcase
        unless head.match?(Hive::InternalPrCheckout::Identity::OID_PATTERN)
          raise Hive::GhError, "PR ##{pr_number} metadata is missing a valid full head commit OID"
        end
        head
      end

      def ensure_no_preexisting_git_residue!(project_root, worktree_path:, branch:)
        expanded = File.expand_path(worktree_path)
        if File.exist?(expanded) || File.symlink?(expanded)
          raise Hive::WorktreeError,
                "unexplained preexisting worktree path #{expanded} blocks creation; inspect and clean up manually before retrying"
        end
        if worktree_listed?(project_root, expanded)
          raise Hive::WorktreeError,
                "unexplained preexisting registered worktree #{expanded} blocks creation; run `git -C #{project_root} worktree prune` after inspecting it"
        end
        if @gate.read(project_root, :branch_oid, branch: branch).success?
          raise Hive::WorktreeError,
                "unexplained preexisting branch #{branch} blocks creation; inspect and remove it before retrying"
        end
      end

      def worktree_listed?(project_root, worktree_path)
        res = @gate.read(project_root, :worktree_paths)
        return false unless res.success?

        expanded = File.expand_path(worktree_path)
        res.stdout.each_line.any? do |line|
          line.start_with?("worktree ") &&
            File.expand_path(line.delete_prefix("worktree ").strip) == expanded
        end
      end

      def build_staged_task_folder!(staging_dir:, slug:, project_name:, pr_number:, parsed_url:,
                                    metadata:, head_oid:, worktree_path:, branch:, now:)
        Dir.mkdir(staging_dir, 0o755)
        Dir.mkdir(File.join(staging_dir, "reviews"), 0o700)

        task_id = Hive::TaskCounter.next_or_nil
        Hive::TaskMeta.write(
          staging_dir,
          id: task_id,
          slug: slug,
          display_name: "Ad-hoc review: PR ##{pr_number}",
          workflow: Hive::Workflows::CODING_ID.to_s
        )
        write_idea_md(staging_dir, slug, pr_number, now)
        write_task_md(staging_dir, slug, pr_number, metadata, now)
        write_worktree_pointer(staging_dir, worktree_path, branch, metadata.base_ref_name, head_oid, now)
        write_pr_md(staging_dir, pr_number, parsed_url.fetch("url"), metadata, head_oid)

        Hive::TaskJournal::Writer.new(
          task_folder: staging_dir, clock: -> { now }
        ).append(
          event_type: "legacy_baseline",
          task: { "id" => task_id&.to_s, "slug" => slug },
          workflow: Hive::Workflows::CODING_ID.to_s,
          stage: REVIEW_STAGE,
          attempt_id: Hive::TaskJournal::LEGACY_ATTEMPT_ID,
          task_generation: 0,
          ownership_generation: nil,
          commit_generation: 0,
          reason: "ad_hoc_review_created",
          evidence: [ {
            "type" => "commit", "sha" => head_oid, "branch" => branch
          } ],
          provenance: { "source" => "ad_hoc_review" },
          payload: {}
        )

        Hive::InternalPrCheckout.initialize_new_task!(
          task_folder: staging_dir,
          task_id: task_id&.to_s,
          task_slug: slug,
          project: project_name,
          pr_host: parsed_url.fetch("host"),
          pr_repository: parsed_url.fetch("repository"),
          pr_number: pr_number,
          pr_url: parsed_url.fetch("url"),
          base_ref_name: metadata.base_ref_name,
          head_ref_name: metadata.head_ref_name,
          head_repository: metadata.head_repository,
          is_cross_repository: metadata.is_cross_repository == true,
          pr_state: metadata.state,
          branch: branch,
          head_oid: head_oid,
          clock: -> { now }
        )
        Hive::AtomicFile.fsync_directory(staging_dir)
      end

      def rollback_claimed_creation!(hive_state_path:, project_root:, worktree_root:, claim_path:, owner_token:)
        Hive::Lock.with_commit_lock(hive_state_path) do
          claim = read_claim(claim_path)
          return unless claim && claim["owner_token"] == owner_token

          rollback_owned_resources!(
            project_root: project_root,
            worktree_root: worktree_root,
            claim: claim,
            strict: false
          )
          remove_claim_file!(claim_path, expected_token: owner_token)
        end
      rescue StandardError => e
        warn "[hive.review] ad-hoc ownership-checked rollback did not complete: #{e.class}: #{e.message}"
      ensure
        deregister_in_process_claim(claim_path, owner_token)
      end

      def rollback_owned_resources!(project_root:, worktree_root:, claim:, strict:)
        resources = claim["resources"].is_a?(Hash) ? claim["resources"] : {}
        issues = []

        if (staging = resources["staging_dir"])
          path = staging["path"].to_s
          if !path.empty? && File.exist?(path) && !File.symlink?(path) &&
             File.basename(path).end_with?(claim.fetch("owner_token"))
            FileUtils.rm_rf(path)
          end
        end

        if (wt = resources["worktree"])
          wt_path = wt["path"].to_s
          expected_branch = wt["branch"].to_s
          expected_oid = wt["oid"].to_s.downcase
          if !wt_path.empty? && (File.exist?(wt_path) || worktree_listed?(project_root, wt_path))
            if owned_worktree_matches?(project_root, wt_path, expected_branch: expected_branch, expected_oid: expected_oid)
              @gate.remove_materialization(
                repository_path: project_root,
                destination: wt_path,
                destination_root: worktree_root,
                force: true
              )
            else
              issues << "worktree #{wt_path} no longer matches claimed branch/OID"
            end
          end
        end

        if (br = resources["branch"])
          ref = br["ref"].to_s
          expected_oid = br["oid"].to_s.downcase
          if !ref.empty? && !expected_oid.empty?
            begin
              @gate.delete_ref_if_matches(
                repository_path: project_root, ref: ref, expected_oid: expected_oid
              )
            rescue Hive::AgentGitGate::Error => e
              issues << "branch #{ref} could not be removed safely (#{e.message})"
            end
          end
        end

        if (qr = resources["quarantine_ref"])
          ref = qr["ref"].to_s
          expected_oid = qr["oid"].to_s.downcase
          if !ref.empty? && !expected_oid.empty?
            begin
              @gate.delete_ref_if_matches(
                repository_path: project_root, ref: ref, expected_oid: expected_oid
              )
            rescue Hive::AgentGitGate::Error => e
              issues << "quarantine ref #{ref} could not be removed safely (#{e.message})"
            end
          end
        end

        return true if issues.empty?

        message = "ownership-checked cleanup left unexplained residue for #{claim['slug']}: #{issues.join('; ')}"
        raise Hive::WorktreeError, message if strict

        warn "[hive.review] #{message}"
        false
      end

      def owned_worktree_matches?(project_root, wt_path, expected_branch:, expected_oid:)
        return false unless worktree_listed?(project_root, wt_path)
        return true unless File.directory?(wt_path)

        br = @gate.read(wt_path, :current_branch)
        head = @gate.read(wt_path, :head_oid)
        br.success? && br.stdout.strip == expected_branch &&
          head.success? && head.stdout.strip.downcase == expected_oid
      rescue Hive::AgentGitGate::Error
        false
      end

      def cleanup_quarantine_ref_safely(project_root, quarantine_ref:, expected_oid:)
        @gate.delete_ref_if_matches(
          repository_path: project_root, ref: quarantine_ref, expected_oid: expected_oid
        )
      rescue Hive::AgentGitGate::Error => e
        warn "[hive.review] ad-hoc quarantine ref cleanup warning: #{e.message}"
      end

      def persist_claim_if_owned!(hive_state_path, claim_path, updated_claim)
        Hive::Lock.with_commit_lock(hive_state_path) do
          current = read_claim(claim_path)
          unless current && current["owner_token"] == updated_claim.fetch("owner_token")
            raise Hive::ConcurrentRunError.new("creation claim ownership lost", lock_path: claim_path)
          end
          write_claim!(claim_path, updated_claim)
        end
        updated_claim
      end

      def record_claim_resource!(hive_state_path, claim_path, claim, key, metadata)
        updated = claim.merge("resources" => claim.fetch("resources").merge(key => metadata))
        persist_claim_if_owned!(hive_state_path, claim_path, updated)
      end

      def write_claim!(claim_path, claim)
        dir = File.dirname(claim_path)
        FileUtils.mkdir_p(dir, mode: 0o700) unless File.directory?(dir)
        File.chmod(0o700, dir)
        Hive::AtomicFile.write(claim_path, "#{JSON.pretty_generate(claim)}\n", mode: 0o600, fsync: true)
        Hive::AtomicFile.fsync_directory(dir)
      end

      def read_claim(claim_path)
        return nil unless File.exist?(claim_path) || File.symlink?(claim_path)

        stat = File.lstat(claim_path)
        unless stat.file? && !stat.symlink?
          raise Hive::WorktreeError, "ad-hoc creation claim #{File.basename(claim_path)} is not a regular file"
        end
        raw = File.open(claim_path, File::RDONLY | File::NOFOLLOW) { |f| f.read(64 * 1024 + 1) || "" }
        raise Hive::WorktreeError, "ad-hoc creation claim exceeds bounded size" if raw.bytesize > 64 * 1024

        doc = JSON.parse(raw)
        unless doc.is_a?(Hash) && doc["schema"] == CLAIM_SCHEMA && doc["schema_version"] == 1 &&
               !doc["owner_token"].to_s.empty?
          raise Hive::WorktreeError, "ad-hoc creation claim is malformed"
        end
        doc
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError
        raise Hive::WorktreeError, "ad-hoc creation claim contains invalid JSON"
      end

      def remove_claim_file!(claim_path, expected_token:)
        current = read_claim(claim_path)
        return unless current && current["owner_token"] == expected_token

        File.unlink(claim_path)
        Hive::AtomicFile.fsync_directory(File.dirname(claim_path))
      rescue Errno::ENOENT
        nil
      end

      def register_in_process_claim(claim_path, owner_token)
        ACTIVE_CLAIMS_MUTEX.synchronize do
          ACTIVE_CLAIMS[File.expand_path(claim_path)] = {
            token: owner_token,
            thread: Thread.current
          }
        end
      end

      def deregister_in_process_claim(claim_path, owner_token)
        ACTIVE_CLAIMS_MUTEX.synchronize do
          key = File.expand_path(claim_path)
          ACTIVE_CLAIMS.delete(key) if ACTIVE_CLAIMS.dig(key, :token) == owner_token
        end
      end

      def claim_owner_alive?(claim_path, claim)
        pid = Integer(claim["pid"])
        if pid == Process.pid
          entry = ACTIVE_CLAIMS_MUTEX.synchronize { ACTIVE_CLAIMS[File.expand_path(claim_path)] }
          return !!(entry && entry[:token] == claim["owner_token"] && entry[:thread].alive?)
        end

        Process.kill(0, pid)
        live_start = Hive::Lock.process_start_time(pid)
        recorded_start = claim["process_start_time"]
        recorded_start.nil? || live_start.nil? || recorded_start == live_start
      rescue Errno::ESRCH, RangeError, ArgumentError, TypeError
        false
      rescue Errno::EPERM
        true
      end

      def allow_local_transport?(cfg)
        return @allow_local_transport == true unless @allow_local_transport.nil?

        cfg.is_a?(Hash) && cfg.dig("agent_git_gate", "allow_local_transport") == true
      end

      def network_timeout_sec(cfg)
        raw = cfg.is_a?(Hash) && (cfg.dig("gh", "network_timeout_sec") ||
                                  cfg.dig("agent_git_gate", "network_timeout_sec"))
        val = raw ? Float(raw, exception: false) : nil
        val&.positive? ? val : Hive::AgentGitGate::NETWORK_TIMEOUT_SEC
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
          "#{text}\n"
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

      def write_worktree_pointer(task_folder, worktree_path, branch, base_branch, head_oid, now)
        data = {
          "path" => worktree_path,
          "branch" => branch,
          "created_at" => now.utc.iso8601,
          "execute_base_head" => head_oid
        }
        data["base_branch"] = base_branch if base_branch && !base_branch.to_s.empty?
        Hive::AtomicFile.write(File.join(task_folder, "worktree.yml"), data.to_yaml, fsync: true)
      end

      def write_pr_md(task_folder, pr_number, pr_url, metadata, head_oid)
        data = {
          "pr_url" => pr_url,
          "pr_number" => pr_number,
          "source" => SOURCE,
          "base_ref_name" => metadata.base_ref_name,
          "head_oid" => head_oid,
          "is_cross_repository" => metadata.is_cross_repository == true,
          "state" => metadata.state
        }
        data["head_ref_name"] = metadata.head_ref_name if metadata.head_ref_name && !metadata.head_ref_name.to_s.empty?
        data["head_repository"] = metadata.head_repository if metadata.head_repository && !metadata.head_repository.to_s.empty?
        write_frontmatter_md(
          File.join(task_folder, "pr.md"),
          data,
          <<~MD
            ## Summary
            Ad-hoc review for PR ##{pr_number}.

            ## Base
            #{metadata.base_ref_name}
          MD
        )
      end

      def write_frontmatter_md(path, data, body)
        Hive::AtomicFile.write(path, "#{data.to_yaml}---\n\n#{body}", fsync: true)
      end

      def error_kind_for(error)
        case error
        when CollisionError then "destination_collision"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConcurrentRunError then "busy"
        else "error"
        end
      end
    end
  end
end
