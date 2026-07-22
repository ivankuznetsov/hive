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

        def state_action
          @operation == "uninstall" ? "uninstalled" : "#{@operation}d"
        end
      end
    end
  end
end
