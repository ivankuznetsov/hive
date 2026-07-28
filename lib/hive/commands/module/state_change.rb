require "hive/commands/module/base"

module Hive
  module Commands
    class Module
      class StateChange < Base
        OPERATIONS = %w[enable disable uninstall].freeze

        def initialize(operation, name, **options)
          super(**options)
          @operation = operation.to_s
          @name = name.to_s.delete_prefix("honeycomb/")
        end

        def call!
          raise Hive::ConfigError, "unsupported module state change" unless OPERATIONS.include?(@operation)
          raise Hive::ConfigError, "module name is required" if @name.empty?
          legacy = workflow_compatibility.selected(@name)
          native = store.inspect_selection(@name, include_tombstone: true)
          if legacy && native
            raise OwnershipError,
                  "module #{@name.inspect} has conflicting native and legacy selections"
          end
          return call_legacy!(legacy) if legacy

          current = store.selected(@name, include_tombstone: true)
          raise OwnershipError, "module #{@name.inspect} is not installed" unless current
          preview = if @dry_run
                      state_preview(@operation, current)
          else
                      require_noninteractive_receipt!
                      verify_state_receipt!(@operation, current)
          end
          if @dry_run
            return emit(
              lifecycle_payload(
                operation: @operation, status: "preview", name: @name, selection: current
              ).merge("preview_receipt" => preview.fetch(:receipt)),
              human_lines: [ "hive: would #{@operation} #{@name}", "preview receipt: #{preview.fetch(:receipt)}" ]
            )
          end
          confirm_mutation!("#{@operation.capitalize} honeycomb/#{@name}?")
          selection = store.public_send(
            @operation, @name, commit: -> { commit_state(@name, state_action) }
          )
          status = @operation == "uninstall" ? "uninstalled" : "#{@operation}d"
          emit(
            lifecycle_payload(
              operation: @operation, status: status, name: @name, selection: selection
            ),
            human_lines: [ "hive: #{status} honeycomb/#{@name}" ]
          )
        end

        private

        def call_legacy!(selection)
          if %w[enable disable].include?(@operation)
            raise OwnershipError,
                  "legacy Honeycomb #{@name.inspect} has no durable enabled state; " \
                  "use `hive workflow remove #{@name}` to stop new task selection"
          end
          current = legacy_selection(selection)
          preview = if @dry_run
                      state_preview(@operation, current)
          else
                      require_noninteractive_receipt!
                      verify_state_receipt!(@operation, current)
          end
          if @dry_run
            return emit(
              lifecycle_payload(
                operation: @operation, status: "preview", name: @name,
                selection: current
              ).merge("preview_receipt" => preview.fetch(:receipt)),
              human_lines: [
                "hive: would uninstall #{@name}",
                "preview receipt: #{preview.fetch(:receipt)}"
              ]
            )
          end

          confirm_mutation!("Uninstall honeycomb/#{@name}?")
          workflow_compatibility.remove_selection!(
            name: @name, expected_current: selection,
            commit: -> { commit_workflow_state(@name, "uninstalled") }
          )
          retained = post_commit_legacy_cleanup
          tombstone = current.merge(
            "installed" => false, "enabled" => false, "active" => nil,
            "previous" => current.fetch("active"),
            "retained_commits" => retained
          )
          emit(
            lifecycle_payload(
              operation: @operation, status: "uninstalled", name: @name,
              selection: tombstone
            ),
            human_lines: [ "hive: uninstalled honeycomb/#{@name}" ]
          )
        end

        def post_commit_legacy_cleanup
          retained = workflow_compatibility.cleanup_unreferenced(@name)
          workflow_compatibility.reset_cache!
          retained
        rescue StandardError => error
          warn(
            "hive module: post-commit workflow cleanup failed " \
            "(#{error.class}: #{error.message}); the selection change already succeeded"
          )
          []
        end

        def legacy_selection(selection)
          {
            "schema_version" => selection.fetch("schema_version"),
            "name" => selection.fetch("name"), "installed" => true,
            "enabled" => true,
            "active" => selection.slice(
              "version", "catalog_commit", "source_commit",
              "manifest_digest", "configuration_digest"
            ),
            "previous" => nil, "epoch" => nil, "high_water_at" => nil,
            "origin" => "legacy_workflow"
          }
        end

        def state_action
          @operation == "uninstall" ? "uninstalled" : "#{@operation}d"
        end
      end
    end
  end
end
