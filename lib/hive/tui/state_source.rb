require "stringio"
require "digest"
require "set"
require "hive"
require "hive/commands/status"
require "hive/config"
require "hive/tui/debug"
require "hive/tui/snapshot"

module Hive
  module Tui
    # Background-thread poller for `hive status` JSON. Calls
    # `Hive::Commands::Status#json_payload` in-process at ~1 Hz, wraps
    # each successful payload in a Snapshot, and exposes the latest one
    # through `#current` for the render thread to read.
    #
    # The render thread reads `@current` without a Mutex. Under MRI's
    # GVL a pointer-sized reference assignment is atomic, so the reader
    # always sees either the previous Snapshot or the new one — never a
    # torn value. JRuby/TruffleRuby would need synchronisation; the boot
    # guard in `Hive::Tui.run` enforces MRI.
    #
    # On any StandardError during refresh the previous snapshot is held
    # and the failure is recorded in `@last_error` (overwritten each
    # retry; not a ring buffer, so the renderer only ever displays the
    # most recent error). The polling loop never crashes its own thread.
    #
    # Cross-thread state beyond `@current`. A short-lived archive
    # refresher thread (spawned by `#start_archive_refresh_if_needed`)
    # writes `@archived_cache`, `@archive_last_refresh_at`, and
    # `@archive_last_error`. Once `@current` is established the refresher is
    # the SOLE writer of those three: the poll/boot thread's cold-start
    # branch in `#refresh_once` also seeds `@archived_cache` and
    # `@archive_last_refresh_at`, but that branch runs only while `@current`
    # is nil — before any refresher can spawn — so there is no concurrent
    # write. Thereafter the poll/render threads only read them, so the same
    # atomic-reference-read discipline as `@current` applies.
    # `@archive_refresh_dirty` is the field written by more than one thread
    # in steady state: ANY thread may SET it (`#request_archive_refresh` is
    # called from the Bubbletea update thread as well as the poll thread,
    # and the refresher re-arms it on a first failure), but only the poll
    # thread CLEARS it (at refresher spawn). A set dropped under that race
    # is recovered by the `ARCHIVE_REFRESH_FALLBACK_SECONDS` backstop. This
    # is a lock-free, single-writer-once-booted-plus-backstop discipline.
    # `@archive_refresh_thread` is also touched across threads: the poll
    # thread spawns it and reads `&.alive?` (here, in `#archive_refresh_due?`
    # and `#start_archive_refresh_if_needed`), while `#stop` (any thread)
    # nils it. Each access is a single atomic-reference read/write under MRI's
    # GVL; the only real interleaving is the teardown race documented in
    # `#stop`'s comment.
    class StateSource
      attr_reader :current_seen_at

      # Upper bound on how long the mtime gate may reuse a cached
      # snapshot before forcing a full re-parse. The fingerprint only
      # tracks file mtimes, but some payload fields (`live_task_lock`,
      # `claude_pid_alive`) are derived from process liveness, which
      # flips without touching any file. Without this fallback a dead
      # lock holder's "live" indicator could never clear. The bound
      # keeps the indicator self-healing while still skipping most
      # idle-path parses.
      LIVENESS_REPARSE_FALLBACK_SECONDS = 3.0
      # Backstop for the archive-set dirty signal, independent of the
      # liveness fallback above. Even with no terminal-stage dir-mtime change
      # and no archive-pane open, force a background archived-cache
      # refresh at least this often so a dropped dirty set (any thread may
      # SET it, only the poll thread CLEARS it) or an mtime-granularity
      # miss still self-heals.
      ARCHIVE_REFRESH_FALLBACK_SECONDS = 30.0

      # Fresh-per-call marker distinguishing "stat errored" from nil
      # ("absent"). Two instances are never `==`, so a repeatedly-erroring
      # path reads as changed on every tick and the change detectors bias
      # toward a re-check rather than masking a real mutation behind a
      # transient stat failure (see `#safe_mtime`).
      #
      # MUST never gain `==`/`eql?`/`hash` and must stay a plain class (not
      # a Struct/Data): the change detectors depend on two instances never
      # comparing equal. Adding value equality would make a repeatedly-
      # erroring path read as "unchanged" and silently mask a real mutation.
      class StatError; end

      def initialize(poll_interval_seconds: 1.0)
        @poll_interval_seconds = poll_interval_seconds
        @current = nil
        @current_seen_at = nil
        @last_error = nil
        # Separate error channel for the archive refresher thread so the
        # poll thread's per-tick `@last_error = nil` (idle gate /
        # publish_snapshot) can't wipe a refresh failure before it surfaces
        # to the renderer. `#last_error` returns whichever is set.
        @archive_last_error = nil
        @mtime_fingerprint = nil
        @policy_fingerprint = nil
        @file_signature_cache = {}
        @last_full_parse_at = nil
        @next_retention_boundary = nil
        # Consecutive archive-refresh failures, so a permanent
        # `json_payload` raise backs off to the 30s backstop instead of
        # hot-looping a full archive rescan every poll tick (see
        # #refresh_archived_cache).
        @archive_refresh_failures = 0
        # Per-path consecutive stat-error streaks (see #safe_mtime): a
        # genuinely stuck EACCES/ESTALE biases the change detectors toward
        # a re-check forever; the streak surfaces a breadcrumb after N.
        @stat_error_streaks = {}
        @archived_cache = empty_archived_cache
        @snapshot_archived_cache = @archived_cache
        @archive_dir_mtimes = {}
        @archive_last_refresh_at = nil
        @archive_refresh_dirty = false
        @archive_refresh_thread = nil
        # Consecutive poll ticks the archive refresher has stayed alive. A
        # healthy refresh completes well within one tick, so a climbing count
        # means the thread is blocked (e.g. uninterruptible I/O on a stale-NFS
        # terminal-stage dir), which silently freezes the cache; #note_archive_refresher_liveness
        # leaves a once-fired breadcrumb when it crosses the hang threshold.
        @archive_refresh_alive_ticks = 0
        @stop = false
        @thread = nil
      end

      # Latest Snapshot, or nil before the first successful poll.
      def current
        @current
      end

      # Most recent failure for the renderer's error channel. Prefers the
      # poll thread's active-parse error (`@last_error`, the primary data
      # path) and falls back to the archive refresher's error
      # (`@archive_last_error`), which the poll thread never clears — so a
      # background archive-refresh failure stays visible instead of being
      # wiped by the next successful active tick. Both are atomic-reference
      # reads under MRI's GVL (same discipline as `@current`).
      def last_error
        @last_error || @archive_last_error
      end

      # Synchronous refresh used during TUI boot to seed the first frame
      # before Bubbletea's input loop starts. The normal background
      # poller still owns subsequent refreshes.
      def refresh_now
        refresh_once
        current
      end

      # Marks the archived-row cache dirty so the next poll tick spawns a
      # background refresher. Cross-thread entry point: besides the poll
      # thread, the Bubbletea update thread calls this (App wires it as
      # BubbleModel's `archive_refresh` hook, fired on archive-pane open).
      # Invariant: any thread may SET the dirty flag here; only the poll
      # thread CLEARS it (at refresher spawn). A set lost to that race is
      # recovered by the `ARCHIVE_REFRESH_FALLBACK_SECONDS` backstop.
      def request_archive_refresh
        @archive_refresh_dirty = true
        nil
      end

      # Boots the polling thread. Idempotent: a second call while the
      # thread is alive is a no-op so accidental double-starts in test
      # setup don't leak threads.
      def start
        return if @thread&.alive?

        @stop = false
        @thread = Thread.new { poll_loop }
      end

      # Sets the stop sentinel and joins the poll thread, then the archive
      # refresher thread, each with its own 0.5s deadline (worst-case
      # ~1.0s teardown). The poll loop checks the sentinel between 0.05s
      # sleep slices, and `#start_archive_refresh_if_needed` refuses to
      # spawn once `@stop` is set, so neither thread outlives this call and
      # test teardown can assert both are gone from `Thread.list`.
      def stop
        @stop = true
        thread = @thread
        @thread = nil
        thread&.join(0.5)
        archive_thread = @archive_refresh_thread
        @archive_refresh_thread = nil
        archive_thread&.join(0.5)
        nil
      end

      # Boot state (no successful poll yet) counts as stalled so the
      # renderer can show a "loading" banner before the first frame.
      def stalled?(now: Time.now, threshold_seconds: 5.0)
        return true if @current_seen_at.nil?

        (now - @current_seen_at) > threshold_seconds
      end

      private

      def poll_loop
        until @stop
          refresh_once
          sleep_in_slices(@poll_interval_seconds)
        end
      end

      def refresh_once
        refresh_now = Time.now.utc
        note_archive_refresher_liveness
        policy_unchanged = false
        if @current
          refresh_archive_signals(@current.projects)
          current_policy_fingerprint = policy_fingerprint_for(@current)
          policy_unchanged = current_policy_fingerprint == @policy_fingerprint
          request_archive_refresh unless policy_unchanged
        end
        request_archive_refresh if archive_refresh_due?(now: refresh_now)

        cache = @archived_cache
        cache_unchanged = cache.equal?(@snapshot_archived_cache)
        if @current && @mtime_fingerprint && cache_unchanged && policy_unchanged &&
           mtime_fingerprint_unchanged? && !full_reparse_due?(now: refresh_now) &&
           !retention_reparse_due?(now: refresh_now)
          start_archive_refresh_if_needed
          @current_seen_at = refresh_now
          @last_error = nil
          return
        end

        projects = Hive::Config.registered_projects
        admission_context = Hive::DependencySnapshot.admission_context(projects)
        if @current.nil?
          # Cold start publishes the ordinary producer projection and seeds a
          # separate, explicitly unfiltered archive cache with the same clock.
          ordinary_status = Hive::Commands::Status.new
          ordinary_payload = ordinary_status.json_payload(
            projects, admission_context: admission_context, now: refresh_now
          )
          archive_payload = Hive::Commands::Status.new(archive: true).json_payload(
            projects, admission_context: admission_context, now: refresh_now
          )
          @archived_cache = archived_cache_from_payload(
            archive_payload, admission_context: admission_context, previous: @archived_cache
          )
          @archive_last_refresh_at = refresh_now
          publish_snapshot(
            ordinary_payload, archived_cache: @archived_cache,
            next_retention_boundary: ordinary_status.next_retention_boundary
          )
          @archive_dir_mtimes = archive_dir_mtimes_for(@current.projects)
        else
          # Steady state also consumes Status's ordinary projection directly.
          # The cache is attached only as Snapshot's dedicated archive source.
          ordinary_status = Hive::Commands::Status.new
          ordinary_payload = ordinary_status.json_payload(
            projects, admission_context: admission_context, now: refresh_now
          )
          publish_snapshot(
            ordinary_payload, archived_cache: cache,
            next_retention_boundary: ordinary_status.next_retention_boundary
          )
        end
        # Do not overlap the ordinary producer with the heavier unfiltered
        # archive producer. Both resolve project workflow overlays under the
        # same process-wide lock, and running them concurrently can starve the
        # user-facing refresh under Bubble Tea's input loop. Publish ordinary
        # rows first; the dedicated archive cache catches up in the background.
        start_archive_refresh_if_needed
      rescue StandardError => e
        Hive::Tui::Debug.log(
          "state_source",
          "refresh failed: #{e.class}: #{e.message}"
        )
        @last_error = e
      end

      # Time-bounded fallback so the mtime gate can't mask liveness
      # state indefinitely (see LIVENESS_REPARSE_FALLBACK_SECONDS).
      def full_reparse_due?(now: Time.now)
        return true if @last_full_parse_at.nil?

        (now - @last_full_parse_at) >= LIVENESS_REPARSE_FALLBACK_SECONDS
      end

      def retention_reparse_due?(now: Time.now)
        @next_retention_boundary && now > @next_retention_boundary
      end

      def mtime_fingerprint_unchanged?
        return false if @mtime_fingerprint.empty?

        @mtime_fingerprint.all? do |path, previous_mtime|
          safe_mtime(path) == previous_mtime
        end
      end

      def mtime_fingerprint_for(snapshot)
        # Watch the global project registry too: `hive init`/`forget`
        # rewrite config.yml without touching any tracked state file,
        # so without this the gate would never see a project added or
        # removed and the displayed set would go stale indefinitely.
        paths = [ registry_config_path ]
        archived_folders = snapshot.archive_rows.map(&:folder).compact.to_set
        snapshot.projects.each do |project|
          paths.concat(project_watch_paths(project))
          project.rows.each do |row|
            next if archived_folders.include?(row.folder)

            paths << row.state_file
            # A runner can acquire the task lock before it writes
            # AGENT_WORKING, so the lock file is a status-affecting path.
            paths << File.join(row.folder, ".lock") if row.folder
          end
        end
        paths.compact.uniq.to_h { |path| [ path, safe_mtime(path) ] }
      end

      def registry_config_path
        Hive::Config.global_config_path
      rescue StandardError => e
        # Bounded: dropping the registry path from the fingerprint only
        # delays a project set add/remove to the 3s liveness reparse. Leave
        # a breadcrumb so an otherwise-mysterious "project set briefly
        # stale" is diagnosable under HIVE_TUI_DEBUG.
        Hive::Tui::Debug.log("state_source", "registry_config_path failed: #{e.class}: #{e.message}")
        nil
      end

      def project_watch_paths(project)
        stages_dir = File.join(project.hive_state_path.to_s, "stages")
        # Glob THIS project's on-disk stage dirs rather than the
        # process-global `all_stage_dirs` union. `load!`
        # leaves only the last-loaded project's workflow overlay
        # registered, so a custom-workflow project that isn't last would
        # have its custom active stage dirs (e.g. `2-work`) absent from a
        # union-derived watch set — a new task appearing there would then be
        # caught only by the 3s liveness fallback, not the ~1s mtime gate.
        # Globbing on disk mirrors the per-project parse fix and is blind to
        # overlay-registration order. Archived state-file cost is still
        # avoided by the action check in mtime_fingerprint_for.
        on_disk = Dir.glob(File.join(stages_dir, "*")).select { |path| File.directory?(path) }
        [ stages_dir, *on_disk ]
      end

      # Policy inputs are small descriptor/config files plus task metadata
      # that can change a workflow pin. They use content-aware signatures so
      # same-size replacements with preserved/coarse mtimes still invalidate
      # the ordinary projection on the next poll.
      def policy_fingerprint_for(snapshot)
        content_paths = [ registry_config_path ]
        snapshot.projects.each do |project|
          content_paths.concat(project_policy_paths(project))
        end
        task_meta_paths = (snapshot.rows + snapshot.archive_rows).map do |row|
          task_meta_path(row.folder)
        end
        fingerprint = content_paths.compact.uniq.sort.to_h do |path|
          [ path, safe_content_signature(path, always_digest: true) ]
        end
        task_meta_paths.compact.uniq.sort.each do |path|
          fingerprint[path] = safe_content_signature(path)
        end
        @file_signature_cache.delete_if { |path, _entry| !fingerprint.key?(path) }
        fingerprint
      end

      def project_policy_paths(project)
        hive_state = project.hive_state_path.to_s
        workflow_dir = File.join(hive_state, "workflows")
        descriptor_paths = Dir.glob(File.join(workflow_dir, "**", "*.yml")).sort
        [
          File.join(project.path.to_s, ".hive-state", "config.yml"),
          File.join(hive_state, "config.yml"),
          workflow_dir,
          *descriptor_paths
        ]
      rescue StandardError => e
        Hive::Tui::Debug.log(
          "state_source",
          "policy paths failed for #{project.path}: #{e.class}: #{e.message}"
        )
        [ File.join(hive_state, "workflows") ]
      end

      def task_meta_path(folder)
        File.join(folder.to_s, "meta.yml") unless folder.to_s.empty?
      end

      def safe_content_signature(path, always_digest: false)
        unless path && File.exist?(path)
          @file_signature_cache.delete(path) if path
          return :absent
        end

        stat = File.stat(path)
        identity = [
          stat.ftype, stat.size, stat.mtime.to_r, stat.ctime.to_r,
          (stat.ino if stat.respond_to?(:ino))
        ]
        cached = @file_signature_cache[path]
        if !always_digest && cached && cached.fetch(:identity) == identity
          return cached.fetch(:signature)
        end

        digest =
          if stat.file?
            Digest::SHA256.file(path).hexdigest
          elsif stat.directory?
            Dir.children(path).sort.join("\0")
          end
        signature = [ *identity, digest ].freeze
        @file_signature_cache[path] = { identity: identity, signature: signature }
        signature
      rescue StandardError => e
        [ :stat_error, e.class.name ].freeze
      end

      # nil means the path is genuinely absent (or nil); a stat ERROR
      # returns a fresh, never-equal `StatError` marker instead. The
      # change detectors compare consecutive readings, so an errored read
      # then reads as "changed/uncertain" and biases toward a re-check — a
      # transient EACCES/ESTALE on an archive dir (or a vanish between
      # `exist?` and `mtime`) can't masquerade as "unchanged" and drop a
      # real mutation until the 30s backstop. A stably-absent path stays
      # `nil == nil` and is correctly seen as unchanged.
      def safe_mtime(path)
        return nil unless path && File.exist?(path)

        mtime = File.mtime(path)
        @stat_error_streaks.delete(path)
        mtime
      rescue StandardError => e
        note_stat_error(path, e)
        StatError.new
      end

      # A genuinely STUCK stat error (vs. a one-off vanish) keeps the
      # never-equal StatError marker forcing a re-check every tick, which
      # re-introduces the very degradation this gate exists to avoid — and
      # the safe_mtime bias is silent. Count consecutive errors per path and
      # leave a single breadcrumb once the streak crosses the threshold so a
      # stuck EACCES/ESTALE is diagnosable under HIVE_TUI_DEBUG instead of
      # presenting as an unexplained hot poll loop. Poll-thread-local: every
      # safe_mtime caller runs on the poll thread.
      STAT_ERROR_BREADCRUMB_THRESHOLD = 5

      def note_stat_error(path, error)
        streak = (@stat_error_streaks[path] || 0) + 1
        @stat_error_streaks[path] = streak
        return unless streak == STAT_ERROR_BREADCRUMB_THRESHOLD

        Hive::Tui::Debug.log(
          "state_source",
          "stat error persists (#{streak}x) for #{path}: #{error.class}: #{error.message}"
        )
      end

      def publish_snapshot(payload, archived_cache:, next_retention_boundary: nil)
        snapshot = Snapshot.from_payload(
          payload,
          archive_payload: archive_payload_from_cache(payload, archived_cache)
        )
        @current = snapshot
        @current_seen_at = Time.now
        @last_full_parse_at = @current_seen_at
        @next_retention_boundary = next_retention_boundary
        @mtime_fingerprint = mtime_fingerprint_for(snapshot)
        @policy_fingerprint = policy_fingerprint_for(snapshot)
        @snapshot_archived_cache = archived_cache
        @last_error = nil
      end

      def archive_payload_from_cache(ordinary_payload, archived_cache)
        cached_rows_by_path = archived_cache.fetch(:rows_by_path)
        copy = ordinary_payload.dup
        copy["projects"] = Array(ordinary_payload["projects"]).map do |project|
          project_copy = project.dup
          cached_rows = project["error"] ? [] : cached_rows_by_path.fetch(project["path"], [])
          project_copy["tasks"] = cached_rows
          project_copy.delete("hidden_archived_task_count")
          project_copy
        end
        copy
      end

      def empty_archived_cache
        {
          rows_by_path: {}.freeze,
          admission_context: Hive::DependencyAdmission::Context.new(projects: [])
        }.freeze
      end

      # Builds the frozen archived-row cache keyed by project path. `previous`
      # is the prior cache (if any): when a project's archive payload comes
      # back EMPTY, retain that project's prior rows ONLY while one of those
      # workflow-aware archived folders still exists on disk. A transient per-project
      # parse failure degrades to an empty task list with no "error" marker
      # (Status#project_payload_or_degraded), which is structurally
      # indistinguishable from a legitimate final archived folder being dropped —
      # both yield `tasks=[]`. The on-disk cached-folder check
      # supplies the missing discriminator: a still-present archived folder
      # means the empty payload is a degradation (retain), while no prior
      # folders means a
      # real removal (publish []). Without it, dropping a project's LAST
      # archived task would re-retain the stale rows on every subsequent empty
      # refresh, leaving a permanent ghost in the archive pane (plan Risk #6).
      # Genuine removals that shrink a project to a smaller non-empty set are
      # still published verbatim.
      def archived_cache_from_payload(payload, admission_context:, previous: nil)
        previous_rows = previous && previous.fetch(:rows_by_path, nil)
        rows_by_path = {}
        retained_paths = {}
        Array(payload["projects"]).each do |project|
          path = project["path"]
          next unless path

          # Archive-mode Status already applied workflow/action-aware
          # membership. Do not reinterpret terminal directory names here.
          archived_rows = Array(project["tasks"])
          if archived_rows.empty?
            prior = previous_rows && previous_rows[path]
            if prior && !prior.empty? && cached_archive_rows_still_exist?(prior)
              rows_by_path[path] = prior
              retained_paths[File.expand_path(path)] = true
              next
            end
          end
          # Shallow freeze: each row hash is frozen but nested values (e.g.
          # an `attrs` sub-hash) stay mutable. The rows are only ever read,
          # so this is sufficient to keep the cache safe to share unguarded
          # across threads.
          rows_by_path[path] = archived_rows.map { |task| task.dup.freeze }.freeze
        end
        archived_slugs_by_path = rows_by_path.to_h do |path, rows|
          [ File.expand_path(path), rows.to_h { |row| [ row["slug"], true ] } ]
        end
        archived_projects = admission_context.projects.map do |project|
          if retained_paths[File.expand_path(project.path)]
            previous&.fetch(:admission_context)&.project_for_path(project.path) ||
              project.with(tasks: [])
          else
            archived_slugs = archived_slugs_by_path.fetch(File.expand_path(project.path), {})
            project.with(tasks: project.tasks.select { |task| archived_slugs.key?(task.slug) })
          end
        end
        {
          rows_by_path: rows_by_path.freeze,
          admission_context: Hive::DependencyAdmission::Context.new(projects: archived_projects)
        }.freeze
      end

      # Positive on-disk evidence that at least one previously cached archive
      # task folder still exists — the discriminator that lets
      # `archived_cache_from_payload` tell a transient empty payload (retain)
      # apart from a real last-row drop (publish []). Uses the same
      # workflow-aware folders already selected by Status, so custom terminal
      # directory names need no second classifier. A stat fault is treated as
      # "uncertain → retain" (mirrors `safe_mtime`'s
      # re-check bias) so a transient EACCES/ESTALE can't blank a project's
      # archived rows.
      def cached_archive_rows_still_exist?(rows)
        Array(rows).any? do |row|
          folder = row["folder"]
          folder && File.directory?(folder)
        end
      rescue StandardError
        true
      end

      def refresh_archive_signals(projects)
        mtimes = archive_dir_mtimes_for(projects)
        # Compare on a STABLE signature that collapses every per-path
        # `StatError` marker to one sentinel. `safe_mtime` returns a fresh,
        # never-equal `StatError` on a stat fault so the mtime *gate* (the
        # cheap active reparse) biases toward a re-check — but that same
        # never-equal marker, fed straight into this archive *trigger*, reads
        # as "changed" on EVERY tick for a persistently-stuck terminal dir
        # (e.g. stale NFS where `File.exist?` is true but `File.mtime`
        # raises). That hot-loops the heavyweight archive-mode status rescan
        # with no backoff: the 30s `#archive_refresh_due?`
        # throttle gates only the time-based re-arm, and the failure backoff
        # only engages when `json_payload` itself raises (here it succeeds).
        # Collapsing `StatError` to one value makes a stuck dir trigger
        # exactly once on the transition into the error (the correct
        # "uncertain → re-check once" bias) and once on recovery, while the
        # 30s backstop still forces periodic refreshes if the dir keeps
        # mutating behind an unreadable mtime.
        request_archive_refresh if archive_mtime_signature(@archive_dir_mtimes) != archive_mtime_signature(mtimes)
        @archive_dir_mtimes = mtimes
      end

      def archive_mtime_signature(mtimes)
        mtimes.transform_values { |value| value.is_a?(StatError) ? :stat_error : value }
      end

      def archive_dir_mtimes_for(projects)
        pairs = Array(projects).flat_map do |project|
          stages_dir = File.join(project.hive_state_path.to_s, "stages")
          terminal_dirs = Hive::Workflows::Project.synchronize do
            Hive::Workflows::Project.load!(project.path)
            Hive::Workflows.all_terminal_stage_dirs.dup
          end
          # Watch only workflow terminal directories. Active-stage mutations
          # already invalidate the ordinary mtime fingerprint and must not
          # launch a redundant full archive scan. Descriptor/pin/default
          # changes live in policy_fingerprint_for and separately arm the
          # archive refresh.
          paths = terminal_dirs.map { |dir| File.join(stages_dir, dir) }
          paths.map { |path| [ path, safe_mtime(path) ] }
        rescue StandardError => e
          Hive::Tui::Debug.log(
            "state_source",
            "archive signal paths failed for #{project.path}: #{e.class}: #{e.message}"
          )
          [ [ stages_dir, StatError.new ] ]
        end
        pairs.to_h
      end

      def archive_refresh_due?(now: Time.now)
        return false if @current.nil?
        # A refresh already in flight will stamp `@archive_last_refresh_at`
        # on completion. Without this guard the backstop re-arms the dirty
        # flag every tick while a long archive parse spans multiple poll
        # ticks (the stamp only advances on completion), queuing one
        # redundant full archive scan per cycle.
        return false if @archive_refresh_thread&.alive?
        return true if @archive_last_refresh_at.nil?

        (now - @archive_last_refresh_at) >= ARCHIVE_REFRESH_FALLBACK_SECONDS
      end

      def start_archive_refresh_if_needed
        # `@stop` guard: if the poll thread overshoots stop's join deadline
        # mid-parse, it must not spawn a fresh refresher after `#stop`
        # already captured/nilled the reference — that would leave a
        # detached thread alive past teardown.
        return if @stop
        return unless @archive_refresh_dirty
        return if @current.nil?
        return if @archive_refresh_thread&.alive?

        project_entries = projects_from_snapshot(@current)
        @archive_refresh_dirty = false
        @archive_refresh_thread = Thread.new(project_entries) do |entries|
          refresh_archived_cache(entries)
        end
      end

      def projects_from_snapshot(snapshot)
        registered = Hive::Config.registered_projects.group_by do |entry|
          File.expand_path(entry.fetch("path"))
        end
        Array(snapshot&.projects).map do |project|
          matches = registered[File.expand_path(project.path)] || []
          registry_entry = matches.one? ? matches.first : nil
          {
            "name" => project.name,
            "path" => project.path,
            "hive_state_path" => project.hive_state_path,
            "repository_identity" => registry_entry && registry_entry["repository_identity"]
          }
        end
      end

      def refresh_archived_cache(projects)
        # `Status#json_payload`'s per-project degrade paths
        # (`project_payload_or_degraded`, `dependency_gate_stage_for`) `warn`
        # to the real `$stderr`. This refresher runs OFF the poll thread, so
        # an unguarded call makes it a SECOND concurrent emitter that could
        # tear the alt-screen frame mid-render. Capture stdout/stderr around
        # the in-process call so those degrade-path warns — which never reach
        # the operator under the alt-screen anyway — can't corrupt the frame
        # (`capture_status_io`, mirroring `BubbleModel#capture_command_io`).
        admission_context = Hive::DependencySnapshot.admission_context(projects)
        refresh_now = Time.now.utc
        payload = capture_status_io do
          Hive::Commands::Status.new(archive: true).json_payload(
            projects,
            admission_context: admission_context,
            now: refresh_now
          )
        end
        @archived_cache = archived_cache_from_payload(
          payload, admission_context: admission_context, previous: @archived_cache
        )
        @archive_last_refresh_at = refresh_now
        @archive_refresh_failures = 0
        @archive_last_error = nil
      rescue StandardError => e
        # Surface the failure on the refresher's own `@archive_last_error`
        # channel (read by `#last_error`) rather than `warn`, which would
        # corrupt the alt-screen frame and never reach the operator. The
        # dedicated field means the poll thread's per-tick `@last_error =
        # nil` can't wipe it before it surfaces.
        @archive_last_error = e
        @archive_refresh_failures += 1
        Hive::Tui::Debug.log(
          "state_source",
          "archive refresh failed (#{@archive_refresh_failures}x): #{e.class}: #{e.message}"
        )
        if @archive_refresh_failures <= 1
          # First failure: re-arm the dirty flag so the next poll tick
          # retries once (the spawn cleared the flag and
          # `refresh_archive_signals` already advanced `@archive_dir_mtimes`,
          # so nothing else would re-trigger).
          @archive_refresh_dirty = true
        else
          # Repeated failure: back off. Stamp the refresh time so the next
          # attempt waits for the 30s backstop instead of respawning a full
          # archive-mode rescan every ~1s tick. A genuine permanent top-level
          # json_payload raise (unlikely — per-project failures degrade)
          # would otherwise hot-loop the heavyweight scan this PR exists to
          # avoid.
          @archive_last_refresh_at = Time.now
        end
      end

      # Poll ticks an archive refresher may stay alive before it is treated as
      # hung and a breadcrumb is dropped. A normal refresh completes well
      # within one tick, so this is far above any healthy run.
      ARCHIVE_REFRESHER_HANG_TICKS = 10

      # Breadcrumb for a refresher thread that never returns. Both
      # `#archive_refresh_due?` and `#start_archive_refresh_if_needed`
      # early-return on `@archive_refresh_thread&.alive?`, so an
      # uninterruptible I/O hang scoped to a terminal dir (e.g. stale NFS)
      # freezes the cache forever with NO `@archive_last_error` and NO
      # Debug.log (a blocked thread raises nothing) while `#stalled?` — which
      # only tracks the active poll — stays false. Count the consecutive poll
      # ticks the refresher stays alive and leave one breadcrumb once it
      # crosses the threshold so the otherwise-silent freeze is diagnosable
      # under HIVE_TUI_DEBUG. Poll-thread-local: only `#refresh_once` calls
      # this, and it reads `@archive_refresh_thread` with the same atomic
      # reference discipline as the other readers.
      def note_archive_refresher_liveness
        unless @archive_refresh_thread&.alive?
          @archive_refresh_alive_ticks = 0
          return
        end

        @archive_refresh_alive_ticks += 1
        return unless @archive_refresh_alive_ticks == ARCHIVE_REFRESHER_HANG_TICKS

        Hive::Tui::Debug.log(
          "state_source",
          "archive refresher alive for #{@archive_refresh_alive_ticks} consecutive poll ticks; " \
          "archived cache refresh may be stuck (e.g. blocking I/O on a terminal-stage dir)"
        )
      end

      # Redirect `$stdout`/`$stderr` to throwaway buffers for the duration of
      # the block so an off-thread `Status#json_payload` call can't `warn`
      # straight onto the alt-screen frame. Mirrors
      # `BubbleModel#capture_command_io`; `capture_io` from minitest is not
      # available in production. StateSource itself never `warn`s, so this only
      # contains Status's degrade-path output.
      def capture_status_io
        orig_out = $stdout
        orig_err = $stderr
        $stdout = StringIO.new
        $stderr = StringIO.new
        yield
      ensure
        $stdout = orig_out
        $stderr = orig_err
      end

      # Sleep in 0.05s slices so #stop joins quickly. Reading @stop
      # between slices is the same unsynchronised-reference-read pattern
      # the render thread uses on @current (and the poll thread uses on
      # @archived_cache / @archive_refresh_dirty) — safe under MRI's GVL.
      def sleep_in_slices(total_seconds)
        slice = 0.05
        elapsed = 0.0
        while elapsed < total_seconds && !@stop
          remaining = total_seconds - elapsed
          sleep(remaining < slice ? remaining : slice)
          elapsed += slice
        end
      end
    end
  end
end
