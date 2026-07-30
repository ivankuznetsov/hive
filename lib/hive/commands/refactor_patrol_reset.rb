require "json"
require "hive/config"
require "hive/daemon/activation_lock"
require "hive/daemon/writer_quiescence"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/job_store"
require "hive/workflow_package/canonical_json"

module Hive
  module Commands
    # Explicit destructive choice for one registered project's obsolete
    # Architecture Patrol backlog. Exact v2 bytes are archived, not converted
    # or deleted, and every other released v2 component remains live.
    class RefactorPatrolReset
      include Hive::Schemas::EnvelopeEmitter

      SCHEMA = "hive-refactor-patrol-jobstore-reset".freeze
      SCHEMA_VERSION =
        Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA)

      def initialize(
        project, confirm:, json: false, output: $stdout,
        project_resolver: ->(name) { Hive::Config.find_project(name) },
        resetter: nil, daemon_quiescence: nil, activation_lock: nil,
        patrol_fence: nil
      )
        @project = project.to_s
        @confirm = confirm == true
        @json = json == true
        @output = output
        @project_resolver = project_resolver
        @resetter = resetter || lambda do |entry|
          Hive::RefactorPatrol::JobStore.reset_released_jobs!(
            entry.fetch("real_path"),
            hive_state_path: entry.fetch("hive_state_path"),
            project: entry
          )
        end
        @daemon_quiescence = daemon_quiescence ||
          Hive::Daemon::WriterQuiescence.new(
            operation: "hive refactor-patrol-reset"
          )
        @activation_lock = activation_lock ||
          Hive::Daemon::ActivationLock.new
        @patrol_fence = patrol_fence || lambda do |identity, &block|
          Hive::Modules::Migration::Patrols.with_migration_lock(
            identity.fetch("real_path"),
            hive_state_path: identity.fetch("hive_state_path"),
            shared: false,
            &block
          )
        end
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = SCHEMA

      def envelope_error_kind(error)
        case error
        when Hive::ConcurrentRunError then "concurrent_run"
        when Hive::UnavailableError then "unavailable"
        when Hive::ConfigError
          error.message.include?("requires --confirm") ?
            "confirmation_required" : "config"
        when Hive::InternalError then "internal"
        else "error"
        end
      end

      def envelope_extras
        { "project" => @project }
      end

      def emit_envelope(error)
        @output.write(
          "#{Hive::WorkflowPackage::CanonicalJSON.generate(
            envelope_payload_for(error)
          )}\n"
        )
        @stdout_written = true
      rescue Errno::EPIPE
        @stdout_written = true
      rescue JSON::GeneratorError => serialization_error
        warn(
          "[hive] #{SCHEMA} error envelope was not serialisable: " \
          "#{serialization_error.class}: #{serialization_error.message}"
        )
        @stdout_written = true
      end

      def do_call
        unless @confirm
          raise Hive::ConfigError,
                "hive refactor-patrol-reset requires --confirm; " \
                "the archived v2 backlog will not be imported into v3"
        end
        entry = registered_project!
        daemon_was_running = false
        result = nil
        begin
          @activation_lock.synchronize do
            # Let the daemon drain while normal Patrol effect locks remain
            # available: shutdown completion can still need to settle a
            # supervised publication. Once it is gone, take the exclusive
            # effect-admission lock before the storage writer fence and keep
            # it through archive exchange and receipt publication.
            daemon_was_running = @daemon_quiescence.quiesce!
            @patrol_fence.call(entry) do
              result = @resetter.call(entry)
            end
          end
        ensure
          @daemon_quiescence.restart! if daemon_was_running
        end
        payload = result.merge(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "ok" => true,
          "project" => entry.fetch("name"),
          "project_id" => entry.fetch("project_id"),
          "project_root" => entry.fetch("real_path")
        )
        emit(payload)
        payload
      end

      private

      def registered_project!
        entry = @project_resolver.call(@project)
        unless entry.is_a?(Hash)
          raise Hive::ConfigError,
                "hive refactor-patrol-reset: unknown project " \
                "#{@project.inspect}"
        end
        path = File.expand_path(entry.fetch("path"))
        real_path = File.realpath(path)
        registered_real_path = File.expand_path(
          entry.fetch("real_path")
        )
        unless real_path == registered_real_path
          raise Hive::ConfigError,
                "registered project path no longer matches its canonical path"
        end
        state = File.expand_path(
          entry.fetch("hive_state_path"), real_path
        )
        project_id = entry.fetch("project_id").to_s
        if project_id.empty?
          raise Hive::ConfigError,
                "registered project identity has no project_id"
        end
        entry.merge(
          "path" => path,
          "real_path" => real_path,
          "hive_state_path" => state,
          "project_id" => project_id
        )
      rescue KeyError, TypeError, SystemCallError => error
        raise Hive::ConfigError,
              "registered project identity is unavailable " \
              "(#{error.class}: #{error.message})"
      end

      def emit(payload)
        bytes =
          if @json
            Hive::WorkflowPackage::CanonicalJSON.generate(payload)
          else
            "hive refactor-patrol-reset: " \
              "#{payload.fetch('project')} status=" \
              "#{payload.fetch('status')} archive=" \
              "#{payload['archive_path'] || 'none'}"
          end
        @output.write("#{bytes}\n")
      end
    end
  end
end
