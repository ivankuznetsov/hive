require "pathname"
require "securerandom"

module Hive
  module RuntimeControlPlane
    class Identity
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      LEGACY_REGISTRATION = /\Alegacy:(#{UUID.source.delete_prefix('\\A').delete_suffix('\\z')})\z/i
      MAX_TASK_ID_BYTES = 128

      Project = Data.define(
        :project_id, :registration_id, :name, :observed_path, :state_root_path,
        :registered_at
      )
      TaskSubject = Data.define(:task_id, :project_id, :workflow_id, :task_slug)

      def initialize(uuid_generator: -> { SecureRandom.uuid }, state_path_identity: nil)
        @uuid_generator = uuid_generator
        @state_path_identity = state_path_identity || method(:config_state_path_identity)
      end

      def project(entry)
        value = stringify_keys(entry)
        project_id = valid_uuid!(value["project_id"], "project_id")
        registration_id = valid_registration_id!(value["registration_id"])
        name = present!(value["name"], "project name")
        observed_path = expanded_path!(value["path"], "project path")
        state_root = value["hive_state_path"] || File.join(observed_path, ".hive-state")
        Project.new(
          project_id: project_id,
          registration_id: registration_id,
          name: name,
          observed_path: observed_path,
          state_root_path: expanded_path!(state_root, "Hive state path"),
          registered_at: value["registered_at"]
        )
      end

      def validate_projects!(entries)
        projects = Array(entries).map { |entry| project(entry) }
        reject_duplicate!(projects, :project_id, :project_identity_collision)
        reject_duplicate!(projects, :registration_id, :registration_identity_collision)
        state_roots = projects.map do |project|
          [ project, @state_path_identity.call(project.state_root_path) ]
        end
        duplicate_root = state_roots.group_by(&:last).find { |_key, rows| rows.length > 1 }
        raise_identity!(:state_root_collision, duplicate_root.first.inspect) if duplicate_root
        projects.freeze
      rescue Hive::Error => error
        raise error if error.is_a?(IdentityError)

        raise_identity!(:invalid_project_identity, error.message)
      end

      def task_subject(project_id:, workflow_id:, task_slug:, task_id: nil)
        id = task_id.nil? ? @uuid_generator.call : task_id
        TaskSubject.new(
          task_id: valid_task_id!(id),
          project_id: valid_uuid!(project_id, "project_id"),
          workflow_id: present!(workflow_id, "workflow_id"),
          task_slug: present!(task_slug, "task_slug")
        )
      end

      def validate_task_subjects!(subjects)
        values = Array(subjects)
        reject_duplicate!(values, :task_id, :task_identity_collision)
        aliases = values.group_by { |subject| [ subject.project_id, subject.workflow_id, subject.task_slug ] }
        collision = aliases.find { |_key, rows| rows.length > 1 }
        raise_identity!(:task_alias_collision, collision.first.inspect) if collision

        values.freeze
      end

      private

      def stringify_keys(value)
        unless value.is_a?(Hash)
          raise_identity!(:invalid_project_identity, "project registration must be an object")
        end

        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def valid_uuid!(value, label)
        string = present!(value, label)
        raise_identity!(:invalid_project_identity, "#{label} is not a UUID") unless UUID.match?(string)

        string
      end

      def valid_registration_id!(value)
        string = present!(value, "registration_id")
        unless UUID.match?(string) || LEGACY_REGISTRATION.match?(string)
          raise_identity!(:invalid_registration_identity, "registration_id is invalid")
        end
        string
      end

      def valid_task_id!(value)
        string = present!(value, "task_id")
        if string.bytesize > MAX_TASK_ID_BYTES || string.include?("\0")
          raise_identity!(:invalid_task_identity, "task_id is invalid")
        end
        string
      end

      def expanded_path!(value, label)
        File.expand_path(present!(value, label))
      rescue ArgumentError
        raise_identity!(:invalid_project_identity, "#{label} is invalid")
      end

      def present!(value, label)
        string = value.to_s
        raise_identity!(:missing_identity, "#{label} is required") if string.empty?

        string
      end

      def reject_duplicate!(values, field, code)
        duplicate = values.group_by { |value| value.public_send(field) }
                          .find { |_key, rows| rows.length > 1 }
        raise_identity!(code, "duplicate #{field} #{duplicate.first.inspect}") if duplicate
      end

      def raise_identity!(code, detail)
        raise IdentityError.new(
          "runtime control-plane identity rejected: #{detail}", code: code
        )
      end

      def config_state_path_identity(path)
        require "hive/config"
        Hive::Config.canonical_registration_state_path(path)
      end
    end
  end
end
