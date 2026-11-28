require "fileutils"
require "securerandom"
require "time"
require "yaml"
require "hive/agent_git_gate"
require "hive/atomic_file"
require "hive/config"
require "hive/gh"
require "hive/lock"
require "hive/markers"
require "hive/stages/review/pass_archive"
require "hive/worktree"
require "hive/internal_pr_checkout/git_transition"
require "hive/internal_pr_checkout/identity"
require "hive/internal_pr_checkout/result"
require "hive/internal_pr_checkout/store"

module Hive
  module InternalPrCheckout
    # Single authoritative reconciliation service for existing Hive-owned
    # internal PR review tasks (`source: ad-hoc`).
    #
    # Owns applicability, strict identity validation, remote-head comparison,
    # interrupted transaction recovery, rollback/roll-forward around the final
    # provider linearization point, retirement/projection, and closed typed
    # outcomes (R1-R11, KTD1-KTD9).
    class Reconciler
      DEFAULT_NETWORK_TIMEOUT_SEC = Hive::AgentGitGate::NETWORK_TIMEOUT_SEC
      HEAD_BOUND_TASK_ROOT_FILES = %w[github-publication.json].freeze

      LocalState = Data.define(
        :identity,
        :config,
        :current,
        :pointer,
        :generation,
        :reviewed_oid,
        :head_oid,
        :candidate,
        :head_transition_digest,
        :remote_fingerprint,
        :stored_pr_observation
      )

      def initialize(
        gh: Hive::Gh,
        gate: Hive::AgentGitGate,
        clock: -> { Time.now.utc },
        monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        id_generator: -> { SecureRandom.hex(8) },
        config_loader: ->(root) { Hive::Config.load(root) },
        pass_archive: Hive::Stages::Review::PassArchive,
        allow_local_transport: nil,
        failpoint: nil
      )
        @gh = gh
        @gate = gate
        @clock = clock
        @monotonic = monotonic
        @id_generator = id_generator
        @config_loader = config_loader
        @pass_archive = pass_archive
        @allow_local_transport = allow_local_transport
        @failpoint = failpoint
      end

      # Reconcile an existing task under the SQLite task lease (or verify
      # locally when `mode: :local_verify`).
      #
      # Modes:
      # - `:explicit_reopen` — human/controller/queued explicit reopen:
      #   observes PR metadata within one monotonic deadline and transitions
      #   head-bound state if the remote PR head changed.
      # - `:local_verify` — worker / automatic continuation: zero provider I/O.
      #   Verifies local ownership/integrity, rolls forward confirmed pending
      #   transactions, and defers unconfirmed pending transactions with
      #   retryable `blocked/remote_observation_required`.
      def reconcile(task:, mode: :explicit_reopen, deadline: nil, timeout_sec: nil, lock_held: false)
        unless %i[explicit_reopen local_verify].include?(mode)
          raise ArgumentError, "unsupported reconcile mode: #{mode.inspect}"
        end

        return Result.not_applicable(task: task) unless Identity.applicable?(task)

        with_lease(task, lock_held: lock_held) do
          reconcile_under_lease(task: task, mode: mode, deadline: deadline, timeout_sec: timeout_sec)
        end
      rescue Hive::ConcurrentRunError => e
        Result.new(
          status: "busy",
          reason: "task_locked",
          retryable: true,
          task_slug: safe_task_slug(task),
          task_id: safe_task_id(task),
          guidance: e.message.empty? ? "task lease is held by another Hive process; retry shortly" : e.message
        )
      rescue Hive::RuntimeControlPlane::IdentityError, Errno::ENOENT => e
        Result.new(
          status: "blocked",
          reason: "sidecar_inconsistent",
          retryable: false,
          task_slug: safe_task_slug(task),
          task_id: safe_task_id(task),
          guidance: "task metadata or lease registration is invalid: #{e.message}"
        )
      rescue Error => e
        blocked_from_error(task, e)
      end

      # Record a controller-accepted clean candidate HEAD in `candidate.json`
      # without mutating `current.json` (preserving live worker generation).
      def record_candidate!(task:, head_oid:, pass:, kind:, worktree_path: nil)
        return nil unless Identity.applicable?(task)

        normalized_oid = head_oid.to_s.strip.downcase
        unless normalized_oid.match?(Identity::OID_PATTERN)
          raise Error.new("candidate_unproven", "candidate head OID is missing or invalid")
        end

        store = Store.new(task.folder)
        cfg = load_config(task.project_root)
        identity = Identity.resolve!(task, config: cfg, allow_legacy_head_ref_oid: !store.current_present?)
        current = store.read_current
        reviewed_oid = current ? current.fetch("reviewed_oid") : identity.pr_head_oid
        generation = @pass_archive.generation(task.folder)
        wt = worktree_path || identity.expected_worktree_path

        if normalized_oid != reviewed_oid
          anc = @gate.read(wt, :ancestor, base_oid: reviewed_oid, head_oid: normalized_oid)
          unless anc.success?
            raise Error.new(
              "candidate_unproven",
              "candidate HEAD #{normalized_oid[0, 12]} does not descend from reviewed OID #{reviewed_oid[0, 12]}"
            )
          end
        end

        doc = {
          "schema" => Store::CANDIDATE_SCHEMA,
          "schema_version" => 1,
          "task_id" => identity.task_id,
          "task_slug" => identity.task_slug,
          "project" => identity.project_name,
          "pr_host" => identity.pr_host,
          "pr_repository" => identity.pr_repository,
          "pr_number" => identity.pr_number,
          "pr_url" => identity.pr_url,
          "generation" => generation,
          "head_transition_digest" => current&.fetch("head_transition_digest", nil),
          "reviewed_oid" => reviewed_oid,
          "candidate_oid" => normalized_oid,
          "pass" => Integer(pass),
          "kind" => kind.to_s,
          "recorded_at" => @clock.call.utc.iso8601(6)
        }
        store.write_candidate!(doc)
      end

      private

      def with_lease(task, lock_held:, &block)
        return yield if lock_held

        Hive::Lock.with_task_lock(task.folder, op: "internal_pr_reconcile", create: false, &block)
      end

      def reconcile_under_lease(task:, mode:, deadline:, timeout_sec:)
        # R7 / AE6: Honor an active MANUAL_STEERING hold before recovery,
        # checkout mutation, network I/O, or admission.
        steering = check_manual_steering!(task)
        return steering if steering

        store = Store.new(task.folder)

        # R10 / R11: Any pending intent fences normal preflight and routes into
        # verified recovery before any new transition may begin.
        if store.pending_present?
          return recover_pending!(task, store: store, mode: mode, deadline: deadline, timeout_sec: timeout_sec)
        end

        local = preflight_local!(task, store: store)

        if mode == :local_verify
          return Result.new(
            status: "current",
            reason: "head_unchanged",
            retryable: false,
            task_slug: local.identity.task_slug,
            task_id: local.identity.task_id,
            pr_number: local.identity.pr_number,
            pr_url: local.identity.pr_url,
            generation: local.generation,
            head_oid: local.reviewed_oid,
            candidate_oid: local.head_oid,
            checkout_digest: local.head_transition_digest,
            pr_observation: local.stored_pr_observation,
            guidance: "local internal PR checkout verified at generation #{local.generation} (#{local.reviewed_oid[0, 12]})"
          )
        end

        effective_deadline = resolve_deadline(deadline: deadline, timeout_sec: timeout_sec, config: local.config)
        initial_obs = observe_provider_pr!(local.identity, config: local.config, deadline: effective_deadline)
        pr_obs_hash = observation_hash(initial_obs, local.identity)

        if initial_obs.head_ref_oid.to_s.downcase == local.reviewed_oid
          # AE1: Unchanged PR head is a strict zero-write no-op.
          return Result.new(
            status: "current",
            reason: "head_unchanged",
            retryable: false,
            task_slug: local.identity.task_slug,
            task_id: local.identity.task_id,
            pr_number: local.identity.pr_number,
            pr_url: local.identity.pr_url,
            generation: local.generation,
            head_oid: local.reviewed_oid,
            candidate_oid: local.head_oid,
            checkout_digest: local.head_transition_digest,
            pr_observation: pr_obs_hash.merge("generation" => local.generation),
            guidance: "PR ##{local.identity.pr_number} head #{local.reviewed_oid[0, 12]} is unchanged at generation #{local.generation}"
          )
        end

        execute_transition!(
          task: task,
          local: local,
          store: store,
          initial_obs: initial_obs,
          initial_obs_hash: pr_obs_hash,
          deadline: effective_deadline,
          recovered: false
        )
      end

      def check_manual_steering!(task)
        state_file = task.respond_to?(:state_file) ? task.state_file : File.join(task.folder, "task.md")
        return nil unless File.exist?(state_file) || File.symlink?(state_file)

        stat = File.lstat(state_file)
        if stat.symlink? || !stat.file?
          raise Error.new("sidecar_inconsistent", "#{File.basename(state_file)} must be a regular file")
        end

        bytes = File.open(state_file, File::RDONLY | File::NOFOLLOW) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise Error.new("sidecar_inconsistent", "#{File.basename(state_file)} changed while opening")
          end
          content = file.read(Identity::PR_FILE_MAX_BYTES + 1) || ""
          if content.bytesize > Identity::PR_FILE_MAX_BYTES
            raise Error.new("sidecar_inconsistent", "#{File.basename(state_file)} exceeds bounded read limit")
          end
          content
        end

        marker = Hive::Markers.current_from_content(bytes)
        return nil unless marker.name == :manual_steering

        Result.new(
          status: "busy",
          reason: "manual_steering",
          retryable: false,
          task_slug: safe_task_slug(task),
          task_id: safe_task_id(task),
          guidance: "MANUAL_STEERING is active for this task; end steering before reopening the PR review"
        )
      end

      def preflight_local!(task, store:)
        cfg = load_config(task.project_root)
        allow_legacy = !store.current_present?
        identity = Identity.resolve!(
          task, config: cfg, allow_legacy_head_ref_oid: allow_legacy,
          allow_local_transport: @allow_local_transport
        )

        validate_store_structure!(store, has_current: !allow_legacy)
        store.verify_history_integrity! if store.history_root_present?

        current = store.read_current
        validate_archive_directory_safety!(store, identity: identity, indexed: store.history_root_present?)
        live_ordinal = @pass_archive.generation(task.folder)

        if current
          validate_current_matches_identity!(current, identity: identity, live_ordinal: live_ordinal, store: store)
          reviewed_oid = current.fetch("reviewed_oid")
          head_transition_digest = current["head_transition_digest"]
        else
          reviewed_oid = identity.pr_head_oid
          head_transition_digest = nil
        end

        pointer = read_strict_pointer!(task.folder, identity: identity)
        validate_pointer_execute_base_head!(pointer, reviewed_oid: reviewed_oid, require_present: !current.nil?)

        verify_repository_configs!(identity)
        GitTransition.check_unexpected_git_locks!(
          identity.expected_worktree_path, branch: identity.expected_branch, gate: @gate
        )

        head_oid = verify_worktree_clean_and_attached!(identity)
        candidate = verify_candidate_provenance!(
          store: store,
          identity: identity,
          current: current,
          reviewed_oid: reviewed_oid,
          head_oid: head_oid,
          generation: live_ordinal
        )

        remote_fingerprint = Identity.validate_remote_identity!(identity, gate: @gate)
        stored_obs = stored_observation_from(current, identity, generation: live_ordinal)

        LocalState.new(
          identity: identity,
          config: cfg,
          current: current,
          pointer: pointer,
          generation: live_ordinal,
          reviewed_oid: reviewed_oid,
          head_oid: head_oid,
          candidate: candidate,
          head_transition_digest: head_transition_digest,
          remote_fingerprint: remote_fingerprint,
          stored_pr_observation: stored_obs
        )
      end

      def validate_store_structure!(store, has_current:)
        if File.exist?(store.store_dir) || File.symlink?(store.store_dir)
          stat = File.lstat(store.store_dir)
          unless stat.directory? && !stat.symlink?
            raise CustodyError.new("custody_mismatch", "internal-pr-checkout must be a real directory")
          end
        end
        if !has_current && store.history_root_present?
          raise Error.new("sidecar_inconsistent", "history-root.json exists without current.json")
        end
        if has_current && File.exist?(store.grant_index_path) && !store.history_root_present?
          raise CustodyError.new("custody_mismatch", "grant-index.json exists without history-root.json")
        end
      end

      def validate_archive_directory_safety!(store, identity:, indexed:)
        archive_dir = store.archive_dir
        return unless File.exist?(archive_dir) || File.symlink?(archive_dir)

        stat = File.lstat(archive_dir)
        unless stat.directory? && !stat.symlink?
          raise CustodyError.new("custody_mismatch", "reviews/archive must be a real directory")
        end

        return if indexed

        # Legacy unindexed archives: ensure no symlinks and check any existing
        # retirement.json does not contradict this task's PR identity.
        Dir.children(archive_dir).sort.each do |name|
          entry_path = File.join(archive_dir, name)
          entry_stat = File.lstat(entry_path)
          if entry_stat.symlink? || !entry_stat.directory?
            raise CustodyError.new("custody_mismatch", "reviews/archive/#{name} must be a real directory")
          end

          receipt_path = File.join(entry_path, Hive::Stages::Review::PassArchive::RETIREMENT_RECEIPT)
          next unless File.exist?(receipt_path) || File.symlink?(receipt_path)

          receipt_stat = File.lstat(receipt_path)
          if receipt_stat.symlink? || !receipt_stat.file?
            raise Error.new("sidecar_inconsistent", "legacy archive #{name} retirement.json is not a regular file")
          end
          raw = File.open(receipt_path, File::RDONLY | File::NOFOLLOW) { |f| f.read(Store::MAX_RECORD_BYTES + 1) || "" }
          if raw.bytesize > Store::MAX_RECORD_BYTES
            raise CustodyError.new("custody_limit_exceeded", "legacy archive #{name} retirement.json exceeds size limit")
          end
          parsed = JSON.parse(raw)
          unless parsed.is_a?(Hash)
            raise Error.new("sidecar_inconsistent", "legacy archive #{name} retirement.json is not a JSON object")
          end
          if parsed["pr_number"] && parsed["pr_number"].to_i != identity.pr_number
            raise Error.new("sidecar_inconsistent", "legacy archive #{name} retirement.json belongs to a different PR")
          end
          if parsed["pr_url"] && parsed["pr_url"].to_s != identity.pr_url
            raise Error.new("sidecar_inconsistent", "legacy archive #{name} retirement.json pr_url contradicts pr.md")
          end
        rescue JSON::ParserError
          raise Error.new("sidecar_inconsistent", "legacy archive #{name} retirement.json is malformed JSON")
        end
      end

      def validate_current_matches_identity!(current, identity:, live_ordinal:, store:)
        mismatches = []
        mismatches << "task_slug" unless current["task_slug"] == identity.task_slug
        mismatches << "task_id" if identity.task_id && current["task_id"] && current["task_id"] != identity.task_id
        mismatches << "project" unless current["project"] == identity.project_name
        mismatches << "pr_number" unless current["pr_number"] == identity.pr_number
        mismatches << "pr_url" unless current["pr_url"] == identity.pr_url
        mismatches << "pr_host" unless current["pr_host"] == identity.pr_host
        mismatches << "pr_repository" unless current["pr_repository"] == identity.pr_repository
        mismatches << "branch" unless current["branch"] == identity.expected_branch
        mismatches << "reviewed_oid" unless current["reviewed_oid"] == identity.pr_head_oid

        unless mismatches.empty?
          raise Error.new(
            "sidecar_inconsistent",
            "current.json disagrees with task/PR identity on: #{mismatches.join(', ')}"
          )
        end

        if live_ordinal < current.fetch("generation")
          raise Error.new(
            "sidecar_inconsistent",
            "PassArchive ordinal #{live_ordinal} is behind committed generation #{current.fetch('generation')}"
          )
        end

        if store.history_root_present?
          root = store.read_history_root
          unless root.fetch("next_ordinal") == live_ordinal
            raise CustodyError.new(
              "custody_mismatch",
              "sealed history next_ordinal #{root.fetch('next_ordinal')} does not match live PassArchive ordinal #{live_ordinal}"
            )
          end
        end
      end

      def read_strict_pointer!(task_folder, identity:, allow_detached: false)
        pointer_path = File.join(task_folder, "worktree.yml")
        unless File.exist?(pointer_path) || File.symlink?(pointer_path)
          raise Error.new("pointer_missing", "worktree.yml is missing for #{identity.task_slug}")
        end

        Hive::Worktree.read_owned_pointer(
          task_folder,
          project_root: identity.project_root,
          slug: identity.task_slug,
          expected_root: identity.expected_root,
          expected_path: identity.expected_worktree_path,
          expected_branch: identity.expected_branch,
          allow_detached: allow_detached
        )
      rescue Hive::WorktreeError => e
        raise Error.new(classify_worktree_error(e.message), e.message)
      end

      def classify_worktree_error(message)
        text = message.to_s
        return "pointer_missing" if text.include?("pointer is missing") || text.include?("worktree.yml is missing")
        return "checkout_detached" if text.include?('is on branch ""') || text.include?("detached")
        if text.include?("not valid YAML") || text.include?("invalid YAML") || text.include?("duplicate key") ||
           text.include?("must be a mapping") || text.include?("must be a hash") ||
           text.include?("must be a non-empty string") || text.include?("is missing keys") ||
           text.include?("exceeds") || text.include?("missing required")
          return "pointer_malformed"
        end
        "pointer_unowned"
      end

      def validate_pointer_execute_base_head!(pointer, reviewed_oid:, require_present:)
        base_head = pointer["execute_base_head"]
        if base_head.nil? || base_head.to_s.strip.empty?
          if require_present
            raise Error.new("sidecar_inconsistent", "worktree.yml is missing execute_base_head")
          end
          return true
        end

        normalized = base_head.to_s.strip.downcase
        unless normalized.match?(Identity::OID_PATTERN)
          raise Error.new("sidecar_inconsistent", "worktree.yml execute_base_head is malformed")
        end
        unless normalized == reviewed_oid
          raise Error.new(
            "sidecar_inconsistent",
            "worktree.yml execute_base_head #{normalized[0, 12]} disagrees with reviewed OID #{reviewed_oid[0, 12]}"
          )
        end
        true
      end

      def verify_repository_configs!(identity)
        @gate.verify_repository_config!(identity.project_root)
        @gate.verify_repository_config!(identity.expected_worktree_path)
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise Error.new("git_config_unsafe", e.message)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def verify_worktree_clean_and_attached!(identity)
        wt = identity.expected_worktree_path
        branch_res = @gate.read(wt, :current_branch)
        unless branch_res.success?
          raise Error.new("git_residue_unverifiable", "could not inspect worktree branch")
        end
        branch = branch_res.stdout.strip
        if branch.empty?
          raise Error.new("checkout_detached", "owned worktree is detached; expected branch #{identity.expected_branch}")
        end
        unless branch == identity.expected_branch
          raise Error.new("pointer_unowned", "owned worktree is on branch #{branch.inspect}, expected #{identity.expected_branch.inspect}")
        end

        status = @gate.read(wt, :status)
        unless status.success?
          raise Error.new("git_residue_unverifiable", "could not inspect worktree status")
        end
        unless status.stdout.empty?
          raise Error.new("checkout_dirty", "owned worktree has uncommitted or untracked changes")
        end

        head_res = @gate.read(wt, :head_oid)
        tip_res = @gate.read(wt, :branch_oid, branch: identity.expected_branch)
        unless head_res.success? && tip_res.success?
          raise Error.new("git_residue_unverifiable", "could not resolve owned worktree HEAD and branch ref")
        end
        head_oid = head_res.stdout.strip.downcase
        tip_oid = tip_res.stdout.strip.downcase
        unless head_oid.match?(Identity::OID_PATTERN) && head_oid == tip_oid
          raise Error.new("git_residue_unverifiable", "owned worktree HEAD and branch tip disagree")
        end
        head_oid
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def verify_candidate_provenance!(store:, identity:, current:, reviewed_oid:, head_oid:, generation:)
        candidate = store.read_candidate

        if head_oid == reviewed_oid
          if candidate
            validate_candidate_binding!(
              candidate,
              identity: identity,
              current: current,
              reviewed_oid: reviewed_oid,
              expected_candidate_oid: head_oid,
              generation: generation
            )
          end
          return candidate
        end

        # HEAD != reviewed_oid: check ancestry independently first.
        anc = @gate.read(
          identity.expected_worktree_path,
          :ancestor,
          base_oid: reviewed_oid,
          head_oid: head_oid
        )
        unless anc.success?
          if candidate
            raise Error.new(
              "candidate_unproven",
              "candidate receipt cannot prove HEAD #{head_oid[0, 12]} because it does not descend from reviewed OID #{reviewed_oid[0, 12]}"
            )
          end
          raise Error.new(
            "checkout_diverged",
            "worktree HEAD #{head_oid[0, 12]} diverged from reviewed PR head #{reviewed_oid[0, 12]}; preserve or restore local commits before reopening"
          )
        end

        # Clean descendant ahead of reviewed_oid: requires strict controller-owned
        # candidate receipt bound to this exact task, PR, generation, and OIDs.
        unless candidate
          raise Error.new(
            "candidate_unproven",
            "worktree HEAD #{head_oid[0, 12]} is ahead of reviewed OID #{reviewed_oid[0, 12]} without a verified Hive candidate receipt; preserve local commits before reopening"
          )
        end

        validate_candidate_binding!(
          candidate,
          identity: identity,
          current: current,
          reviewed_oid: reviewed_oid,
          expected_candidate_oid: head_oid,
          generation: generation
        )
        candidate
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def validate_candidate_binding!(candidate, identity:, current:, reviewed_oid:, expected_candidate_oid:, generation:)
        expected_digest = current&.fetch("head_transition_digest", nil)
        ok = candidate["candidate_oid"] == expected_candidate_oid &&
             candidate["reviewed_oid"] == reviewed_oid &&
             candidate["task_slug"] == identity.task_slug &&
             (identity.task_id.nil? || candidate["task_id"].nil? || candidate["task_id"] == identity.task_id) &&
             candidate["project"] == identity.project_name &&
             candidate["pr_number"] == identity.pr_number &&
             candidate["pr_url"] == identity.pr_url &&
             candidate["pr_host"] == identity.pr_host &&
             candidate["pr_repository"] == identity.pr_repository &&
             candidate["generation"] == generation &&
             candidate["head_transition_digest"] == expected_digest

        return true if ok

        raise Error.new(
          "candidate_unproven",
          "candidate.json binding does not match this task, PR, generation #{generation}, or HEAD #{expected_candidate_oid[0, 12]}"
        )
      end

      def execute_transition!(task:, local:, store:, initial_obs:, initial_obs_hash:, deadline:, recovered:)
        identity = local.identity
        tx_id = @id_generator.call
        old_generation = local.generation
        after_generation = old_generation + 1
        old_reviewed_oid = local.reviewed_oid
        old_candidate_oid = local.head_oid
        target_oid = initial_obs.head_ref_oid.to_s.downcase
        quarantine_ref = Identity.quarantine_ref_for(tx_id)
        candidate_archive_ref = Identity.candidate_archive_ref_for(
          pr_number: identity.pr_number,
          generation: old_generation,
          transaction_id: tx_id
        )
        retirement_label = Identity.retirement_label_for(transaction_id: tx_id, target_oid: target_oid)
        head_transition_digest = Store.head_transition_digest(
          pr_url: identity.pr_url,
          pr_number: identity.pr_number,
          branch: identity.expected_branch,
          reviewed_oid: target_oid,
          generation: after_generation,
          previous_generation: old_generation,
          retirement_label: retirement_label,
          transaction_id: tx_id
        )
        retirement_receipt = {
          "transaction_id" => tx_id,
          "pr_number" => identity.pr_number,
          "pr_url" => identity.pr_url,
          "previous_generation" => old_generation,
          "generation" => after_generation,
          "from_reviewed_oid" => old_reviewed_oid,
          "from_candidate_oid" => old_candidate_oid,
          "to_reviewed_oid" => target_oid,
          "candidate_archive_ref" => candidate_archive_ref
        }

        from_tree = GitTransition.capture_tree_snapshot(
          identity.expected_worktree_path, old_candidate_oid, gate: @gate
        )
        from_index = GitTransition.capture_index_snapshot(
          identity.expected_worktree_path, gate: @gate
        )

        now = @clock.call.utc.iso8601(6)
        pending = {
          "schema" => Store::PENDING_SCHEMA,
          "schema_version" => 1,
          "phase" => "prepared",
          "transaction_id" => tx_id,
          "task_id" => identity.task_id,
          "task_slug" => identity.task_slug,
          "project" => identity.project_name,
          "pr_host" => identity.pr_host,
          "pr_repository" => identity.pr_repository,
          "pr_number" => identity.pr_number,
          "pr_url" => identity.pr_url,
          "branch" => identity.expected_branch,
          "worktree_path" => identity.expected_worktree_path,
          "remote_fingerprint" => local.remote_fingerprint,
          "old_generation" => old_generation,
          "after_generation" => after_generation,
          "old_reviewed_oid" => old_reviewed_oid,
          "old_candidate_oid" => old_candidate_oid,
          "old_index_digest" => from_index.fetch(:digest),
          "target_oid" => target_oid,
          "quarantine_ref" => quarantine_ref,
          "candidate_archive_ref" => candidate_archive_ref,
          "candidate_archive_ref_created" => false,
          "retirement_label" => retirement_label,
          "retirement_receipt" => retirement_receipt,
          "head_transition_digest" => head_transition_digest,
          "initial_observation" => initial_obs_hash,
          "confirmed_observation" => nil,
          "owned_temp_paths" => [],
          "created_at" => now,
          "updated_at" => now
        }

        # Phase 1: Durable intent BEFORE fetch (R10 / KTD5).
        pending = store.write_pending!(pending)
        trigger_failpoint!(:after_prepared, pending)

        # Phase 2: Fetch exact OID into quarantine ref and preserve old candidate.
        begin
          @gate.fetch_pull_request_commit(
            repository_path: identity.expected_worktree_path,
            pr_number: identity.pr_number,
            expected_oid: target_oid,
            quarantine_ref: quarantine_ref,
            expected_remote_fingerprint: local.remote_fingerprint,
            allow_local_transport: identity.allow_local_transport,
            deadline: deadline
          )
        rescue Hive::AgentGitGate::RemoteConflict => e
          return handle_unconfirmed_failure!(
            pending: pending,
            identity: identity,
            store: store,
            reason: "remote_changed_before_linearization",
            retryable: true,
            guidance: "PR ##{identity.pr_number} moved before fetch completed (#{e.message}); retry reopen"
          )
        rescue Hive::AgentGitGate::DeadlineExceeded, Hive::AgentGitGate::CommandFailed => e
          return handle_unconfirmed_failure!(
            pending: pending,
            identity: identity,
            store: store,
            reason: "provider_unavailable",
            retryable: true,
            guidance: "could not fetch PR ##{identity.pr_number} head #{target_oid[0, 12]}: #{e.message}"
          )
        rescue Hive::AgentGitGate::InvalidRequest => e
          err = classify_gate_invalid_request(e)
          return handle_unconfirmed_failure!(
            pending: pending,
            identity: identity,
            store: store,
            reason: err.reason,
            retryable: false,
            guidance: err.guidance
          )
        end

        trigger_failpoint!(:after_fetch_before_fetched_journal, pending)

        @gate.ensure_immutable_ref(
          repository_path: identity.expected_worktree_path,
          ref: candidate_archive_ref,
          oid: old_candidate_oid
        )
        trigger_failpoint!(:after_candidate_archive_ref, pending)

        to_tree = GitTransition.capture_tree_snapshot(
          identity.expected_worktree_path, target_oid, gate: @gate
        )
        pending = store.write_pending!(
          pending.merge(
            "phase" => "fetched",
            "candidate_archive_ref_created" => true,
            "updated_at" => @clock.call.utc.iso8601(6)
          )
        )
        trigger_failpoint!(:after_fetched, pending)

        # Phase 3: Safe checkout transition (KTD9).
        begin
          GitTransition.transition_clean!(
            worktree_path: identity.expected_worktree_path,
            branch: identity.expected_branch,
            from_oid: old_candidate_oid,
            to_oid: target_oid,
            from_tree: from_tree,
            to_tree: to_tree,
            gate: @gate
          )
        rescue Error => e
          return handle_unconfirmed_failure!(
            pending: pending,
            identity: identity,
            store: store,
            reason: e.reason,
            retryable: e.retryable,
            guidance: e.guidance
          )
        end

        pending = store.write_pending!(
          pending.merge("phase" => "checked_out", "updated_at" => @clock.call.utc.iso8601(6))
        )
        trigger_failpoint!(:after_checked_out, pending)

        # Phase 4: Final provider observation (linearization point, R8 / AE8).
        confirm_and_commit!(
          task: task,
          identity: identity,
          store: store,
          pending: pending,
          config: local.config,
          deadline: deadline,
          recovered: recovered
        )
      end

      def confirm_and_commit!(task:, identity:, store:, pending:, deadline:, recovered:, config: nil)
        begin
          final_obs = observe_provider_pr!(identity, config: config, deadline: deadline)
        rescue Error => e
          return handle_unconfirmed_failure!(
            pending: pending,
            identity: identity,
            store: store,
            reason: e.reason,
            retryable: e.retryable,
            guidance: e.guidance
          )
        end

        observed_oid = final_obs.head_ref_oid.to_s.downcase
        unless observed_oid == pending.fetch("target_oid") &&
               final_obs.number == identity.pr_number &&
               final_obs.url == identity.pr_url
          return handle_unconfirmed_failure!(
            pending: pending,
            identity: identity,
            store: store,
            reason: "remote_changed_before_linearization",
            retryable: true,
            guidance: "PR ##{identity.pr_number} moved to #{observed_oid[0, 12]} before final confirmation; prior checkout restored, retry reopen"
          )
        end

        confirmed_obs = observation_hash(final_obs, identity)
        pending = store.write_pending!(
          pending.merge(
            "phase" => "confirmed",
            "confirmed_observation" => confirmed_obs,
            "updated_at" => @clock.call.utc.iso8601(6)
          )
        )
        trigger_failpoint!(:after_confirmed, pending)

        roll_forward_confirmed!(
          task: task,
          identity: identity,
          store: store,
          pending: pending,
          recovered: recovered
        )
      end

      def roll_forward_confirmed!(task:, identity:, store:, pending:, recovered:)
        tx_id = pending.fetch("transaction_id")
        target_oid = pending.fetch("target_oid")
        old_reviewed_oid = pending.fetch("old_reviewed_oid")
        old_generation = pending.fetch("old_generation")
        after_generation = pending.fetch("after_generation")
        label = pending.fetch("retirement_label")
        confirmed = pending.fetch("confirmed_observation")

        already_published = store.current_present? &&
                            store.read_current["transaction_id"] == tx_id

        unless already_published
          # Phase 5: Archive active generation, expire grants once, seal manifest.
          unless %w[archived projected].include?(pending["phase"])
            ensure_reviews_directory!(task.folder)
            @pass_archive.retire!(
              task,
              label: label,
              expiry_reason: "internal_pr_head_changed",
              receipt: pending.fetch("retirement_receipt"),
              exact_label: true,
              prior_labels: store.sealed_labels,
              failpoint: @failpoint
            )
            trigger_failpoint!(:after_pass_archive_retire, pending)

            archive_remaining_head_bound_state!(task: task, store: store, label: label, pending: pending)

            _root, history_root_digest = store.seal_retirement!(label: label)
            pending = store.write_pending!(
              pending.merge(
                "phase" => "archived",
                "history_root_digest" => history_root_digest,
                "updated_at" => @clock.call.utc.iso8601(6)
              )
            )
            trigger_failpoint!(:after_archived, pending)
          end

          # Phase 6: Atomic projections (pr.md, worktree.yml, selective REVIEW_* strip).
          unless pending["phase"] == "projected"
            project_pr_metadata!(task.folder, identity: identity, confirmed: confirmed, target_oid: target_oid)
            project_worktree_pointer!(task.folder, identity: identity, target_oid: target_oid, base_ref_name: confirmed["base_ref_name"])
            strip_review_markers!(task)

            pending = store.write_pending!(
              pending.merge("phase" => "projected", "updated_at" => @clock.call.utc.iso8601(6))
            )
            trigger_failpoint!(:after_projected, pending)
          end

          # Phase 7: Atomic current.json publication LAST (KTD4 / R9).
          history_root_digest = pending["history_root_digest"] || store.history_root_sha256
          current_doc = {
            "schema" => Store::CURRENT_SCHEMA,
            "schema_version" => 1,
            "task_id" => identity.task_id,
            "task_slug" => identity.task_slug,
            "project" => identity.project_name,
            "pr_host" => identity.pr_host,
            "pr_repository" => identity.pr_repository,
            "pr_number" => identity.pr_number,
            "pr_url" => identity.pr_url,
            "base_ref_name" => confirmed["base_ref_name"] || identity.base_ref_name,
            "head_ref_name" => confirmed["head_ref_name"] || identity.head_ref_name,
            "head_repository" => confirmed["head_repository"] || identity.head_repository,
            "is_cross_repository" => confirmed["is_cross_repository"] == true,
            "pr_state" => confirmed["state"].to_s.upcase,
            "branch" => identity.expected_branch,
            "reviewed_oid" => target_oid,
            "candidate_oid" => target_oid,
            "generation" => after_generation,
            "previous_generation" => old_generation,
            "previous_reviewed_oid" => old_reviewed_oid,
            "retirement_label" => label,
            "candidate_archive_ref" => pending.fetch("candidate_archive_ref"),
            "transaction_id" => tx_id,
            "head_transition_digest" => pending.fetch("head_transition_digest"),
            "history_root_digest" => history_root_digest,
            "committed_at" => @clock.call.utc.iso8601(6)
          }
          store.write_current!(current_doc)
          trigger_failpoint!(:after_current_published, pending)
        end

        # Verify committed current record & history before deleting quarantine ref
        # and clearing pending intent.
        published = store.read_current
        unless published && published["transaction_id"] == tx_id && published["reviewed_oid"] == target_oid
          raise Error.new("sidecar_inconsistent", "published current.json could not be verified")
        end
        store.verify_history_integrity!

        cleanup_ref_if_matches!(
          identity.expected_worktree_path,
          ref_name: pending.fetch("quarantine_ref"),
          expected_oid: target_oid
        )
        trigger_failpoint!(:after_quarantine_cleanup, pending)

        store.clear_pending!

        Result.new(
          status: "reopened",
          reason: recovered ? "pending_recovered_reopened" : "head_changed",
          retryable: false,
          task_slug: identity.task_slug,
          task_id: identity.task_id,
          pr_number: identity.pr_number,
          pr_url: identity.pr_url,
          generation: after_generation,
          head_oid: target_oid,
          previous_head_oid: old_reviewed_oid,
          candidate_oid: target_oid,
          checkout_digest: pending.fetch("head_transition_digest"),
          transaction_id: tx_id,
          pr_observation: confirmed.merge("generation" => after_generation),
          guidance: "PR ##{identity.pr_number} moved from #{old_reviewed_oid[0, 12]} to #{target_oid[0, 12]}; started generation #{after_generation}"
        )
      end

      def recover_pending!(task, store:, mode:, deadline:, timeout_sec:)
        pending = store.read_pending
        cfg = load_config(task.project_root)
        identity = validate_pending_against_task!(task, pending: pending, store: store, config: cfg)

        # Already published current.json for this exact transaction -> finish cleanup
        # with zero provider I/O in both modes.
        if store.current_present? && store.read_current["transaction_id"] == pending.fetch("transaction_id")
          GitTransition.verify_clean_at!(
            identity.expected_worktree_path,
            branch: identity.expected_branch,
            expected_oid: pending.fetch("target_oid"),
            gate: @gate
          )
          return roll_forward_confirmed!(
            task: task,
            identity: identity,
            store: store,
            pending: pending,
            recovered: true
          )
        end

        # Confirmed phases always roll forward deterministically with zero provider I/O.
        if %w[confirmed archived projected].include?(pending.fetch("phase"))
          GitTransition.verify_and_converge!(
            worktree_path: identity.expected_worktree_path,
            branch: identity.expected_branch,
            from_oid: pending.fetch("old_candidate_oid"),
            to_oid: pending.fetch("target_oid"),
            dest_oid: pending.fetch("target_oid"),
            owned_temp_paths: pending["owned_temp_paths"],
            gate: @gate
          )
          @gate.ensure_immutable_ref(
            repository_path: identity.expected_worktree_path,
            ref: pending.fetch("candidate_archive_ref"),
            oid: pending.fetch("old_candidate_oid")
          )
          return roll_forward_confirmed!(
            task: task,
            identity: identity,
            store: store,
            pending: pending,
            recovered: true
          )
        end

        # Unconfirmed phases (`prepared`, `fetched`, `checked_out`):
        # Automatic continuations (`:local_verify`) cannot query GitHub and must
        # never silently discard pending state.
        if mode == :local_verify
          return Result.new(
            status: "blocked",
            reason: "remote_observation_required",
            retryable: true,
            task_slug: identity.task_slug,
            task_id: identity.task_id,
            pr_number: identity.pr_number,
            pr_url: identity.pr_url,
            generation: pending.fetch("old_generation"),
            head_oid: pending.fetch("old_reviewed_oid"),
            candidate_oid: pending.fetch("old_candidate_oid"),
            transaction_id: pending.fetch("transaction_id"),
            guidance: "unconfirmed internal PR checkout transition requires an explicit reopen with provider observation"
          )
        end

        effective_deadline = resolve_deadline(deadline: deadline, timeout_sec: timeout_sec, config: cfg)
        live_obs = observe_provider_pr!(identity, config: cfg, deadline: effective_deadline)
        live_obs_hash = observation_hash(live_obs, identity)
        live_oid = live_obs.head_ref_oid.to_s.downcase

        if live_oid == pending.fetch("target_oid")
          # Reuse this transaction identity, quarantine ref, and retirement label (R10).
          return resume_unconfirmed_same_target!(
            task: task,
            identity: identity,
            store: store,
            pending: pending,
            config: cfg,
            deadline: effective_deadline
          )
        end

        # Remote head moved again (or reverted to old_reviewed_oid) while unconfirmed.
        # Safely roll back and clean up this transaction's proven effects first.
        rollback_unconfirmed!(pending: pending, identity: identity, store: store)

        if live_oid == pending.fetch("old_reviewed_oid")
          local = preflight_local!(task, store: store)
          return Result.new(
            status: "current",
            reason: "pending_recovered_current",
            retryable: false,
            task_slug: local.identity.task_slug,
            task_id: local.identity.task_id,
            pr_number: local.identity.pr_number,
            pr_url: local.identity.pr_url,
            generation: local.generation,
            head_oid: local.reviewed_oid,
            candidate_oid: local.head_oid,
            checkout_digest: local.head_transition_digest,
            pr_observation: live_obs_hash.merge("generation" => local.generation),
            guidance: "recovered interrupted transition back to unchanged PR head #{local.reviewed_oid[0, 12]} (generation #{local.generation})"
          )
        end

        # Start a clean transaction for the new live head from the verified
        # committed baseline.
        local = preflight_local!(task, store: store)
        execute_transition!(
          task: task,
          local: local,
          store: store,
          initial_obs: live_obs,
          initial_obs_hash: live_obs_hash,
          deadline: effective_deadline,
          recovered: true
        )
      end

      def resume_unconfirmed_same_target!(task:, identity:, store:, pending:, deadline:, config: nil)
        wt = identity.expected_worktree_path
        target_oid = pending.fetch("target_oid")
        old_candidate_oid = pending.fetch("old_candidate_oid")
        quarantine_ref = pending.fetch("quarantine_ref")
        candidate_archive_ref = pending.fetch("candidate_archive_ref")

        q_res = @gate.read(wt, :ref_oid, ref: quarantine_ref)
        if q_res.success?
          actual_q = q_res.stdout.strip.downcase
          unless actual_q == target_oid
            raise Error.new(
              "git_residue_unverifiable",
              "quarantine ref #{quarantine_ref} points to #{actual_q[0, 12]} instead of expected #{target_oid[0, 12]}"
            )
          end
        else
          begin
            @gate.fetch_pull_request_commit(
              repository_path: wt,
              pr_number: identity.pr_number,
              expected_oid: target_oid,
              quarantine_ref: quarantine_ref,
              expected_remote_fingerprint: pending.fetch("remote_fingerprint"),
              allow_local_transport: identity.allow_local_transport,
              deadline: deadline
            )
          rescue Hive::AgentGitGate::RemoteConflict => e
            return handle_unconfirmed_failure!(
              pending: pending,
              identity: identity,
              store: store,
              reason: "remote_changed_before_linearization",
              retryable: true,
              guidance: "PR ##{identity.pr_number} moved before recovery fetch completed (#{e.message}); retry reopen"
            )
          rescue Hive::AgentGitGate::DeadlineExceeded, Hive::AgentGitGate::CommandFailed => e
            return Result.new(
              status: "blocked",
              reason: "provider_unavailable",
              retryable: true,
              task_slug: identity.task_slug,
              task_id: identity.task_id,
              pr_number: identity.pr_number,
              pr_url: identity.pr_url,
              generation: pending.fetch("old_generation"),
              head_oid: pending.fetch("old_reviewed_oid"),
              transaction_id: pending.fetch("transaction_id"),
              guidance: "could not fetch PR ##{identity.pr_number} during recovery: #{e.message}"
            )
          end
        end

        @gate.ensure_immutable_ref(
          repository_path: wt,
          ref: candidate_archive_ref,
          oid: old_candidate_oid
        )
        if pending["phase"] == "prepared"
          pending = store.write_pending!(
            pending.merge(
              "phase" => "fetched",
              "candidate_archive_ref_created" => true,
              "updated_at" => @clock.call.utc.iso8601(6)
            )
          )
        end

        begin
          GitTransition.verify_and_converge!(
            worktree_path: wt,
            branch: identity.expected_branch,
            from_oid: old_candidate_oid,
            to_oid: target_oid,
            dest_oid: target_oid,
            owned_temp_paths: pending["owned_temp_paths"],
            gate: @gate
          )
        rescue Error => e
          return Result.new(
            status: "blocked",
            reason: e.reason,
            retryable: e.retryable,
            task_slug: identity.task_slug,
            task_id: identity.task_id,
            pr_number: identity.pr_number,
            pr_url: identity.pr_url,
            generation: pending.fetch("old_generation"),
            head_oid: pending.fetch("old_reviewed_oid"),
            transaction_id: pending.fetch("transaction_id"),
            guidance: e.guidance
          )
        end

        if pending["phase"] != "checked_out"
          pending = store.write_pending!(
            pending.merge("phase" => "checked_out", "updated_at" => @clock.call.utc.iso8601(6))
          )
        end

        confirm_and_commit!(
          task: task,
          identity: identity,
          store: store,
          pending: pending,
          config: config,
          deadline: deadline,
          recovered: true
        )
      end

      def validate_pending_against_task!(task, pending:, store:, config:)
        slug = safe_task_slug(task)
        task_id = safe_task_id(task)
        project_name = Identity.project_name_for(task.project_root, task: task)
        pr_number = pending.fetch("pr_number")
        expected_slug = Identity.slug_for(pr_number)
        expected_branch = Identity.branch_for(pr_number)
        expected_wt = Identity.worktree_path_for(task.project_root, expected_slug, config: config)
        expected_candidate_ref = Identity.candidate_archive_ref_for(
          pr_number: pr_number,
          generation: pending.fetch("old_generation"),
          transaction_id: pending.fetch("transaction_id")
        )
        expected_digest = Store.head_transition_digest(
          pr_url: pending.fetch("pr_url"),
          pr_number: pr_number,
          branch: expected_branch,
          reviewed_oid: pending.fetch("target_oid"),
          generation: pending.fetch("after_generation"),
          previous_generation: pending.fetch("old_generation"),
          retirement_label: pending.fetch("retirement_label"),
          transaction_id: pending.fetch("transaction_id")
        )

        unless pending["task_slug"] == slug &&
               slug == expected_slug &&
               (task_id.nil? || pending["task_id"].nil? || pending["task_id"] == task_id) &&
               pending["project"] == project_name &&
               pending["worktree_path"] == expected_wt &&
               pending["branch"] == expected_branch &&
               pending["candidate_archive_ref"] == expected_candidate_ref &&
               pending["head_transition_digest"] == expected_digest
          raise PendingInvalid, "pending.json identity or containment does not match task #{slug}"
        end

        allow_legacy = !store.current_present?
        identity = Identity.resolve!(
          task, config: config, allow_legacy_head_ref_oid: allow_legacy,
          allow_local_transport: @allow_local_transport
        )
        unless identity.pr_number == pr_number &&
               identity.pr_url == pending.fetch("pr_url") &&
               identity.pr_host == pending.fetch("pr_host") &&
               identity.pr_repository == pending.fetch("pr_repository")
          raise PendingInvalid, "pending.json PR identity disagrees with pr.md"
        end

        allowed_pr_oids = [ pending.fetch("old_reviewed_oid") ]
        if pending["phase"] == "projected" ||
           (store.current_present? && store.read_current["transaction_id"] == pending.fetch("transaction_id"))
          allowed_pr_oids << pending.fetch("target_oid")
        end
        unless allowed_pr_oids.include?(identity.pr_head_oid)
          raise PendingInvalid, "pr.md head_oid disagrees with pending transaction phase #{pending['phase']}"
        end

        read_strict_pointer!(task.folder, identity: identity, allow_detached: true)
        verify_repository_configs!(identity)

        actual_fp = Identity.validate_remote_identity!(identity, gate: @gate)
        unless actual_fp == pending.fetch("remote_fingerprint")
          raise Error.new("remote_identity_invalid", "origin remote fingerprint changed during pending transition")
        end

        identity
      end

      def handle_unconfirmed_failure!(pending:, identity:, store:, reason:, retryable:, guidance:)
        begin
          rollback_unconfirmed!(pending: pending, identity: identity, store: store)
        rescue Error => rollback_err
          # AE8: If rollback is obstructed (e.g. operator wrote an obstructing
          # file or third tracked state), preserve those bytes and keep
          # pending.json fenced!
          return Result.new(
            status: "blocked",
            reason: rollback_err.reason,
            retryable: false,
            task_slug: identity.task_slug,
            task_id: identity.task_id,
            pr_number: identity.pr_number,
            pr_url: identity.pr_url,
            generation: pending.fetch("old_generation"),
            head_oid: pending.fetch("old_reviewed_oid"),
            candidate_oid: pending.fetch("old_candidate_oid"),
            transaction_id: pending.fetch("transaction_id"),
            guidance: "rollback fenced after #{reason}: #{rollback_err.guidance}"
          )
        end

        Result.new(
          status: "blocked",
          reason: reason,
          retryable: retryable,
          task_slug: identity.task_slug,
          task_id: identity.task_id,
          pr_number: identity.pr_number,
          pr_url: identity.pr_url,
          generation: pending.fetch("old_generation"),
          head_oid: pending.fetch("old_reviewed_oid"),
          candidate_oid: pending.fetch("old_candidate_oid"),
          transaction_id: pending.fetch("transaction_id"),
          guidance: guidance
        )
      end

      def rollback_unconfirmed!(pending:, identity:, store:)
        wt = identity.expected_worktree_path
        branch = identity.expected_branch
        old_candidate_oid = pending.fetch("old_candidate_oid")
        target_oid = pending.fetch("target_oid")
        quarantine_ref = pending.fetch("quarantine_ref")
        candidate_archive_ref = pending.fetch("candidate_archive_ref")

        trigger_failpoint!(:before_rollback_checkout, pending)

        if target_object_present?(wt, target_oid)
          GitTransition.verify_and_converge!(
            worktree_path: wt,
            branch: branch,
            from_oid: old_candidate_oid,
            to_oid: target_oid,
            dest_oid: old_candidate_oid,
            owned_temp_paths: pending["owned_temp_paths"],
            gate: @gate
          )
        else
          GitTransition.check_unexpected_git_locks!(
            wt, branch: branch, owned_temp_paths: pending["owned_temp_paths"], gate: @gate
          )
          GitTransition.verify_clean_at!(wt, branch: branch, expected_oid: old_candidate_oid, gate: @gate)
        end

        cleanup_ref_if_matches!(wt, ref_name: quarantine_ref, expected_oid: target_oid)
        cleanup_ref_if_matches!(wt, ref_name: candidate_archive_ref, expected_oid: old_candidate_oid)
        store.clear_pending!
        true
      end

      def target_object_present?(worktree_path, oid)
        res = @gate.read(worktree_path, :tree_entries, oid: oid)
        res.success?
      rescue Hive::AgentGitGate::Error
        false
      end

      def cleanup_ref_if_matches!(worktree_path, ref_name:, expected_oid:)
        @gate.delete_ref_if_matches(
          repository_path: worktree_path,
          ref: ref_name,
          expected_oid: expected_oid
        )
      rescue Hive::AgentGitGate::InvalidRequest => e
        raise classify_gate_invalid_request(e)
      rescue Hive::AgentGitGate::Error => e
        raise Error.new("git_residue_unverifiable", e.message)
      end

      def ensure_reviews_directory!(task_folder)
        reviews = File.join(task_folder, "reviews")
        if File.exist?(reviews) || File.symlink?(reviews)
          stat = File.lstat(reviews)
          unless stat.directory? && !stat.symlink?
            raise CustodyError.new("custody_mismatch", "reviews must be a real directory")
          end
          return reviews
        end

        Dir.mkdir(reviews, 0o700)
        Hive::AtomicFile.fsync_directory(task_folder)
        reviews
      end

      def archive_remaining_head_bound_state!(task:, store:, label:, pending:)
        archive_target = File.join(store.archive_dir, label)
        head_state_dir = File.join(archive_target, "head-state")

        # 1. Retain original state file (including prior review markers) and pr.md
        #    bytes write-once before projections mutate them.
        state_file = task.respond_to?(:state_file) ? task.state_file : File.join(task.folder, "task.md")
        snapshot_file_once!(state_file, File.join(head_state_dir, "state-file-before.md"))
        snapshot_file_once!(File.join(task.folder, "pr.md"), File.join(head_state_dir, "pr-before.md"))

        # 2. Retain active candidate.json evidence and clear it for the new head.
        if store.candidate_present?
          move_file_idempotent!(store.candidate_path, File.join(head_state_dir, "candidate.json"))
        end

        # 3. Move task-root head-bound receipts (e.g. github-publication.json).
        HEAD_BOUND_TASK_ROOT_FILES.each do |filename|
          source = File.join(task.folder, filename)
          next unless File.exist?(source) || File.symlink?(source)

          move_file_idempotent!(source, File.join(head_state_dir, filename))
        end

        # 4. Move EVERY remaining entry in `reviews/` other than `archive/` into
        #    `reviews/archive/<label>/` so active flat `reviews/` is empty.
        reviews = store.reviews_dir
        remaining = Dir.children(reviews).reject { |name| name == Hive::Stages::Review::PassArchive::ARCHIVE_DIR }.sort
        moved_any = false
        remaining.each do |name|
          source = File.join(reviews, name)
          dest = File.join(archive_target, name)
          if File.exist?(dest) || File.symlink?(dest)
            raise CustodyError.new("custody_mismatch", "conflicting entry #{name.inspect} already exists in archive #{label}")
          end
          File.rename(source, dest)
          unless moved_any
            moved_any = true
            trigger_failpoint!(:after_partial_head_moves, pending)
          end
        end

        Hive::AtomicFile.fsync_directory(head_state_dir) if File.directory?(head_state_dir)
        Hive::AtomicFile.fsync_directory(archive_target)
        Hive::AtomicFile.fsync_directory(reviews)
      end

      def snapshot_file_once!(source, dest)
        return unless File.file?(source) && !File.symlink?(source)
        return if File.exist?(dest) || File.symlink?(dest)

        ensure_directory_no_follow!(File.dirname(dest))
        bytes = File.open(source, File::RDONLY | File::NOFOLLOW, &:read)
        Hive::AtomicFile.create(dest, bytes, mode: 0o600, fsync: true)
      rescue Errno::EEXIST
        nil
      end

      def move_file_idempotent!(source, dest)
        stat = File.lstat(source)
        unless stat.file? && !stat.symlink?
          raise CustodyError.new("custody_mismatch", "#{File.basename(source)} must be a regular file")
        end

        ensure_directory_no_follow!(File.dirname(dest))
        bytes = File.open(source, File::RDONLY | File::NOFOLLOW, &:read)
        if File.exist?(dest) || File.symlink?(dest)
          dest_bytes = File.open(dest, File::RDONLY | File::NOFOLLOW, &:read)
          unless dest_bytes == bytes
            raise CustodyError.new("custody_mismatch", "conflicting archived copy of #{File.basename(source)}")
          end
        else
          Hive::AtomicFile.write(dest, bytes, mode: 0o600, fsync: true)
        end
        File.unlink(source)
        Hive::AtomicFile.fsync_directory(File.dirname(source))
      end

      def ensure_directory_no_follow!(dir)
        if File.exist?(dir) || File.symlink?(dir)
          stat = File.lstat(dir)
          unless stat.directory? && !stat.symlink?
            raise CustodyError.new("custody_mismatch", "#{File.basename(dir)} must be a real directory")
          end
          return dir
        end

        Dir.mkdir(dir, 0o700)
        Hive::AtomicFile.fsync_directory(File.dirname(dir))
        dir
      end

      def project_pr_metadata!(task_folder, identity:, confirmed:, target_oid:)
        pr_path = File.join(task_folder, "pr.md")
        attrs = {
          "source" => Identity::SOURCE,
          "pr_number" => identity.pr_number,
          "state" => confirmed["state"].to_s.upcase,
          "is_cross_repository" => confirmed["is_cross_repository"] == true
        }
        attrs["base_ref_name"] = confirmed["base_ref_name"] if confirmed["base_ref_name"]
        attrs["head_ref_name"] = confirmed["head_ref_name"] if confirmed["head_ref_name"]
        attrs["head_repository"] = confirmed["head_repository"] if confirmed["head_repository"]

        Hive::Gh.persist_pr_identity!(
          pr_path,
          pr_url: identity.pr_url,
          pr_number: identity.pr_number,
          head_oid: target_oid,
          attributes: attrs
        )
      end

      def project_worktree_pointer!(task_folder, identity:, target_oid:, base_ref_name:)
        pointer_path = File.join(task_folder, "worktree.yml")
        data = read_strict_pointer!(task_folder, identity: identity)
        data["execute_base_head"] = target_oid
        data["base_branch"] = base_ref_name if base_ref_name && !base_ref_name.to_s.empty?
        Hive::AtomicFile.write(pointer_path, YAML.dump(data), fsync: true)
        Hive::AtomicFile.fsync_directory(task_folder)
      end

      def strip_review_markers!(task)
        state_file = task.respond_to?(:state_file) ? task.state_file : File.join(task.folder, "task.md")
        return unless File.exist?(state_file)

        result = Hive::Markers.remove_named_markers(
          state_file,
          Hive::Markers::REVIEW_MARKER_NAMES,
          refuse_if_current: [ :manual_steering ]
        )
        if result == :refused
          raise Error.new("sidecar_inconsistent", "MANUAL_STEERING appeared during review marker rewrite")
        end
        Hive::AtomicFile.fsync_directory(File.dirname(state_file))
      end

      def observe_provider_pr!(identity, config: nil, deadline:)
        remaining = remaining_budget(deadline)
        unless remaining.positive?
          raise Error.new(
            "provider_unavailable",
            "reopen network deadline expired before observing PR ##{identity.pr_number}",
            retryable: true
          )
        end

        meta = @gh.validated_pr_metadata(
          identity.pr_number,
          expected_host: identity.pr_host,
          expected_repository: identity.pr_repository,
          cfg: config,
          chdir: identity.project_root,
          deadline: deadline
        )
        unless meta.number == identity.pr_number && meta.url == identity.pr_url
          raise Error.new(
            "remote_identity_invalid",
            "provider returned PR #{meta.url} instead of expected #{identity.pr_url}"
          )
        end
        meta
      rescue Hive::GhError => e
        if e.message.include?("does not match") || e.message.include?("non-canonical") ||
           e.message.include?("invalid") || e.message.include?("unsupported")
          raise Error.new("remote_identity_invalid", e.message, retryable: false)
        end
        raise Error.new("provider_unavailable", e.message, retryable: true)
      rescue Hive::AgentGitGate::DeadlineExceeded => e
        raise Error.new("provider_unavailable", e.message, retryable: true)
      end

      def observation_hash(meta, identity)
        {
          "number" => meta.number,
          "url" => meta.url,
          "pr_number" => meta.number,
          "pr_url" => meta.url,
          "pr_host" => identity.pr_host,
          "pr_repository" => identity.pr_repository,
          "state" => meta.state.to_s.upcase,
          "head_oid" => meta.head_ref_oid.to_s.downcase,
          "base_ref_name" => meta.base_ref_name,
          "head_ref_name" => meta.head_ref_name,
          "head_repository" => meta.head_repository,
          "is_cross_repository" => meta.is_cross_repository == true,
          "observed_at" => @clock.call.utc.iso8601(6)
        }
      end

      def stored_observation_from(current, identity, generation:)
        state = current&.dig("pr_state") || identity.pr_state
        return nil unless state

        {
          "number" => identity.pr_number,
          "url" => identity.pr_url,
          "pr_number" => identity.pr_number,
          "pr_url" => identity.pr_url,
          "pr_host" => identity.pr_host,
          "pr_repository" => identity.pr_repository,
          "state" => state,
          "head_oid" => current ? current.fetch("reviewed_oid") : identity.pr_head_oid,
          "base_ref_name" => current&.dig("base_ref_name") || identity.base_ref_name,
          "head_ref_name" => current&.dig("head_ref_name") || identity.head_ref_name,
          "head_repository" => current&.dig("head_repository") || identity.head_repository,
          "is_cross_repository" => current ? current["is_cross_repository"] == true : identity.is_cross_repository,
          "generation" => generation,
          "observed_at" => current&.dig("committed_at")
        }
      end

      def resolve_deadline(deadline:, timeout_sec:, config:)
        return deadline.to_f if deadline

        seconds = timeout_sec || configured_network_timeout(config)
        @monotonic.call + Float(seconds)
      end

      def remaining_budget(deadline)
        deadline.to_f - @monotonic.call
      end

      def configured_network_timeout(config)
        raw = config.is_a?(Hash) && (config.dig("review", "reconcile_timeout_sec") ||
                                     config.dig("agent_git_gate", "network_timeout_sec"))
        val = raw ? Float(raw, exception: false) : nil
        val&.positive? ? val : DEFAULT_NETWORK_TIMEOUT_SEC
      end

      def load_config(project_root)
        @config_loader.call(project_root)
      rescue Hive::ConfigError => e
        raise Error.new("sidecar_inconsistent", "project config could not be loaded: #{e.message}")
      end

      def classify_gate_invalid_request(error)
        if error.message.include?("executable Git helpers") || error.message.include?("could not be inspected safely")
          Error.new("git_config_unsafe", error.message)
        elsif error.message.include?("remote") || error.message.include?("transport")
          Error.new("remote_identity_invalid", error.message)
        else
          Error.new("git_residue_unverifiable", error.message)
        end
      end

      def blocked_from_error(task, error)
        Result.new(
          status: "blocked",
          reason: error.reason,
          retryable: error.retryable,
          task_slug: safe_task_slug(task),
          task_id: safe_task_id(task),
          guidance: error.guidance
        )
      end

      def trigger_failpoint!(name, payload = {})
        @failpoint&.call(name, payload)
      end

      def safe_task_slug(task)
        task.respond_to?(:slug) ? task.slug&.to_s : nil
      end

      def safe_task_id(task)
        task.respond_to?(:id) ? task.id&.to_s : nil
      rescue StandardError
        nil
      end
    end
  end
end
