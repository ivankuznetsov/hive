require "digest"
require "json"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/operational_payload_store"

module Hive
  module RuntimeControlPlane
    # Owns one daemon observation and its optional derived status projection.
    #
    # The scheduler snapshot and the projection envelope (daemon, tick,
    # deadlines, payload reference) share one row, so source binding cannot
    # drift across transactions. The multi-MB `hive-status` payload body is
    # not in that row: SQLite rewrites a whole row on update, so carrying it
    # there made every tick write megabytes under the shared write lock.
    # The body is a content-addressed file written before the lock, and only
    # when its non-volatile content changes. `generated_at` and per-task
    # `age_seconds` move every tick without a material change, so they ride
    # in the row's reference and are restored on read. Readers verify the
    # file's size and SHA-256 against the committed reference and fail closed.
    class OperationalRepository
      PAYLOAD_REFERENCE = "payload_reference".freeze
      VOLATILE_PAYLOAD_KEY = "generated_at".freeze
      VOLATILE_TASK_KEY = "age_seconds".freeze
      TASK_AGES = "task_age_seconds".freeze
      # The current payload plus the two before it, so a reader that loaded
      # the previous row can still open its file after a content change.
      RETAINED_PAYLOADS = 3

      def initialize(database: RuntimeControlPlane.database, payload_store: nil)
        @database = database
        @payload_store = payload_store
        @retained_digests = []
      end

      def publish(snapshot, status_projection: nil)
        validate_projection!(snapshot, status_projection) if status_projection
        # Encode and write the payload file before taking the write lock. The
        # status payload is several MB; canonical encoding inside BEGIN
        # IMMEDIATE held the lock every attempt heartbeat and CLI write waits
        # on for seconds per tick on a swapping host.
        stored_projection, digest = stored_projection(status_projection)
        document = { "snapshot" => snapshot, "status_projection" => stored_projection }
        observation_json = Codec.dump_json(document)
        @database.transaction(operation: "operational.publish") do |db|
          installation_id = db[:installations].get(:installation_id) ||
            raise(IntegrityError.new("runtime installation identity is missing", code: :identity_missing))
          values = { installation_id: installation_id, observation_json: observation_json }
          db[:daemon_runtime].insert_conflict(
            target: :installation_id, update: values
          ).insert(values)
        end
        retain_payload(digest) if digest
        true
      end

      def snapshot = read_document&.fetch("snapshot")
      def status_projection
        document = read_document
        projection = document && document["status_projection"]
        return projection unless projection

        validate_projection!(document.fetch("snapshot"), projection)
        loaded_projection(projection)
      end

      private

      def payload_store
        @payload_store ||= OperationalPayloadStore.new(
          root: Hive::Paths.operational_status_payload_root(File.dirname(@database.path))
        )
      end

      def read_document
        @database.read do |db|
          row = db[:daemon_runtime].first
          row && decode(row.fetch(:observation_json))
        end
      end

      def validate_projection!(snapshot, projection)
        valid = snapshot.fetch("phase") == "complete" &&
          projection.fetch("tick_sequence") == snapshot.fetch("tick_sequence") &&
          projection.fetch("daemon") == snapshot.fetch("daemon")
        raise IntegrityError.new("operational projection source binding differs",
                                 code: :projection_source_mismatch) unless valid
        true
      rescue KeyError, TypeError
        raise IntegrityError.new("operational projection source binding is invalid",
                                 code: :projection_source_invalid)
      end

      # Returns the row form of a projection and the digest of its payload
      # file. A projection without a payload object is stored inline. When the
      # file cannot be written the row carries no projection: readers then
      # compute status live instead of trusting a reference to missing bytes.
      def stored_projection(projection)
        payload = projection && projection["payload"]
        return [ projection, nil ] unless payload.is_a?(Hash)

        body, volatile = split_volatile(payload)
        bytes = Codec.dump_json(body)
        digest = Digest::SHA256.hexdigest(bytes)
        begin
          payload_store.write(digest, bytes)
        rescue SystemCallError, IOError => error
          report_unavailable_payload(error)
          return [ nil, nil ]
        end
        reference = volatile.merge("sha256" => digest, "bytes" => bytes.bytesize)
        [ projection.except("payload").merge(PAYLOAD_REFERENCE => reference), digest ]
      end

      def split_volatile(payload)
        volatile = payload.key?(VOLATILE_PAYLOAD_KEY) ? { VOLATILE_PAYLOAD_KEY => payload[VOLATILE_PAYLOAD_KEY] } : {}
        body = payload.except(VOLATILE_PAYLOAD_KEY)
        projects = body["projects"]
        return [ body, volatile ] unless projects.is_a?(Array)

        ages = []
        stable_projects = projects.each_with_index.map do |project, project_index|
          tasks = project.is_a?(Hash) ? project["tasks"] : nil
          next project unless tasks.is_a?(Array)

          stable_tasks = tasks.each_with_index.map do |task, task_index|
            next task unless task.is_a?(Hash) && task.key?(VOLATILE_TASK_KEY)

            ages << [ project_index, task_index, task[VOLATILE_TASK_KEY] ]
            task.except(VOLATILE_TASK_KEY)
          end
          project.merge("tasks" => stable_tasks)
        end
        volatile[TASK_AGES] = ages unless ages.empty?
        [ body.merge("projects" => stable_projects), volatile ]
      end

      def loaded_projection(projection)
        return projection unless projection.key?(PAYLOAD_REFERENCE)

        reference = projection.fetch(PAYLOAD_REFERENCE)
        unless reference.is_a?(Hash) && !projection.key?("payload")
          invalid_payload!("operational projection payload reference is invalid")
        end
        body = decode(payload_store.read(reference["sha256"], reference["bytes"]))
        payload = restore_volatile(body, reference)
        sorted(projection.except(PAYLOAD_REFERENCE).merge("payload" => payload))
      end

      # Restores per-tick fields into the verified body. The body's digest
      # pins its project/task layout, so positional entries cannot shift.
      def restore_volatile(body, reference)
        invalid_payload!("operational projection payload is not an object") unless body.is_a?(Hash)

        payload = body
        if reference.key?(VOLATILE_PAYLOAD_KEY)
          payload = sorted(body.merge(VOLATILE_PAYLOAD_KEY => reference[VOLATILE_PAYLOAD_KEY]))
        end
        ages = reference.fetch(TASK_AGES, [])
        invalid_payload!("operational projection task ages are invalid") unless ages.is_a?(Array)

        ages.each do |entry|
          project_index, task_index, age = entry
          unless entry.is_a?(Array) && entry.size == 3 &&
                 [ project_index, task_index ].all? { |index| index.is_a?(Integer) && !index.negative? }
            invalid_payload!("operational projection task ages are invalid")
          end
          tasks = payload.fetch("projects").fetch(project_index).fetch("tasks")
          task = tasks.fetch(task_index)
          invalid_payload!("operational projection task ages are invalid") if task.key?(VOLATILE_TASK_KEY)

          tasks[task_index] = sorted(task.merge(VOLATILE_TASK_KEY => age))
        end
        payload
      rescue IndexError, TypeError, NoMethodError
        invalid_payload!("operational projection task ages do not match the payload")
      end

      def retain_payload(digest)
        return if @retained_digests.first == digest

        @retained_digests = [ digest, *@retained_digests ].uniq.first(RETAINED_PAYLOADS)
        payload_store.prune(keep: @retained_digests)
      end

      # Codec output is key-sorted; keep restored objects in the same order.
      def sorted(hash) = hash.sort.to_h

      def report_unavailable_payload(error)
        warn JSON.generate(
          event: "operational_projection_unavailable", level: "warning",
          error_class: error.class.name, message: error.message.to_s.byteslice(0, 240)
        )
      rescue StandardError
        nil
      end

      def invalid_payload!(message)
        raise IntegrityError.new(message, code: :projection_payload_invalid)
      end

      def decode(value)
        Codec.load_json(value)
      rescue CodecError => error
        raise IntegrityError.new("operational projection is invalid: #{error.message}",
                                 code: :projection_invalid, details: { codec_code: error.code })
      end
    end
  end
end
