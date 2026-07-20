require "digest"
require "fileutils"
require "json"
require "time"
require "yaml"

require "hive/agent_limit"
require "hive/atomic_file"
require "hive/lock"
require "hive/paths"

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
          @validity_sec = [ Integer(poll_interval_sec), 1 ].max * MAX_VALIDITY_MULTIPLIER
          @tick_sequence = 0
          @started_at = nil
          @observations = {}
        end

        def begin_tick(now: Time.now.utc)
          @tick_sequence += 1
          @started_at = now.utc
          @observations = {}
          @store.write(base_record(phase: "started", now: now).merge("tasks" => []))
          tick_sequence
        end

        def observe(row, decision:, owner:, reason:)
          @observations[row_key(row)] = {
            "status" => "available",
            "decision" => decision.to_s,
            "owner" => owner.to_s,
            "reason" => reason.to_s
          }
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
          tasks = revalidated_tasks(Array(initial_rows), Array(final_rows))
          holds = provider_holds(final_rows)
          overlay_recovery_dispositions!(tasks, recoveries || {})
          overlay_provider_dispositions!(tasks, holds)
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
          (initial.keys | final.keys).sort.map do |key|
            before = initial[key]
            after = final[key]
            disposition = if before.nil?
              unavailable("added_during_tick")
            elsif after.nil?
              unavailable("removed_during_tick")
            elsif row_fingerprint(before) != row_fingerprint(after)
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
            task_record(after || before).merge("disposition" => disposition)
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
            "state_file_mtime" => time_string(value(row, :state_file_mtime))
          }
        end

        def row_fingerprint(row)
          ::Digest::SHA256.hexdigest(JSON.generate(task_record(row)))
        end

        def row_key(row)
          [ value(row, :project).to_s, value(row, :slug).to_s ]
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

        def overlay_recovery_dispositions!(tasks, recoveries)
          stale = recoveries.fetch("stale_agent", {})
          generic = recoveries.fetch("recoverable_error", {})
          exhausted = Array(stale["error_exhausted"]) +
                      Array(stale["review_exhausted"]) +
                      Array(generic["exhausted"])
          exhausted.each do |entry|
            task = find_task(tasks, entry)
            next unless task && task.dig("disposition", "status") == "available"

            task["disposition"] = {
              "status" => "available",
              "decision" => "recovery_exhausted",
              "owner" => "operator",
              "reason" => "automatic recovery budget is exhausted"
            }
          end
        end

        def overlay_provider_dispositions!(tasks, holds)
          holds.each do |hold|
            task = find_task(tasks, hold)
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

        def find_task(tasks, identity)
          tasks.find do |task|
            task.dig("identity", "project") == identity["project"].to_s &&
              task.dig("identity", "slug") == identity["slug"].to_s
          end
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
