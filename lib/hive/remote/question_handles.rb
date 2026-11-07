# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "hive/atomic_file"
require "hive/paths"
require "hive/remote/errors"

module Hive
  module Remote
    # Private read identities only. These records convey no mutation admission
    # or result authority; durable commands continue to use CommandReceiptStore.
    # Original native answer bindings stay server-side so receipt replay remains
    # possible even when a task has advanced since the handle was issued.
    class QuestionHandles
      attr_reader :path

      def initialize(root: File.join(Hive::Paths.state_home, "remote-access"))
        @root = root
        @path = File.join(root, "read-handles.json")
      end

      def issue(project:, task:, inventory:)
        locked do |data|
          dirty = false
          identities = data.fetch("handles").to_h { |handle, record| [record, handle] }
          slots = Array(inventory["slots"]).map do |slot|
            record = target(project, task).merge(
              "kind" => "question", "generation" => inventory.fetch("task").fetch("generation"),
              "ordinal" => slot.fetch("ordinal"), "fingerprint" => slot.fetch("fingerprint"),
              "round" => slot["round"], "question_number" => slot["question_number"],
              "binding" => slot.fetch("binding")
            )
            existing = identities[record]
            handle = existing || SecureRandom.hex(32)
            unless existing
              data.fetch("handles")[handle] = record
              identities[record] = handle
              dirty = true
            end
            slot.slice("ordinal", "round", "question_number", "text", "answered", "answer").merge("handle" => handle)
          end
          persist(data) if dirty
          slots
        end
      end

      def resolve(handle:, project:, task:)
        record = lookup(handle, "question")
        not_found! unless target(project, task).all? { |key, value| record[key] == value }
        record
      end

      def current!(record:, inventory:)
        slot = Array(inventory["slots"]).find { |entry| entry["ordinal"] == record["ordinal"] }
        current = inventory.fetch("task")
        unless current["generation"] == record["generation"] && current["id"] == record["task_id"] &&
               current["slug"] == record["task_slug"] && current["project"] == record["project"] &&
               slot && slot["fingerprint"] == record["fingerprint"] && slot["binding"] == record["binding"]
          stale!
        end
        true
      end

      def artifact(project:, task:, generation:, reference:)
        remember("artifact", target(project, task).merge("generation" => generation, "reference" => reference))
      end

      def resolve_artifact(handle:, project:, task:, generation:)
        record = lookup(handle, "artifact")
        not_found! unless target(project, task).all? { |key, value| record[key] == value }
        stale! unless record["generation"] == generation
        record.fetch("reference")
      end

      def cursor(projects:, snapshot:, offset:)
        remember("cursor", { "projects" => projects, "snapshot" => snapshot, "offset" => offset })
      end

      def resolve_cursor(handle:, projects:, snapshot:)
        record = lookup(handle, "cursor")
        not_found! unless record["projects"] == projects
        stale! unless record["snapshot"] == snapshot
        record.fetch("offset")
      end

      private

      def target(project, task)
        { "project" => project.fetch("name"), "task_id" => task.id, "task_slug" => task.slug }
      end

      def remember(kind, identity)
        locked do |data|
          record = identity.merge("kind" => kind)
          existing = data.fetch("handles").find { |_, value| value == record }
          next existing.first if existing
          handle = SecureRandom.hex(32)
          data.fetch("handles")[handle] = record
          persist(data)
          handle
        end
      end

      def persist(data)
        Hive::AtomicFile.write(path, JSON.generate(data), mode: 0o600)
        Hive::AtomicFile.fsync_directory(@root)
      end

      def lookup(handle, kind)
        not_found! unless handle.to_s.match?(/\A[0-9a-f]{64}\z/)
        locked do |data|
          record = data.fetch("handles")[handle]
          not_found! unless record.is_a?(Hash) && record["kind"] == kind
          record
        end
      end

      def locked
        FileUtils.mkdir_p(@root, mode: 0o700)
        stat = File.lstat(@root)
        unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
          raise Hive::ConfigError, "remote read identities require an operator-owned directory"
        end
        File.chmod(0o700, @root)
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(File.join(@root, ".read-handles.lock"), flags, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield read
        ensure
          lock.flock(File::LOCK_UN)
        end
      rescue Errno::ELOOP
        raise Hive::ConfigError, "remote read identity files cannot use symlinks"
      end

      def read
        return { "schema_version" => 1, "handles" => {} } unless File.exist?(path)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise Hive::ConfigError, "remote read identity registry must be an owner-only regular file"
        end
        data = JSON.parse(File.read(path))
        if data.is_a?(Hash) && data["schema_version"].is_a?(Integer) && data["schema_version"] > 1
          raise Hive::ConfigError, "remote read identity registry is newer; upgrade Hive"
        end
        unless data.is_a?(Hash) && data["schema_version"] == 1 && data["handles"].is_a?(Hash) &&
               data["handles"].all? { |key, value| key.match?(/\A[0-9a-f]{64}\z/) && value.is_a?(Hash) }
          raise Hive::ConfigError, "invalid remote read identity registry"
        end
        data
      rescue JSON::ParserError
        raise Hive::ConfigError, "invalid remote read identity registry"
      end

      def not_found!
        raise Error.new(code: "not_found", status: 404, message: "resource not found")
      end

      def stale!
        raise Error.new(code: "stale", status: 409, message: "resource changed; refresh its inventory")
      end
    end
  end
end
