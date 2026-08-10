require "digest"
require "hive/atomic_file"
require "hive/user_service/definition"
require "hive/user_service/status"
require "hive/user_service/plan"
require "hive/user_service/result"
require "hive/user_service/manager"

module Hive
  class UserService
    NO_MANAGER_INSPECTION = Manager::Inspection.new(
      available: false,
      enabled: false,
      running: false,
      diagnostics: []
    ).freeze

    def initialize(definition:, runner: nil, query_available: false, manager_available: false,
                   status_reader: nil, launchd_running_via_list: false,
                   writer: Hive::AtomicFile, clock: -> { Time.now.utc },
                   event_handler: nil)
      @definition = definition
      @runner = runner || ->(argv) { system(*argv, out: File::NULL) }
      @writer = writer
      @clock = clock
      @manager = Manager.new(
        definition: definition,
        runner: @runner,
        query_available: query_available,
        manager_available: manager_available,
        status_reader: status_reader,
        launchd_running_via_list: launchd_running_via_list,
        event_handler: event_handler
      )
    end

    def inspect
      inspect_status(manager: true)
    end

    def plan(autostart:, force: false)
      if @definition.platform != :unsupported && !@definition.content
        raise ArgumentError, "service content is required to plan an apply"
      end

      status = inspect_status(manager: false)
      action = apply_action(status, force: force)
      manager_observed = autostart && manager_action?(action)
      if manager_observed
        status = inspect_status(manager: true)
        action = apply_action(status, force: force)
      end
      Plan.new(
        operation: :apply,
        action: action,
        definition_fingerprint: @definition.fingerprint,
        expected_observation: status.observation_key,
        status: status,
        manager_observed: manager_observed,
        autostart: autostart,
        force: force
      )
    end

    def plan_remove
      status = inspect_status(manager: false)
      manager_observed = !%i[absent unsafe unreadable].include?(status.content_state)
      status = inspect_status(manager: true) if manager_observed
      Plan.new(
        operation: :remove,
        action: status.content_state == :absent ? :none : :remove,
        definition_fingerprint: @definition.fingerprint,
        expected_observation: status.observation_key,
        status: status,
        manager_observed: manager_observed
      )
    end

    def apply(plan)
      validate_plan!(plan, :apply)

      begin
        current = inspect_status(manager: plan.manager_observed)
        return stale_result(:apply, current) unless current.observation_key == plan.expected_observation

        apply_current(plan, current)
      rescue StandardError => error
        Result.new(
          :failed,
          operation: :apply,
          final_status: safe_inspect(manager: plan.manager_observed),
          diagnostics: [ :write_failed ],
          error: error
        )
      end
    end

    def remove(plan)
      validate_plan!(plan, :remove)

      begin
        remove_current(plan)
      rescue Errno::ENOENT
        result(:absent, operation: :remove, final_status: inspect_status(manager: plan.manager_observed))
      rescue StandardError => error
        Result.new(
          :failed,
          operation: :remove,
          final_status: safe_inspect(manager: plan.manager_observed),
          diagnostics: [ :remove_failed ],
          error: error
        )
      end
    end

    private

    def inspect_status(manager:)
      manager_inspection = manager ? @manager.inspect : NO_MANAGER_INSPECTION
      file = inspect_file
      Status.new(
        platform: @definition.platform,
        unit_path: @definition.target_path,
        content_state: file.fetch(:state),
        file_identity: file[:identity],
        manager_available: manager_inspection.available,
        enabled: manager_inspection.enabled,
        running: manager_inspection.running,
        diagnostics: manager_inspection.diagnostics + file.fetch(:diagnostics)
      )
    end

    def remove_current(plan)
      current = inspect_status(manager: plan.manager_observed)
      return stale_result(:remove, current) unless current.observation_key == plan.expected_observation
      return result(:absent, operation: :remove, final_status: current) if current.content_state == :absent
      if %i[unsafe unreadable].include?(current.content_state)
        return result(
          :unsafe_path,
          operation: :remove,
          final_status: current,
          diagnostics: current.diagnostics + [ :unsafe_unit_path ]
        )
      end

      disabled = @manager.disable
      unless disabled.ok
        return result(
          :failed,
          operation: :remove,
          final_status: inspect_status(manager: true),
          diagnostics: disabled.diagnostics
        )
      end

      after_disable = inspect_file
      unless after_disable[:identity] == current.file_identity
        return result(
          :partial,
          operation: :remove,
          final_status: inspect_status(manager: true),
          diagnostics: [ :stale_after_manager_change ]
        )
      end

      if (error = unlink_target)
        return Result.new(
          :partial,
          operation: :remove,
          final_status: safe_inspect(manager: true),
          diagnostics: [ :remove_failed ],
          error: error
        )
      end

      reload = @manager.reload_after_remove
      result(
        reload.ok ? :removed : :partial,
        operation: :remove,
        final_status: inspect_status(manager: true),
        diagnostics: reload.diagnostics
      )
    end

    def unlink_target
      File.unlink(@definition.target_path)
      nil
    rescue Errno::ENOENT
      # The desired end state was reached concurrently. The manager still
      # needs its post-remove reload.
      nil
    rescue StandardError => error
      error
    end

    def apply_current(plan, current)
      return result(:unsupported, final_status: current) if plan.action == :unsupported
      return result(
        :unsafe_path,
        final_status: current,
        diagnostics: [ :unsafe_unit_path ]
      ) if plan.action == :unsafe
      return result(
        :drifted,
        final_status: current,
        diagnostics: [ :drift_detected ]
      ) if plan.action == :refuse_drift

      backup_path = nil
      kind =
        case plan.action
        when :write
          write(@definition.target_path, @definition.content)
          :written
        when :replace
          backup_path = backup_path_for(@definition.target_path)
          backup_content = bound_file_content(current.file_identity)
          return stale_result(:apply, inspect_status(manager: plan.manager_observed)) unless backup_content

          write(backup_path, backup_content)
          begin
            write(@definition.target_path, @definition.content)
          rescue StandardError => error
            return Result.new(
              :failed,
              backup_path: backup_path,
              final_status: safe_inspect(manager: plan.manager_observed),
              diagnostics: %i[backup_written write_failed],
              error: error
            )
          end
          :upgraded
        when :noop
          :unchanged
        else
          raise ArgumentError, "unsupported user service action #{plan.action.inspect}"
        end

      unless plan.autostart
        return result(
          kind,
          backup_path: backup_path,
          final_status: inspect_status(manager: false),
          diagnostics: backup_path ? [ :backup_written ] : []
        )
      end

      manager = @manager.install(kind: kind, status: current)
      diagnostics = []
      diagnostics << :backup_written if backup_path
      diagnostics.concat(manager.diagnostics)
      final_kind =
        if manager.diagnostics.include?(:autostart_unavailable)
          :autostart_unavailable
        elsif manager.ok
          kind
        else
          :partial
        end
      result(
        final_kind,
        backup_path: backup_path,
        restarted: manager.restarted,
        final_status: inspect,
        diagnostics: diagnostics
      )
    end

    def apply_action(status, force:)
      return :unsupported if @definition.platform == :unsupported

      case status.content_state
      when :absent then :write
      when :matching then :noop
      when :drifted then force ? :replace : :refuse_drift
      else :unsafe
      end
    end

    def manager_action?(action)
      %i[write replace noop].include?(action)
    end

    def validate_plan!(plan, operation)
      raise ArgumentError, "expected Hive::UserService::Plan" unless plan.is_a?(Plan)
      raise ArgumentError, "expected #{operation} plan, got #{plan.operation}" unless plan.operation == operation
      unless plan.definition_fingerprint == @definition.fingerprint
        raise ArgumentError, "plan belongs to a different service definition"
      end
      return if canonical_plan?(plan)

      raise ArgumentError, "plan decision does not match its observed service state"
    end

    def canonical_plan?(plan)
      if plan.operation == :apply
        expected_action = apply_action(plan.status, force: plan.force)
        plan.action == expected_action &&
          plan.manager_observed == (plan.autostart && manager_action?(expected_action))
      else
        expected_action = plan.status.content_state == :absent ? :none : :remove
        expected_manager_observed =
          !%i[absent unsafe unreadable].include?(plan.status.content_state)
        plan.action == expected_action &&
          plan.manager_observed == expected_manager_observed &&
          !plan.autostart &&
          !plan.force
      end
    end

    def stale_result(operation, current)
      result(
        :stale,
        operation: operation,
        final_status: current,
        diagnostics: [ :stale_plan ]
      )
    end

    def inspect_file
      return { state: :absent, identity: nil, diagnostics: [] } unless @definition.target_path

      lexical_stat = File.lstat(@definition.target_path)
      return unsafe_file_observation(lexical_stat) unless lexical_stat.file?

      stat, content = read_regular_file
      return unsafe_file_observation(stat) unless stat.file?

      file_observation(
        @definition.content && content.b == @definition.content.b ? :matching : :drifted,
        stat: stat,
        digest: Digest::SHA256.hexdigest(content)
      )
    rescue Errno::ENOENT
      file_observation(:absent)
    rescue Errno::ELOOP
      unsafe_file_observation(lexical_stat)
    rescue Errno::EACCES, Errno::EPERM
      file_observation(:unreadable, stat: lexical_stat, diagnostics: [ :unit_unreadable ])
    end

    def bound_file_content(expected_identity)
      stat, content = read_regular_file
      return unless stat.file?

      identity = file_identity(stat, Digest::SHA256.hexdigest(content))
      content if identity == expected_identity
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES, Errno::EPERM
      nil
    end

    def read_regular_file
      flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      File.open(@definition.target_path, flags) do |file|
        stat = file.stat
        next [ stat, nil ] unless stat.file?

        content = file.read
        [ file.stat, content ]
      end
    end

    def unsafe_file_observation(stat)
      file_observation(:unsafe, stat: stat, diagnostics: [ :unsafe_unit_path ])
    end

    def file_observation(state, stat: nil, digest: nil, diagnostics: [])
      {
        state: state,
        identity: stat && file_identity(stat, digest),
        diagnostics: diagnostics
      }
    end

    def file_identity(stat, digest)
      {
        type: stat.ftype,
        device: stat.dev,
        inode: stat.ino,
        mode: stat.mode,
        size: stat.size,
        mtime_nsec: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec,
        digest: digest
      }
    end

    def write(path, content)
      @writer.write(path, content, mode: 0o644)
    end

    def backup_path_for(path)
      "#{path}.bak-#{@clock.call.utc.strftime('%Y%m%dT%H%M%SZ')}"
    end

    def result(kind, **kwargs)
      Result.new(kind, **kwargs)
    end

    def safe_inspect(manager: true)
      inspect_status(manager: manager)
    rescue StandardError
      nil
    end
  end
end
