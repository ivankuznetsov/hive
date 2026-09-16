require "json"
require "time"
require "hive/atomic_file"
require "hive/config"

module Hive
  module Web
    # Disposable display cache, never task/action authority. Registry changes
    # invalidate it so a removed or relocated project cannot reappear on boot.
    class StatusSnapshotStore
      SCHEMA = 1
      MAX_BYTES = 16 * 1024 * 1024

      def initialize(path: File.join(Hive::Config.hive_home, "web-status.json"))
        @path = path
      end

      def read
        bytes = File.read(@path, MAX_BYTES + 1)
        return if bytes.bytesize > MAX_BYTES

        document = JSON.parse(bytes)
        return unless document.is_a?(Hash) && document["schema"] == SCHEMA
        return unless document["projects"] == Hive::Config.registered_projects
        return unless valid_payload?(document["payload"])
        return unless Time.iso8601(document.fetch("last_success_at")) <= Time.now.utc

        document
      rescue StandardError
        nil
      end

      def write(payload, last_success_at:, projects: Hive::Config.registered_projects)
        return unless valid_payload?(payload)
        # The producer may independently reread registration during a scan.
        # Never stamp rows from a different fleet with the supplied identity.
        return unless project_identities(payload.fetch("projects")) == project_identities(projects)

        bytes = JSON.generate(
          "schema" => SCHEMA, "projects" => projects,
          "payload" => payload, "last_success_at" => last_success_at
        )
        return if bytes.bytesize > MAX_BYTES

        Hive::AtomicFile.write(@path, bytes, mode: 0o600)
      rescue StandardError
        # A cache write failure must not turn a successful live scan into an
        # outage. Atomic replacement leaves the earlier snapshot readable.
        nil
      end

      private

      def project_identities(projects)
        projects.map do |project|
          path = project.fetch("path")
          [ project.fetch("name"), path, project["hive_state_path"] || File.join(path, ".hive-state") ]
        end.sort
      end

      def valid_payload?(payload)
        payload.is_a?(Hash) && payload["unavailable"] != true &&
          payload["projects"].is_a?(Array) && payload["projects"].all? do |project|
            project.is_a?(Hash) && project.fetch("tasks", []).is_a?(Array) &&
              project.fetch("tasks", []).all? { |task| task.is_a?(Hash) }
          end
      end
    end
  end
end
