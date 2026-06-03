require "fileutils"
require "open3"
require "time"
require "yaml"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/paths"
require "hive/stages"
require "hive/task_counter"
require "hive/task_meta"

module Hive
  module Commands
    class Migrate
      # Each entry maps a legacy stage-directory name to its CURRENT
      # canonical name in `Hive::Stages::DIRS`. When the canonical layout
      # shifts (e.g. the 7-artifacts insertion), every entry must re-point
      # at the new index so a long-dormant project still migrates onto the
      # current layout in a single `hive migrate` pass — chaining is not
      # supported (see `Migrate::STAGE_RENAMES` consistency tests).
      STAGE_RENAMES = {
        "5-review" => "6-review",
        "6-pr" => "8-finalize",
        "7-done" => "9-done",
        "7-finalize" => "8-finalize",
        "8-done" => "9-done"
      }.freeze

      # Legacy `pr` budget/timeout keys are read-through-fallback in
      # Stages::Finalize for one version; this map rewrites them onto
      # the canonical names so the shim has a removal path. New keys
      # win on collision (the canonical was the one the user actually
      # tuned post-migration).
      CONFIG_KEY_RENAMES = {
        %w[budget_usd pr] => %w[budget_usd finalize],
        %w[timeout_sec pr] => %w[timeout_sec finalize]
      }.freeze

      # Task-folder names follow this slug pattern (see Task::PATH_RE).
      # Any entry under a legacy stage directory that doesn't look like a
      # task slug is left in place — never silently mv'd into the new
      # stage dir. Re-exported here for back-compat with existing callers;
      # `Hive::Stages::SLUG_RE` is the single source of truth shared with
      # `Hive::Commands::Status#detect_legacy_stage_dirs`.
      SLUG_RE = Hive::Stages::SLUG_RE

      def initialize(project_path = Dir.pwd)
        @project_path = File.expand_path(project_path)
      end

      def call
        hive_state = File.join(@project_path, ".hive-state")
        stages = File.join(hive_state, "stages")
        raise Hive::InvalidTaskPath, "not a hive project: #{hive_state}" unless Dir.exist?(stages)

        moved = []
        backfilled_count = 0
        Hive::Lock.with_commit_lock(hive_state) do
          plan = build_migration_plan(stages)
          config_changed = rewrite_legacy_config_keys(hive_state)
          if plan.empty?
            ensure_current_stage_dirs(stages)
            backfilled_count = backfill_task_ids(stages)
            if config_changed || backfilled_count.positive?
              commit_migration(hive_state, moved, config_only: config_changed, backfilled_count: backfilled_count)
              puts migration_no_move_message(config_changed: config_changed, backfilled_count: backfilled_count)
            elsif already_migrated?(stages)
              puts "hive: migrate found nothing to move (target stage directories look already-migrated)"
            else
              puts "hive: migrate found nothing to move"
            end
            return moved
          end

          # Pre-flight: all destinations must be free BEFORE we issue
          # any `mv`. Mid-loop collisions left the filesystem partially
          # renamed with no rollback — pre-flighting closes that hole.
          preflight_collisions!(plan)
          plan.each { |op| FileUtils.mv(op[:src], op[:dst]) }
          moved.concat(plan.map { |op| [ op[:old_stage], op[:new_stage], op[:entry] ] })
          ensure_current_stage_dirs(stages)
          backfilled_count = backfill_task_ids(stages)
          commit_migration(hive_state, moved, config_only: false, backfilled_count: backfilled_count)
        end

        puts "hive: migrate complete (#{moved.size} task#{moved.size == 1 ? '' : 's'} moved" \
             "#{backfilled_count.positive? ? ", #{backfilled_count} id#{backfilled_count == 1 ? '' : 's'} backfilled" : ''})"
        restart_daemon_if_running!
        moved
      end

      private

      def build_migration_plan(stages)
        ops = []
        STAGE_RENAMES.each do |old_stage, new_stage|
          old_dir = File.join(stages, old_stage)
          new_dir = File.join(stages, new_stage)
          FileUtils.mkdir_p(new_dir)
          next unless Dir.exist?(old_dir)

          Dir.children(old_dir).sort.each do |entry|
            # Skip any non-slug entry (including .gitkeep, .DS_Store,
            # stray .lock, etc.). Only task-folder slugs migrate.
            next unless Hive::Stages.task_slug?(entry)

            src = File.join(old_dir, entry)
            next unless File.directory?(src)

            ops << {
              old_stage: old_stage, new_stage: new_stage, entry: entry,
              src: src, dst: File.join(new_dir, entry)
            }
          end
        end
        ops
      end

      def preflight_collisions!(plan)
        # First: detect duplicate destinations *within* the plan itself.
        # STAGE_RENAMES maps multiple legacy stages to the same canonical
        # target (e.g., both `6-pr` and `7-finalize` map to `8-finalize`).
        # If a project has the same slug under two source stages,
        # File.exist? on the not-yet-created destination misses the
        # conflict — both ops pass preflight, the second FileUtils.mv
        # silently nests the source folder inside the existing dst
        # (`8-finalize/<slug>/<slug>/`), and PATH_RE cannot re-parse it.
        # Group by destination and raise on any plan-internal duplicate
        # before any mv runs.
        plan.group_by { |op| op[:dst] }.each do |dst, ops|
          next if ops.size == 1

          sources = ops.map { |op| "#{op[:old_stage]}/#{op[:entry]}" }.join(", ")
          raise Hive::DestinationCollision.new(
            "cannot migrate: multiple legacy stages target the same destination #{dst} " \
            "(sources: #{sources}); resolve by moving or renaming one of the source folders before rerunning",
            path: dst
          )
        end

        collisions = plan.select { |op| File.exist?(op[:dst]) }
        return if collisions.empty?

        first = collisions.first
        raise Hive::DestinationCollision.new(
          "cannot migrate #{collisions.size} task#{collisions.size == 1 ? '' : 's'}; " \
          "destination already exists for #{first[:old_stage]}/#{first[:entry]} at #{first[:dst]}",
          path: first[:dst]
        )
      end

      def ensure_current_stage_dirs(stages)
        Hive::Stages::DIRS.each do |stage|
          dir = File.join(stages, stage)
          FileUtils.mkdir_p(dir)
          gitkeep = File.join(dir, ".gitkeep")
          FileUtils.touch(gitkeep) unless File.exist?(gitkeep)
        end
      end

      def backfill_task_ids(stages)
        folders = task_folders(stages)
        max_id = folders.map { |folder| Hive::TaskMeta.read(folder)[:id] }.compact.max
        Hive::TaskCounter.seed_at_least!(max_id + 1) if max_id

        targets = folders.select { |folder| Hive::TaskMeta.read(folder)[:id].nil? }
        targets.sort_by! { |folder| [ idea_created_at(folder) || Time.at(2**31 - 1), File.basename(folder) ] }

        targets.each do |folder|
          meta = Hive::TaskMeta.read(folder)
          Hive::TaskMeta.write(
            folder,
            id: Hive::TaskCounter.next!,
            slug: File.basename(folder),
            display_name: meta[:display_name]
          )
        end
        targets.size
      end

      def task_folders(stages)
        return [] unless Dir.exist?(stages)

        Dir.children(stages).sort.flat_map do |stage|
          stage_dir = File.join(stages, stage)
          next [] unless File.directory?(stage_dir)

          Dir.children(stage_dir).sort.filter_map do |entry|
            next unless Hive::Stages.task_slug?(entry)

            folder = File.join(stage_dir, entry)
            folder if File.directory?(folder)
          end
        end
      end

      def idea_created_at(folder)
        path = File.join(folder, "idea.md")
        return nil unless File.exist?(path)

        data = frontmatter(File.read(path))
        raw = data["created_at"] || data[:created_at]
        return raw if raw.is_a?(Time)

        Time.parse(raw.to_s)
      rescue StandardError
        nil
      end

      def frontmatter(contents)
        return {} unless contents.start_with?("---\n")

        body = contents.lines[1..]
        stop = body&.index { |line| line.match?(/\A---\s*\z/) }
        return {} unless stop

        YAML.safe_load(body.first(stop).join) || {}
      rescue StandardError
        {}
      end

      def commit_migration(hive_state, moved, config_only: false, backfilled_count: 0)
        ops = Hive::GitOps.new(@project_path)
        ops.run_git!("-C", hive_state, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        message = migrate_commit_message(moved, config_only: config_only, backfilled_count: backfilled_count)
        ops.run_git!("-C", hive_state, "commit", "-m", message)
      rescue Hive::GitError => e
        # The mv operations already succeeded — the on-disk layout is
        # the new one — but git couldn't commit the change (missing
        # git, dirty index, hook failure, EACCES, etc.). Without this
        # rescue, a subsequent `hive migrate` sees `already_migrated?`
        # return true (because legacy dirs are absent) and is a no-op,
        # so the moves never get committed unless the operator notices
        # and runs the right git commands manually. Print a concrete
        # one-liner recovery hint and swallow the error so the rest of
        # `Migrate#call` (daemon restart, completion message) still
        # runs against the consistent on-disk layout. ce-code-review
        # P2 #21.
        message = migrate_commit_message(moved, config_only: config_only, backfilled_count: backfilled_count)
        warn "hive: migrate completed the on-disk mv operations but " \
             "could not commit them to the hive-state git history: " \
             "#{e.class}: #{e.message}"
        warn "hive: recover with:  git -C #{hive_state} add -A && " \
             "git -C #{hive_state} commit -m '#{message}'"
      end

      def migrate_commit_message(moved, config_only:, backfilled_count: 0)
        if moved.empty? && backfilled_count.positive? && !config_only
          "hive: migrate task ids (#{backfilled_count} task#{backfilled_count == 1 ? '' : 's'})"
        elsif config_only && moved.empty?
          "hive: migrate config keys (no tasks moved)"
        else
          "hive: migrate stage directories (#{moved.size} task#{moved.size == 1 ? '' : 's'})"
        end
      end

      def migration_no_move_message(config_changed:, backfilled_count:)
        if config_changed && backfilled_count.positive?
          "hive: migrate rewrote legacy config keys and backfilled #{backfilled_count} task id#{backfilled_count == 1 ? '' : 's'}"
        elsif config_changed
          "hive: migrate rewrote legacy config keys (no task folders to move)"
        else
          "hive: migrate backfilled #{backfilled_count} task id#{backfilled_count == 1 ? '' : 's'}"
        end
      end

      # Rewrite legacy `pr` budget/timeout keys onto the canonical
      # `finalize` names so the read-through fallback in Stages::Finalize
      # has a removal path. Idempotent and a no-op when the legacy keys
      # don't exist.
      def rewrite_legacy_config_keys(hive_state)
        path = File.join(hive_state, "config.yml")
        return false unless File.exist?(path)

        content = File.read(path)
        changed = false
        CONFIG_KEY_RENAMES.each do |from, to|
          section, key = from
          dst_section, dst_key = to
          next unless section == dst_section

          content, rewritten = rewrite_section_key(content, section, key, dst_key)
          changed ||= rewritten
        end
        File.write(path, content) if changed
        changed
      end

      def rewrite_section_key(content, section, legacy_key, canonical_key)
        lines = content.lines
        section_idx = lines.index { |line| line =~ /^(\s*)#{Regexp.escape(section)}:\s*(?:#.*)?$/ }
        return [ content, false ] unless section_idx

        section_indent = Regexp.last_match(1).length
        end_idx = lines.length
        ((section_idx + 1)...lines.length).each do |idx|
          line = lines[idx]
          next if line.strip.empty? || line.lstrip.start_with?("#")

          indent = line[/\A */].length
          if indent <= section_indent
            end_idx = idx
            break
          end
        end

        range = ((section_idx + 1)...end_idx)
        legacy_idx = range.find { |idx| lines[idx] =~ /^(\s*)#{Regexp.escape(legacy_key)}:(.*)$/ }
        return [ content, false ] unless legacy_idx

        canonical_exists = range.any? { |idx| lines[idx] =~ /^\s*#{Regexp.escape(canonical_key)}:/ }
        if canonical_exists
          lines.delete_at(legacy_idx)
        else
          lines[legacy_idx] = lines[legacy_idx].sub(/^(\s*)#{Regexp.escape(legacy_key)}:/, "\\1#{canonical_key}:")
        end
        [ lines.join, true ]
      end

      # True when every legacy stage dir is absent and every target
      # stage dir exists — i.e. an idempotent rerun of an already-
      # complete migration.
      def already_migrated?(stages)
        STAGE_RENAMES.all? { |old, new_dir| !Dir.exist?(File.join(stages, old)) && Dir.exist?(File.join(stages, new_dir)) }
      end

      # When `hive migrate` reshuffles the stage layout, an already-
      # running daemon still has Ruby constants (most importantly
      # `Hive::Daemon::PrMergeWatcher::ARCHIVE_VERB_TEMPLATE` and
      # `ARCHIVE_FROM_STAGE`) frozen at class-load time from the OLD
      # `Workflows::VERBS`. Its next archive dispatch would emit
      # `hive archive ... --from <old-stage>` against the post-migrate
      # disk layout and silently fail with `WrongStage`. Restarting the
      # daemon process is the only way to refresh those constants
      # (SIGHUP only re-reads YAML config, not Ruby constants).
      #
      # Best-effort: skip when no daemon pid file, no live process, or
      # `HIVE_MIGRATE_SKIP_DAEMON_RESTART` is set. On Linux with
      # systemd-user available, restart via systemctl. Anywhere else,
      # print a load-bearing warning so the operator restarts manually.
      def restart_daemon_if_running!
        return if ENV["HIVE_MIGRATE_SKIP_DAEMON_RESTART"] == "1"

        pid = read_daemon_pid
        return if pid.nil? || !daemon_alive?(pid)

        if systemctl_available?
          ok = system("systemctl", "--user", "restart", "hive-daemon",
                      out: File::NULL, err: File::NULL)
          if ok
            puts "hive: restarted hive-daemon (pid #{pid}) so its in-memory stage layout matches the migrated on-disk layout"
            return
          end

          warn "hive: migrate detected a running hive-daemon (pid #{pid}) but " \
               "`systemctl --user restart hive-daemon` failed; restart the daemon " \
               "manually before its next archive dispatch (e.g., `hive daemon stop && hive daemon start`)"
          return
        end

        warn "hive: migrate detected a running hive-daemon (pid #{pid}); restart it " \
             "manually so its in-memory stage layout refreshes from the new Hive::Workflows::VERBS " \
             "(e.g., `hive daemon stop && hive daemon start`)"
      end

      def read_daemon_pid
        pid_file = File.join(Hive::Paths.config_home, ".daemon.pid")
        return nil unless File.exist?(pid_file)

        payload = YAML.safe_load(File.read(pid_file)) rescue nil
        pid = payload.is_a?(Hash) ? payload["pid"] : payload
        pid.is_a?(Integer) && pid.positive? ? pid : nil
      rescue SystemCallError
        nil
      end

      def daemon_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        # We can't signal it, but the process exists — treat as alive
        # rather than risk a silent miss.
        true
      end

      def systemctl_available?
        system("systemctl", "--user", "--version",
               out: File::NULL, err: File::NULL)
      rescue SystemCallError
        false
      end
    end
  end
end
