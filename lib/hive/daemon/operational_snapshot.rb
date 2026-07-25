require "digest"
require "fileutils"
require "json"
require "time"
require "yaml"

require "hive/agent_limit"
require "hive/atomic_file"
require "hive/lock"
require "hive/paths"
require "hive/recovery"

module Hive
  module Daemon
    # Private daemon-to-CLI observation channel. The dispatcher is the only
    # writer; status and watch are read-only consumers. A record is useful for
    # decisions only when it belongs to the live daemon generation, has phase
    # `complete`, and has not passed its short validity deadline.
    module OperationalSnapshot
      SCHEMA = "hive-daemon-operational-snapshot".freeze
      SCHEMA_VERSION = 1
      PHASES = %w[started failed complete].freeze
      MAX_VALIDITY_MULTIPLIER = 3

      class SecurityError < StandardError; end

      module_function

      def daemon_identity(pid:, process_start_time:)
        seed = "#{Integer(pid)}\0#{process_start_time}"
        {
          "generation" => ::Digest::SHA256.hexdigest(seed),
          "pid" => Integer(pid),
          "process_start_time" => process_start_time.to_s
        }
      end

      # Owner-private atomic persistence. The dedicated parent directory and
      # final inode are both checked before and after replacement so a symlink
      # or permissive path never becomes an authority source.
      class Store
        attr_reader :path

        def initialize(path: Hive::Paths.operational_snapshot_path)
          @path = File.expand_path(path)
        end

        def write(record)
          secure_parent!
          secure_target!
          Hive::AtomicFile.write(path, "#{JSON.generate(record)}\n", mode: 0o600)
          secure_target!(required: true)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
          path
        end

        private

        def secure_parent!
          parent = File.dirname(path)
          if lexical_entry?(parent)
            stat = File.lstat(parent)
            reject!("snapshot directory is a symlink") if stat.symlink?
            reject!("snapshot parent is not a directory") unless stat.directory?
          else
            FileUtils.mkdir_p(parent, mode: 0o700)
          end
          File.chmod(0o700, parent)
          stat = File.lstat(parent)
          reject!("snapshot directory is not owned by the current user") unless stat.uid == Process.uid
          reject!("snapshot directory is not owner-private") unless (stat.mode & 0o077).zero?
        end

        def secure_target!(required: false)
          unless lexical_entry?(path)
            reject!("snapshot file disappeared during publication") if required
            return
          end

          stat = File.lstat(path)
          reject!("snapshot file is a symlink") if stat.symlink?
          reject!("snapshot path is not a regular file") unless stat.file?
          reject!("snapshot file has multiple hard links") unless stat.nlink == 1
          reject!("snapshot file is not owned by the current user") unless stat.uid == Process.uid
          reject!("snapshot file is not owner-private") unless (stat.mode & 0o077).zero?
        end

        def lexical_entry?(candidate)
          File.exist?(candidate) || File.symlink?(candidate)
        end

        def reject!(message)
          raise SecurityError, "#{message}: #{path}"
        end
      end

      # Builds one coherent tick record. Decisions are captured in memory as
      # the dispatcher evaluates rows, then joined only after a second status
      # read proves the task identity/generation/stage/marker did not change.
      class Assembler
        attr_reader :tick_sequence

        def initialize(store:, daemon_identity:, poll_interval_sec:)
          @store = store
          @daemon_identity = stringify_keys(daemon_identity)
          reconfigure(poll_interval_sec: poll_interval_sec)
          @tick_sequence = 0
          @started_at = nil
          @observations = {}
        end

        def reconfigure(poll_interval_sec:)
          @validity_sec = [ Integer(poll_interval_sec), 1 ].max * MAX_VALIDITY_MULTIPLIER
        end

        def begin_tick(now: Time.now.utc)
          @tick_sequence += 1
          @started_at = now.utc
          @observations = {}
          @store.write(base_record(phase: "started", now: now).merge("tasks" => []))
          tick_sequence
        end

        def observe(row, decision:, owner:, reason:, **details)
          @observations[row_key(row)] = {
            "status" => "available",
            "decision" => decision.to_s,
            "owner" => owner.to_s,
            "reason" => reason.to_s
          }.merge(details.transform_keys(&:to_s))
        end

        def fail(reason:, now: Time.now.utc)
          @store.write(
            base_record(phase: "failed", now: now).merge(
              "reason" => reason.to_s,
              "capacity" => nil,
              "queue" => nil,
              "provider_holds" => [],
              "recoveries" => {},
              "tasks" => []
            )
          )
        end

        def complete(initial_rows:, final_rows:, controller:, queue:, recoveries:, now: Time.now.utc)
          initial_rows = Array(initial_rows)
          final_rows = Array(final_rows)
          duplicate_keys = duplicate_row_keys(initial_rows) | duplicate_row_keys(final_rows)
          unless duplicate_keys.empty?
            identities = duplicate_keys.sort.map { |project, slug| "#{project}:#{slug}" }
            return fail(reason: "duplicate_task_identity: #{identities.join(', ')}", now: now)
          end

          tasks = revalidated_tasks(initial_rows, final_rows)
          task_index = tasks.to_h do |task|
            [ [ task.dig("identity", "project"), task.dig("identity", "slug") ], task ]
          end
          holds = provider_holds(final_rows)
          overlay_provider_dispositions!(task_index, holds)
          overlay_recovery_dispositions!(task_index, recoveries || {})
          @store.write(
            base_record(phase: "complete", now: now).merge(
              "reason" => nil,
              "capacity" => controller || {},
              "queue" => queue || {},
              "provider_holds" => holds,
              "recoveries" => recoveries || {},
              "tasks" => tasks
            )
          )
        end

        private

        def base_record(phase:, now:)
          instant = now.utc
          {
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "phase" => phase,
            "tick_sequence" => tick_sequence,
            "daemon" => @daemon_identity,
            "observed_at" => instant.iso8601(6),
            "valid_until" => (instant + @validity_sec).iso8601(6),
            "source_window" => {
              "started_at" => (@started_at || instant).utc.iso8601(6),
              "completed_at" => phase == "started" ? nil : instant.iso8601(6)
            }
          }
        end

        def revalidated_tasks(initial_rows, final_rows)
          initial = initial_rows.to_h { |row| [ row_key(row), row ] }
          final = final_rows.to_h { |row| [ row_key(row), row ] }
          initial_records = initial.transform_values { |row| task_record(row) }
          final_records = final.transform_values { |row| task_record(row) }
          (initial.keys | final.keys).sort.map do |key|
            before = initial[key]
            after = final[key]
            before_record = initial_records[key]
            after_record = final_records[key]
            disposition = if before.nil?
              unavailable("added_during_tick")
            elsif after.nil?
              unavailable("removed_during_tick")
            elsif record_fingerprint(before_record) != record_fingerprint(after_record)
              unavailable("changed_during_tick")
            else
              @observations.fetch(
                key,
                {
                  "status" => "available",
                  "decision" => "not_evaluated",
                  "owner" => "scheduler",
                  "reason" => "no dispatch decision was required"
                }
              )
            end
            (after_record || before_record).merge("disposition" => disposition)
          end
        end

        def unavailable(reason)
          { "status" => "unavailable", "decision" => nil, "owner" => "unknown", "reason" => reason }
        end

        def task_record(row)
          {
            "identity" => {
              "project" => value(row, :project).to_s,
              "slug" => value(row, :slug).to_s,
              "folder" => value(row, :folder).to_s
            },
            "workflow" => nullable_string(value(row, :workflow)),
            "stage" => value(row, :stage).to_s,
            "marker" => value(row, :marker).to_s,
            "marker_attrs" => canonical(value(row, :marker_attrs) || {}),
            "task_generation" => nullable_string(value(row, :task_generation)),
            "condition_task_generation" => nullable_string(value(row, :condition_task_generation)),
            "commit_generation" => value(row, :commit_generation),
            "attempt_id" => nullable_string(value(row, :attempt_id)),
            "state_file_mtime" => time_string(value(row, :state_file_mtime)),
            "action" => nullable_string(value(row, :action)),
            "depends_on" => nullable_string(value(row, :depends_on)),
            "blocked_by" => nullable_string(value(row, :blocked_by)),
            "dependency_stage" => nullable_string(value(row, :dependency_stage)),
            "blocked" => value(row, :blocked) == true,
            "admission_error" => canonical_record(value(row, :admission_error))
          }
        end

        def record_fingerprint(record)
          ::Digest::SHA256.hexdigest(JSON.generate(record))
        end

        def row_key(row)
          [ value(row, :project).to_s, value(row, :slug).to_s ]
        end

        def duplicate_row_keys(rows)
          rows.group_by { |row| row_key(row) }
              .select { |_key, grouped_rows| grouped_rows.size > 1 }
              .keys
        end

        def provider_holds(rows)
          Array(rows).filter_map do |row|
            attrs = value(row, :marker_attrs)
            next unless attrs.is_a?(Hash)
            next unless Hive::AgentLimit.held?(value(row, :marker), attrs)

            {
              "project" => value(row, :project).to_s,
              "slug" => value(row, :slug).to_s,
              "provider" => Hive::AgentLimit.held_provider(attrs),
              "retry_after" => Hive::AgentLimit.retry_after_time(attrs)&.iso8601
            }
          end
        end

        def overlay_recovery_dispositions!(task_index, recoveries)
          coordinator = recoveries.fetch("coordinator", {})
          Array(coordinator["receipts"]).each do |entry|
            task = find_recovery_task(task_index, entry)
            next unless task

            receipt = entry["receipt"]
            next unless receipt.is_a?(Hash)

            status = receipt["status"].to_s
            task["disposition"] = {
              "status" => "available",
              "decision" => {
                "queued" => "retry_pending",
                "cooldown" => "retry_cooldown",
                "running" => "retry_in_flight",
                "blocked" => "retry_safety_blocked",
                "terminal" => "attempt_terminal_replay",
                "unavailable" => "recovery_unavailable"
              }.fetch(status, "recovery_unavailable"),
              "owner" => receipt["owner"] || "hive",
              "reason" => receipt["reason"] || status.tr("_", " "),
              "recovery" => receipt
            }
          end
        end

        def overlay_provider_dispositions!(task_index, holds)
          holds.each do |hold|
            task = find_task(task_index, hold)
            next unless task && task.dig("disposition", "status") == "available"

            provider = hold["provider"] || "provider"
            suffix = hold["retry_after"] ? " until #{hold.fetch('retry_after')}" : ""
            task["disposition"] = {
              "status" => "available",
              "decision" => "provider_hold",
              "owner" => "provider",
              "reason" => "#{provider} quota hold#{suffix}"
            }
          end
        end

        def find_task(task_index, identity)
          key = [ identity["project"].to_s, identity["slug"].to_s ]
          task = task_index[key]
          return unless task
          return unless identity["stage"].to_s.empty? || task["stage"] == identity["stage"].to_s
          return unless identity["reason"].to_s.empty? ||
                        task.dig("marker_attrs", "reason").to_s == identity["reason"].to_s

          task
        end

        def find_recovery_task(task_index, identity)
          task = find_task(task_index, identity)
          return unless task

          phase = identity["recovery_phase"].to_s
          if phase == "admitted"
            return unless task["marker"].to_s == identity["expected_marker_name"].to_s

            expected = identity["expected_marker_attrs"]
            if expected.is_a?(Hash)
              return unless expected.all? do |key, value|
                task.dig("marker_attrs", key.to_s).to_s == value.to_s
              end
            end
          elsif %w[cleared dispatched].include?(phase)
            # Once the original marker is gone, a fresh ERROR/REVIEW_ERROR is
            # a new recovery generation. Do not let an older terminal receipt
            # hide that generation's cooldown/action.
            return unless %w[none agent_working].include?(task["marker"].to_s)
          elsif phase == "terminal"
            # A completed attempt normally leaves a meaningful workflow marker
            # (WAITING, COMPLETE, REVIEW_COMPLETE, and similar). Preserve its
            # terminal receipt unless a fresh recoverable failure now owns the
            # task.
            return if Hive::Recovery.recoverable_marker?(task["marker"])
          end

          task
        end

        def value(row, name)
          return row.public_send(name) if row.respond_to?(name)
          return row[name] if row.respond_to?(:key?) && row.key?(name)
          return row[name.to_s] if row.respond_to?(:key?) && row.key?(name.to_s)

          nil
        end

        def stringify_keys(hash)
          hash.to_h.transform_keys(&:to_s)
        end

        def nullable_string(value)
          value.nil? ? nil : value.to_s
        end

        def time_string(value)
          return nil if value.nil?
          return value.utc.iso8601(6) if value.respond_to?(:utc)

          value.to_s
        end

        def canonical(value)
          case value
          when Hash
            value.keys.map(&:to_s).sort.to_h do |key|
              original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
              [ key, canonical(value[original]) ]
            end
          when Array then value.map { |entry| canonical(entry) }
          when Time then value.utc.iso8601(6)
          else value
          end
        end

        def canonical_record(value)
          value = value.to_h if value && !value.is_a?(Hash) && value.respond_to?(:to_h)
          canonical(value)
        end
      end

      # Defensive reader that converts every non-authoritative condition into
      # an explicit status. It never raises into `hive status`.
      class Reader
        AUTO_DAEMON = Object.new.freeze

        def initialize(path: Hive::Paths.operational_snapshot_path,
                       expected_daemon: AUTO_DAEMON,
                       pid_path: File.join(Hive::Paths.state_home, ".daemon.pid"))
          @path = File.expand_path(path)
          @expected_daemon = expected_daemon
          @pid_path = File.expand_path(pid_path)
        end

        def read(now: Time.now.utc)
          expected = expected_daemon
          return unavailable("daemon_not_running") if expected == :unavailable

          validate_path!
          record = JSON.parse(File.read(@path))
          validate_record!(record)
          return invalid("daemon_generation_mismatch", record) unless daemon_matches?(record, expected)
          return unavailable(record["reason"] || "tick_#{record.fetch('phase')}", record) unless
            record["phase"] == "complete"
          return stale("snapshot_expired", record) if Time.parse(record.fetch("valid_until")) < now

          record.merge("status" => "current")
        rescue Errno::ENOENT
          unavailable("snapshot_missing")
        rescue SecurityError => e
          invalid("snapshot_path_unsafe", nil, e.message)
        rescue JSON::ParserError, ArgumentError, TypeError, KeyError => e
          invalid("snapshot_invalid", nil, "#{e.class}: #{e.message}")
        rescue SystemCallError, IOError => e
          unavailable("snapshot_unreadable", nil, "#{e.class}: #{e.message}")
        end

        private

        def expected_daemon
          return @expected_daemon unless @expected_daemon.equal?(AUTO_DAEMON)

          load_live_daemon_identity
        end

        def load_live_daemon_identity
          return :unavailable unless File.file?(@pid_path) && !File.symlink?(@pid_path)

          payload = YAML.safe_load(File.read(@pid_path))
          return :unavailable unless payload.is_a?(Hash)

          pid = payload["pid"]
          start_time = payload["process_start_time"]
          return :unavailable unless pid.is_a?(Integer) && pid.positive? && !start_time.to_s.empty?

          Process.kill(0, pid)
          live_start = Hive::Lock.process_start_time(pid)
          return :unavailable unless live_start && live_start.to_s == start_time.to_s

          OperationalSnapshot.daemon_identity(pid: pid, process_start_time: start_time)
        rescue Errno::ESRCH, Errno::EPERM, Psych::Exception, SystemCallError
          :unavailable
        end

        def validate_path!
          parent = File.dirname(@path)
          parent_stat = File.lstat(parent)
          raise SecurityError, "snapshot directory is a symlink" if parent_stat.symlink?
          raise SecurityError, "snapshot parent is not a directory" unless parent_stat.directory?
          raise SecurityError, "snapshot directory has unsafe ownership" unless parent_stat.uid == Process.uid
          raise SecurityError, "snapshot directory is not owner-private" unless (parent_stat.mode & 0o077).zero?

          stat = File.lstat(@path)
          raise SecurityError, "snapshot file is a symlink" if stat.symlink?
          raise SecurityError, "snapshot path is not a regular file" unless stat.file?
          raise SecurityError, "snapshot file has multiple hard links" unless stat.nlink == 1
          raise SecurityError, "snapshot file has unsafe ownership" unless stat.uid == Process.uid
          raise SecurityError, "snapshot file is not owner-private" unless (stat.mode & 0o077).zero?
        end

        def validate_record!(record)
          raise ArgumentError, "record must be an object" unless record.is_a?(Hash)
          raise ArgumentError, "wrong snapshot schema" unless record["schema"] == SCHEMA
          raise ArgumentError, "unsupported snapshot schema version" unless record["schema_version"] == SCHEMA_VERSION
          raise ArgumentError, "invalid snapshot phase" unless PHASES.include?(record["phase"])
          raise ArgumentError, "invalid tick sequence" unless record["tick_sequence"].is_a?(Integer)
          raise ArgumentError, "invalid daemon identity" unless record["daemon"].is_a?(Hash)
          Time.parse(record.fetch("observed_at"))
          Time.parse(record.fetch("valid_until"))
        end

        def daemon_matches?(record, expected)
          return false unless expected.is_a?(Hash)

          %w[generation pid process_start_time].all? do |key|
            record.dig("daemon", key).to_s == expected[key].to_s
          end
        end

        def unavailable(reason, record = nil, detail = nil)
          fallback("unavailable", reason, record, detail)
        end

        def stale(reason, record, detail = nil)
          fallback("stale", reason, record, detail)
        end

        def invalid(reason, record = nil, detail = nil)
          fallback("invalid", reason, record, detail)
        end

        def fallback(status, reason, record, detail)
          base = record.is_a?(Hash) ? record : {}
          base.merge(
            "status" => status,
            "reason" => reason,
            "detail" => detail,
            "phase" => base["phase"],
            "observed_at" => base["observed_at"],
            "valid_until" => base["valid_until"],
            "tick_sequence" => base["tick_sequence"],
            "capacity" => nil,
            "queue" => nil,
            "provider_holds" => [],
            "tasks" => []
          )
        end
      end
    end
  end
end
