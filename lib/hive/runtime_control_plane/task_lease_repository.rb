require "securerandom"
require "time"
require "fileutils"
require "hive/runtime_control_plane"

module Hive
  module RuntimeControlPlane
    class TaskLeaseRepository
      DEFAULT_LEASE_SEC = 7 * 86_400
      MAX_RETRIES = 8
      MAX_PAYLOAD_BYTES = 16 * 1024

      attr_reader :database

      def initialize(database: RuntimeControlPlane.database,
                     clock: -> { Time.now.utc }, nonce: -> { SecureRandom.hex(16) },
                     process_start_time:, process_alive:)
        @database = database
        @clock = clock
        @nonce = nonce
        @process_start_time = process_start_time
        @process_alive = process_alive
      end

      def acquire(task_folder, payload, create: true)
        folder = File.expand_path(task_folder)
        if create
          FileUtils.mkdir_p(folder)
        elsif !File.directory?(folder)
          raise Errno::ENOENT, folder
        end
        subject = subject_for(folder, observe: true)
        data = { "started_at" => Codec.dump_time(@clock.call) }.merge(payload.transform_keys(&:to_s))
        data["pid"] = Process.pid
        data["process_start_time"] = @process_start_time.call(Process.pid)
        data["lock_id"] = @nonce.call
        data["task_id"] = subject.fetch(:task_id)
        payload_json = dump_payload(data)

        MAX_RETRIES.times do
          observed = read_row(subject.fetch(:task_id))
          if observed && observed[:holder_id] && holder_alive?(observed)
            raise contention(folder, observed)
          end
          claimed = claim(subject, observed, data, payload_json)
          return claimed if claimed
        end
        raise contention(folder, read_row(subject.fetch(:task_id)))
      end

      def release(task_folder, lock_id:)
        subject = subject_for(File.expand_path(task_folder))
        release_dataset(lock_id, task_id: subject.fetch(:task_id))
      rescue IdentityError
        release_dataset(lock_id)
      end

      def update(task_folder, additions, lock_id:)
        subject = subject_for(File.expand_path(task_folder))
        observed = read_row(subject.fetch(:task_id))
        return nil unless observed&.fetch(:holder_id, nil) == lock_id.to_s

        data = payload_from(observed).merge(additions.transform_keys(&:to_s))
        payload_json = dump_payload(data)
        @database.transaction do |db|
          updated = db[:task_leases].where(
            task_id: subject.fetch(:task_id), holder_id: lock_id.to_s,
            lease_version: observed.fetch(:lease_version)
          ).update(payload_json: payload_json)
          updated == 1 ? data : nil
        end
      end

      def clear_child(task_folder, pid:, process_start_time:, lock_id:)
        subject = subject_for(File.expand_path(task_folder))
        observed = read_row(subject.fetch(:task_id))
        return false unless observed&.fetch(:holder_id, nil) == lock_id.to_s

        data = payload_from(observed)
        return false unless data["claude_pid"] == pid
        return false unless data["claude_pid_start_time"].to_s == process_start_time.to_s

        data.delete("claude_pid")
        data.delete("claude_pid_start_time")
        payload_json = dump_payload(data)
        @database.transaction do |db|
          db[:task_leases].where(
            task_id: subject.fetch(:task_id), holder_id: lock_id.to_s,
            lease_version: observed.fetch(:lease_version)
          ).update(payload_json: payload_json) == 1
        end
      end

      def read(task_folder_or_lock)
        folder = File.expand_path(task_folder_or_lock.to_s)
        subject = subject_for(folder)
        row = read_row(subject.fetch(:task_id))
        row && row[:holder_id] ? payload_from(row) : nil
      rescue IdentityError, Errno::ENOENT
        nil
      end

      def active_leases(state_roots:, limit:)
        roots = Array(state_roots).map { |path| File.expand_path(path) }.uniq
        return [] if roots.empty?

        rows = @database.read do |db|
          db[:task_leases]
            .join(:task_subjects, task_id: :task_id)
            .join(:projects, project_id: :project_id)
            .where(Sequel[:projects][:state_root_path] => roots)
            .exclude(Sequel[:task_leases][:holder_id] => nil)
            .select(
              Sequel[:task_subjects][:task_id].as(:task_id),
              Sequel[:task_subjects][:task_slug].as(:task_slug),
              Sequel[:task_subjects][:workflow_id].as(:workflow_id),
              Sequel[:task_subjects][:observed_path].as(:observed_path),
              Sequel[:projects][:state_root_path].as(:state_root_path),
              Sequel[:task_leases][:payload_json].as(:payload_json)
            )
            .order(Sequel[:projects][:state_root_path], Sequel[:task_subjects][:task_id])
            .limit(Integer(limit))
            .all
        end
        rows.map do |row|
          row.merge(payload: payload_from(row), malformed: false)
        rescue CodecError
          row.merge(payload: nil, malformed: true)
        end
      end

      def lease_key(task_folder)
        require "hive/task_meta"
        task_id = Hive::TaskMeta.read(File.expand_path(task_folder))[:id]&.to_s
        raise IdentityError.new(
          "task metadata has no stable id", code: :missing_task_identity
        ) if task_id.to_s.empty?

        task_id
      end

      private

      def subject_for(folder, observe: false)
        require "hive/task_meta"
        metadata = Hive::TaskMeta.read(folder)
        task_id = metadata[:id]&.to_s
        raise IdentityError.new("task metadata has no stable id", code: :missing_task_identity) if task_id.to_s.empty?

        project = project_for(folder)
        if observe && !project
          raise IdentityError.new(
            "task folder is outside a registered state root",
            code: :missing_project_identity
          )
        end
        row = @database.read { |db| db[:task_subjects].where(task_id: task_id).first }
        row ||= register_subject(folder, task_id, metadata, project) if observe
        raise IdentityError.new(
          "task #{task_id} is not registered in the runtime control plane",
          code: :missing_task_identity
        ) unless row
        workflow_id = (metadata[:workflow] || "coding").to_s
        task_slug = (metadata[:slug] || File.basename(folder)).to_s
        if project && (row.fetch(:project_id) != project.fetch(:project_id) ||
                       row.fetch(:workflow_id) != workflow_id || row.fetch(:task_slug) != task_slug)
          raise IdentityError.new(
            "task #{task_id} belongs to a different registered subject",
            code: :task_identity_conflict
          )
        end
        if observe && row.fetch(:observed_path) != folder
          timestamp = Codec.dump_time(@clock.call)
          @database.transaction do |db|
            db[:task_subjects].where(task_id: task_id).update(
              observed_path: folder, last_observed_at: timestamp
            )
          end
          row = row.merge(observed_path: folder, last_observed_at: timestamp)
        end
        { task_id: task_id, generation: row.fetch(:generation),
          source_fingerprint: row[:source_fingerprint].to_s }
      end

      def register_subject(folder, task_id, metadata, project)
        workflow_id = (metadata[:workflow] || "coding").to_s
        task_slug = (metadata[:slug] || File.basename(folder)).to_s
        timestamp = Codec.dump_time(@clock.call)
        @database.transaction do |db|
          historical = db[:task_subjects].where(
            project_id: project.fetch(:project_id), workflow_id: workflow_id,
            task_slug: task_slug
          ).first
          if historical && historical.fetch(:task_id) != task_id
            raise IdentityError.new(
              "task alias #{task_slug} is already bound to #{historical.fetch(:task_id)}",
              code: :task_identity_conflict
            )
          end
          db[:task_subjects].insert_conflict.insert(
            task_id: task_id, project_id: project.fetch(:project_id),
            workflow_id: workflow_id, task_slug: task_slug, observed_path: folder,
            source_fingerprint: "", generation: 0,
            created_at: timestamp, last_observed_at: timestamp
          )
          row = db[:task_subjects].where(task_id: task_id).first
          if row && row.fetch(:project_id) != project.fetch(:project_id)
            raise IdentityError.new(
              "task #{task_id} belongs to a different registered project",
              code: :task_identity_conflict
            )
          end
          row
        end
      end

      def project_for(folder)
        stage_directory = File.dirname(folder)
        stages_directory = File.dirname(stage_directory)
        return unless File.basename(stages_directory) == "stages"
        return if File.basename(stage_directory).empty? || File.basename(folder).empty?

        state_root = File.dirname(stages_directory)
        @database.read { |db| db[:projects].where(state_root_path: state_root).first }
      end

      def release_dataset(lock_id, task_id: nil)
        timestamp = Codec.dump_time(@clock.call)
        @database.transaction do |db|
          dataset = db[:task_leases].where(holder_id: lock_id.to_s)
          dataset = dataset.where(task_id: task_id) if task_id
          updated = dataset.update(
            holder_kind: nil, holder_id: nil, holder_pid: nil,
            holder_process_identity: nil, payload_json: "{}",
            acquired_at: nil, expires_at: nil, released_at: timestamp
          )
          updated == 1
        end
      end

      def read_row(task_id)
        @database.read { |db| db[:task_leases].where(task_id: task_id).first }
      end

      def claim(subject, observed, data, payload_json)
        timestamp = Codec.dump_time(@clock.call)
        expiry = Codec.dump_time(@clock.call + DEFAULT_LEASE_SEC)
        values = {
          holder_kind: data["op"] || data["operation"] || "task_run",
          holder_id: data.fetch("lock_id"), holder_pid: data.fetch("pid"),
          holder_process_identity: data["process_start_time"], payload_json: payload_json,
          generation: subject.fetch(:generation),
          source_fingerprint: subject.fetch(:source_fingerprint),
          acquired_at: timestamp, expires_at: expiry, released_at: nil
        }
        claimed = false
        @database.transaction do |db|
          dataset = db[:task_leases].where(task_id: subject.fetch(:task_id))
          if observed
            claimed = dataset.where(
              lease_version: observed.fetch(:lease_version), holder_id: observed[:holder_id]
            ).update(
              lease_version: observed.fetch(:lease_version) + 1,
              **values
            ) == 1
          else
            begin
              dataset.insert(
                task_id: subject.fetch(:task_id), lease_version: 1, **values
              )
              claimed = true
            rescue Sequel::UniqueConstraintViolation
              claimed = false
            end
          end
        end
        data if claimed
      end

      def payload_from(row)
        value = Codec.load_json(bounded_payload(row.fetch(:payload_json).to_s))
        raise CodecError.new(
          "task lease payload is not an object", code: :json_invalid
        ) unless value.is_a?(Hash)

        value
      end

      def dump_payload(value) = bounded_payload(Codec.dump_json(value))

      def bounded_payload(payload)
        raise CodecError.new(
          "task lease payload exceeds its size bound", code: :json_invalid
        ) if payload.bytesize > MAX_PAYLOAD_BYTES

        payload
      end

      def holder_alive?(row)
        @process_alive.call(
          row.fetch(:holder_pid), recorded_start_time: row[:holder_process_identity]
        )
      rescue StandardError
        true
      end

      def contention(folder, row)
        holder = row && payload_from(row)
        ConcurrentRunError.new(
          "another hive run is active for #{folder}", holder: holder,
          lock_path: "runtime-control-plane:task:#{row&.fetch(:task_id, "unknown")}"
        )
      end
    end
  end
end
