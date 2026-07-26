require "fileutils"
require "open3"
require "time"
require "yaml"
require "hive/config"
require "hive/display_name/generator"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/paths"
require "hive/process_kill"
require "hive/recovery"
require "hive/recovery/migration"
require "hive/repository_identity"
require "hive/stages"
require "hive/task"
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
        "5-review" => "6-review", # not-a-stage-ref: legacy migration table
        "6-pr" => "8-finalize", # not-a-stage-ref: legacy migration table
        "7-done" => "9-done", # not-a-stage-ref: legacy migration table
        "7-finalize" => "8-finalize", # not-a-stage-ref: legacy migration table
        "8-done" => "9-done" # not-a-stage-ref: legacy migration table
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
      ROOT_REVIEWERS_LINE = /\A(?:reviewers|["']reviewers["'])\s*:/.freeze
      REVIEW_BLOCK_LINE = /\A(?:review|["']review["'])\s*:\s*(?:#.*)?(?:\r?\n)?\z/.freeze

      # Task-folder names follow this slug pattern (see Task::PATH_RE).
      # Any entry under a legacy stage directory that doesn't look like a
      # task slug is left in place — never silently mv'd into the new
      # stage dir. Re-exported here for back-compat with existing callers;
      # `Hive::Stages::SLUG_RE` is the single source of truth shared with
      # `Hive::Commands::Status#detect_legacy_stage_dirs`.
      SLUG_RE = Hive::Stages::SLUG_RE

      def initialize(project_path = Dir.pwd, display_name_generator: Hive::DisplayName::Generator)
        @project_path = File.expand_path(project_path)
        @display_name_generator = display_name_generator
      end

      def call
        hive_state = File.join(@project_path, ".hive-state")
        stages = File.join(hive_state, "stages")
        raise Hive::InvalidTaskPath, "not a hive project: #{hive_state}" unless Dir.exist?(stages)

        Hive::Recovery::Migration.ensure!
        moved = []
        backfilled_count = 0
        recovery_marker_count = 0
        no_move_message = nil
        Hive::Lock.with_commit_lock(hive_state) do
          plan = build_migration_plan(stages)
          config_changed = rewrite_legacy_config_keys(hive_state)
          if plan.empty?
            ensure_current_stage_dirs(stages)
            backfilled_count = backfill_task_ids(stages)
            recovery_marker_count = backfill_recovery_marker_ids(stages)
            if config_changed || backfilled_count.positive? || recovery_marker_count.positive?
              commit_migration(
                hive_state, moved, config_only: config_changed,
                backfilled_count: backfilled_count,
                recovery_marker_count: recovery_marker_count
              )
              no_move_message = migration_no_move_message(
                config_changed: config_changed,
                backfilled_count: backfilled_count,
                recovery_marker_count: recovery_marker_count
              )
            elsif already_migrated?(stages)
              no_move_message = "hive: migrate found nothing to move (target stage directories look already-migrated)"
            else
              no_move_message = "hive: migrate found nothing to move"
            end
          else

            # Pre-flight: all destinations must be free BEFORE we issue
            # any `mv`. Mid-loop collisions left the filesystem partially
            # renamed with no rollback — pre-flighting closes that hole.
            preflight_collisions!(plan)
            plan.each { |op| FileUtils.mv(op[:src], op[:dst]) }
            moved.concat(plan.map { |op| [ op[:old_stage], op[:new_stage], op[:entry] ] })
            ensure_current_stage_dirs(stages)
            backfilled_count = backfill_task_ids(stages)
            recovery_marker_count = backfill_recovery_marker_ids(stages)
            commit_migration(
              hive_state, moved, config_only: false,
              backfilled_count: backfilled_count,
              recovery_marker_count: recovery_marker_count
            )
          end
        end

        display_name_count = backfill_display_names(stages)
        if display_name_count.positive?
          Hive::Lock.with_commit_lock(hive_state) do
            commit_display_name_backfill(hive_state, display_name_count)
          end
        end
        repository_identity = backfill_registered_repository_identity

        if moved.empty?
          puts no_move_message
        else
          puts "hive: migrate complete (#{moved.size} task#{moved.size == 1 ? '' : 's'} moved" \
               "#{backfilled_count.positive? ? ", #{backfilled_count} id#{backfilled_count == 1 ? '' : 's'} backfilled" : ''}" \
               "#{recovery_marker_count.positive? ? ", #{recovery_marker_count} recovery marker#{recovery_marker_count == 1 ? '' : 's'} upgraded" : ''})"
        end
        if display_name_count.positive?
          puts "hive: migrate backfilled #{display_name_count} display name#{display_name_count == 1 ? '' : 's'}"
        end
        if repository_identity
          puts "hive: migrate backfilled registered repository identity #{repository_identity}"
        end
        restart_daemon_if_running! if moved.any?
        moved
      end

      private

      def backfill_registered_repository_identity
        project = Hive::Config.registered_projects.find do |entry|
          same_project_path?(entry["path"], @project_path)
        end
        return nil unless project
        return nil unless project["repository_identity"].to_s.empty?

        identity = Hive::RepositoryIdentity.current(@project_path)
        return nil unless identity

        Hive::Config.register_project(
          name: project.fetch("name"),
          path: project.fetch("path"),
          repository_identity: identity
        )
        identity
      end

      def same_project_path?(candidate, expected)
        return true if File.expand_path(candidate.to_s) == expected

        File.realpath(candidate.to_s) == File.realpath(expected)
      rescue SystemCallError
        false
      end

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
            display_name: meta[:display_name],
            depends_on: meta[:depends_on],
            workflow: meta[:workflow]
          )
        end
        targets.size
      end

      # Recovery v2 requires every recoverable marker generation to carry a
      # durable random identity. Older projects may have ERROR/REVIEW_ERROR
      # markers written before marker_id existed. Migrate them once, under the
      # project commit lock, so runtime recovery can reject id-less markers
      # instead of carrying a permanent compatibility identity algorithm.
      def backfill_recovery_marker_ids(stages)
        task_folders(stages).count do |folder|
          state_file = recovery_state_file(folder)
          next false unless state_file

          marker = Hive::Markers.current(state_file)
          next false unless Hive::Recovery.recoverable_marker?(marker.name)
          next false unless marker.attrs["marker_id"].to_s.empty?

          Hive::Markers.upgrade_recovery_marker_id(state_file, observed: marker)
        end
      end

      def recovery_state_file(folder)
        Hive::Task.new(folder).state_file
      rescue Hive::InvalidTaskPath, Hive::ConfigError
        # An unknown or incomplete workflow cannot identify its authoritative
        # state file safely. Preserve it unchanged; recovery remains blocked
        # until the workflow is restored and migrate can be rerun.
        nil
      end

      def backfill_display_names(stages)
        cfg = Hive::Config.load(@project_path)
        targets = task_folders(stages).select { |folder| Hive::TaskMeta.read(folder)[:display_name].nil? }

        targets.count do |folder|
          name = @display_name_generator.new(Hive::Task.new(folder), cfg: cfg, commit: false).call
          !name.to_s.strip.empty?
        end
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

      def commit_migration(hive_state, moved, config_only: false, backfilled_count: 0,
                           recovery_marker_count: 0)
        ops = Hive::GitOps.new(@project_path)
        ops.run_git!("-C", hive_state, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        message = migrate_commit_message(
          moved, config_only: config_only, backfilled_count: backfilled_count,
          recovery_marker_count: recovery_marker_count
        )
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
        message = migrate_commit_message(
          moved, config_only: config_only, backfilled_count: backfilled_count,
          recovery_marker_count: recovery_marker_count
        )
        warn "hive: migrate completed the on-disk mv operations but " \
             "could not commit them to the hive-state git history: " \
             "#{e.class}: #{e.message}"
        warn "hive: recover with:  git -C #{hive_state} add -A && " \
             "git -C #{hive_state} commit -m '#{message}'"
      end

      def commit_display_name_backfill(hive_state, display_name_count)
        ops = Hive::GitOps.new(@project_path)
        ops.run_git!("-C", hive_state, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", hive_state, "diff", "--cached", "--quiet")
        return if status.success?

        ops.run_git!("-C", hive_state, "commit", "-m",
                     "hive: migrate display names (#{display_name_count} task#{display_name_count == 1 ? '' : 's'})")
      rescue Hive::GitError => e
        warn "hive: migrate generated display names but could not commit them " \
             "to the hive-state git history: #{e.class}: #{e.message}"
        warn "hive: recover with:  git -C #{hive_state} add -A && " \
             "git -C #{hive_state} commit -m 'hive: migrate display names " \
             "(#{display_name_count} task#{display_name_count == 1 ? '' : 's'})'"
      end

      def migrate_commit_message(moved, config_only:, backfilled_count: 0,
                                 recovery_marker_count: 0)
        if moved.empty? && recovery_marker_count.positive? &&
           backfilled_count.zero? && !config_only
          "hive: migrate recovery markers (#{recovery_marker_count} task#{recovery_marker_count == 1 ? '' : 's'})"
        elsif moved.empty? && backfilled_count.positive? && !config_only &&
              recovery_marker_count.zero?
          "hive: migrate task ids (#{backfilled_count} task#{backfilled_count == 1 ? '' : 's'})"
        elsif config_only && moved.empty? && recovery_marker_count.zero?
          "hive: migrate config keys (no tasks moved)"
        elsif moved.empty?
          "hive: migrate project state (#{backfilled_count} ids, #{recovery_marker_count} recovery markers)"
        else
          "hive: migrate stage directories (#{moved.size} task#{moved.size == 1 ? '' : 's'})"
        end
      end

      def migration_no_move_message(config_changed:, backfilled_count:,
                                    recovery_marker_count: 0)
        actions = []
        actions << "rewrote legacy config keys" if config_changed
        if backfilled_count.positive?
          actions << "backfilled #{backfilled_count} task id#{backfilled_count == 1 ? '' : 's'}"
        end
        if recovery_marker_count.positive?
          actions << "upgraded #{recovery_marker_count} recovery marker#{recovery_marker_count == 1 ? '' : 's'}"
        end
        "hive: migrate #{actions.join(' and ')}"
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
        content, rewritten = rewrite_legacy_root_reviewers(content, path)
        changed ||= rewritten
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

      def rewrite_legacy_root_reviewers(content, path)
        lines = content.lines
        root_idx = lines.index { |line| ROOT_REVIEWERS_LINE.match?(line) }
        return [ content, false ] unless root_idx

        parsed = YAML.safe_load(content) || {}
        review_present = parsed.key?("review")
        normalized = Hive::Config.normalize_legacy_project_config(parsed, path, emit_warning: false)
        Hive::Config.build_project_config(@project_path, path, normalized)

        root_start_idx = root_idx
        while root_start_idx.positive? && lines[root_start_idx - 1].match?(/\A#/)
          root_start_idx -= 1
        end
        end_idx = ((root_idx + 1)...lines.length).find do |idx|
          line = lines[idx]
          !line.strip.empty? && line.match?(/\A\S/)
        end || lines.length
        root_block = lines.slice!(root_start_idx...end_idx)
        indented_root_block = root_block.map do |line|
          line.strip.empty? ? line : "  #{line}"
        end

        if review_present
          review_idx = lines.index { |line| REVIEW_BLOCK_LINE.match?(line) }
          unless review_idx
            raise Hive::ConfigError,
                  "cannot automatically migrate top-level `reviewers` in #{path} because " \
                  "`review` is not written as a block mapping; move the value to " \
                  "`review.reviewers` manually"
          end
          lines.insert(review_idx + 1, *indented_root_block)
        else
          lines.insert(root_start_idx, "review:\n", *indented_root_block)
        end

        [ lines.join, true ]
      rescue Psych::Exception => e
        raise Hive::ConfigError, "config.yml at #{path} is not valid YAML: #{e.message}"
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
      # running daemon still has stage-derived constants (including the
      # merge reconciler's supported PR-bearing stages) frozen at class-load
      # time from the OLD `Workflows::VERBS`. Restarting the daemon process
      # is the only way to refresh those constants (SIGHUP only re-reads YAML
      # config, not Ruby constants).
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
        Hive::ProcessKill.pid_alive?(pid)
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
