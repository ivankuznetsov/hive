require "hive/task_meta"
require "hive/task_counter"
require "hive/config"
require "hive/git_ops"
require "hive/lock"

module Hive
  module Daemon
    # Tick-time self-healer for tasks created OUTSIDE `hive new` — a
    # hand-made folder, one `mv`-ed in from elsewhere, or a restored task —
    # whose `meta.yml` carries no `id`. `hive new` allocates an id from
    # `Hive::TaskCounter` and writes it into the meta; a task that never
    # went through that path shows a blank id everywhere it is listed (TUI,
    # `hive status`, digest, dependency references).
    #
    # This backfiller closes that gap purely additively: on each tick it
    # scans the status rows, and for any task whose meta `id` is missing it
    # allocates the next counter id, writes it, and commits the meta on the
    # `hive/state` branch — bounded by `max_per_tick`. It never touches
    # markers, dispatch, or heal logic.
    #
    # Anti-churn design (mirrors DisplayNameBackfiller):
    #   - Once a task's id is assigned, the next meta read no longer flags
    #     it, so it is a natural fixed point — a one-time assignment with no
    #     state to reconcile and no repeated work.
    #   - `max_per_tick` bounds how many assignments (each a small locked
    #     git commit) a single tick performs, so a large backlog drains
    #     over several ticks instead of committing in one burst.
    #   - Every per-row step is rescued, and `#backfill` itself can never
    #     raise out into the tick loop (which would trip the unit's
    #     restart-loop cap). A failed assignment simply leaves the id unset
    #     and is retried on a later tick; there is no backoff — the tick
    #     interval is the only spacing, which is fine for a one-shot heal.
    class TaskIdBackfiller
      DEFAULT_MAX_PER_TICK = 5

      # `allocate` and `commit` are injectable so the unit tests can assign
      # ids without a real task counter or git repo.
      def initialize(logger:, dry_run: false, max_per_tick: DEFAULT_MAX_PER_TICK,
                     allocate: nil, commit: nil)
        @logger = logger
        @dry_run = dry_run
        @max_per_tick = max_per_tick
        @allocate = allocate || -> { Hive::TaskCounter.next! }
        @commit = commit || method(:commit_id)
      end

      # Walk the row set; for each task whose meta has no id, assign one.
      # `now:` is accepted for signature parity with the other tick-time
      # healers even though id assignment needs no clock.
      def backfill(rows, now: Time.now)
        _ = now
        assigned = 0
        rows.each do |row|
          break if assigned >= @max_per_tick

          assigned += 1 if consider_row(row)
        end
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "task_id_backfiller#backfill raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
      end

      private

      # Returns true only when an id was assigned this tick (so the caller
      # can count it against max_per_tick). A single bad row or meta is
      # swallowed here so the rest of the row set still runs.
      def consider_row(row)
        folder = row_folder(row)
        return false if folder.empty?
        return false unless id_missing?(folder)

        assign_id(row, folder)
      rescue StandardError => e
        @logger.event(:fatal,
                      message: "task_id_backfiller row raised: #{e.class}: #{e.message}",
                      keeping_previous: true)
        false
      end

      def id_missing?(folder)
        # The folder must still exist on disk. A row can outlive its folder
        # (e.g. `hive drop` between the status snapshot and this tick); since
        # `TaskMeta.write` would `mkdir_p` the path, assigning an id to a
        # vanished folder would RESURRECT a dropped task. Skip it.
        return false unless File.directory?(folder)

        Hive::TaskMeta.read(folder)[:id].nil?
      rescue StandardError
        # If we can't read the meta we can't tell — treat as "not missing"
        # so a flaky read never triggers a write/commit storm.
        false
      end

      def assign_id(row, folder)
        if @dry_run
          @logger.event(:task_id_backfill,
                        project: row.project, slug: row.slug, folder: folder,
                        id: nil, dry_run: true)
          return false
        end

        id = @allocate.call
        return false if id.nil?

        Hive::TaskMeta.update_id(folder, id)
        # `committed: false` flags the durability gap (id on disk, not yet on
        # hive/state) so the success event isn't read as fully durable. With
        # the commit lock below a skip is rare, but when it happens the id is
        # swept into the next operation that commits this folder.
        committed = @commit.call(row) != false
        @logger.event(:task_id_backfill,
                      project: row.project, slug: row.slug, folder: folder,
                      id: id, committed: committed)
        true
      end

      # Commit the meta on hive/state under the per-project commit lock —
      # every durable `hive_commit` caller (`new`, `run`, `approve`,
      # `markers`, the name generator) takes it to serialise hive/state
      # writes against concurrent committers; skipping it would let this
      # `git add`/`commit` interleave with a dispatched child's and cross-
      # contaminate the audit history (or collide on `index.lock`). Uses the
      # same per-task `hive_commit(stage_name:, slug:)` the name generator
      # does. Returns true on commit, false on skip. A lock-timeout
      # (`ConcurrentRunError`) or git/config failure is swallowed and logged:
      # the id is still on disk and will be picked up by the next operation
      # that commits this task's folder.
      def commit_id(row)
        project = Hive::Config.find_project(row.project)
        return false unless project && project["path"]

        Hive::Lock.with_commit_lock(project["hive_state_path"]) do
          Hive::GitOps.new(project["path"]).hive_commit(
            stage_name: row.stage, slug: row.slug, action: "id-assigned"
          )
        end
        true
      rescue Hive::ConcurrentRunError, Hive::GitError, Hive::ConfigError, SystemCallError, IOError => e
        @logger.event(:task_id_backfill_commit_skipped,
                      project: row.project, slug: row.slug,
                      reason: "#{e.class}: #{e.message}")
        false
      end

      def row_folder(row)
        return "" unless row.respond_to?(:folder)

        row.folder.to_s
      end
    end
  end
end
