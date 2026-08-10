require "hive/config"
require "hive/modules/capability_context"

module Hive
  module Modules
    module Migration
      # Revalidates live ownership, configuration, module generation, grants,
      # and product claims while the migration admission lock is held. It owns
      # policy only; effect sender and recovery transitions stay in
      # EffectDelivery.
      class EffectAdmission
        LifecycleDenied = Class.new(StandardError)

        def initialize(module_name:, product_label:, config_key:,
                       project_root:, hive_state_path:, capture:, authority:,
                       migration_lock:, ownership_loader:, config_loader: nil,
                       capability_checker: nil, claim_validator: nil,
                       module_execution: nil, lifecycle_store_factory: nil,
                       diagnostic_transition: false)
          @module_name = module_name
          @product_label = product_label
          @config_key = config_key
          @project_root = project_root
          @hive_state_path = hive_state_path
          @capture = capture
          @authority = authority
          @migration_lock = migration_lock
          @ownership_loader = ownership_loader
          @config_loader = config_loader ||
                           ->(root) { Hive::Config.load(root) }
          @capability_checker =
            capability_checker || method(:default_capability_allowed?)
          @claim_validator = claim_validator || ->(**) { true }
          @module_execution = normalize_module_execution(module_execution)
          @lifecycle_store_factory = lifecycle_store_factory || lambda do |root|
            require "hive/module_package/managed_store"
            Hive::ModulePackage::ManagedStore.new(root)
          end
          @diagnostic_transition = diagnostic_transition == true
        end

        def with_live_authorization(intent, on_denied:)
          @migration_lock.call do
            ownership = @ownership_loader.call
            config = load_live_config
            reason = ownership_denial(ownership)
            reason ||= configuration_denial(config) unless
              @diagnostic_transition
            return on_denied.call(reason) if reason

            begin
              with_lifecycle_admission do |capability_context|
                unless capability_allowed?(
                  intent, config, capability_context
                )
                  return on_denied.call("capability_revoked")
                end
                unless claim_current?(intent)
                  return on_denied.call("stale_claim")
                end
                yield
              end
            rescue LifecycleDenied => e
              on_denied.call(e.message)
            end
          end
        end

        def with_shadow_denial
          @migration_lock.call do
            ownership = @ownership_loader.call
            config = @config_loader.call(@project_root)
            reason = ownership_denial(ownership) ||
                     configuration_denial(config) ||
                     "shadow_mutation_forbidden"
            yield reason
          end
        end

        private

        def capability_allowed?(intent, config, capability_context)
          @capability_checker.call(
            config: config,
            capability: intent.capability,
            sink: intent.sink,
            target: intent.target,
            authority: @authority,
            capability_context: capability_context
          )
        end

        def claim_current?(intent)
          @claim_validator.call(
            occurrence_id: intent.occurrence_id,
            claim_generation: intent.claim_generation,
            sink: intent.sink,
            target: intent.target,
            scope: intent.scope
          )
        end

        def with_lifecycle_admission
          return yield(nil) unless @module_execution

          store = @lifecycle_store_factory.call(@hive_state_path)
          name = @module_execution.fetch("module")
          store.with_admission(name) do |selection|
            active = selection && selection["active"]
            valid = selection&.fetch("installed", false) == true &&
                    selection.fetch("enabled", false) == true &&
                    active.is_a?(Hash) &&
                    active["source_commit"] ==
                      @module_execution.fetch("generation") &&
                    active["configuration_digest"] ==
                      @module_execution.fetch("configuration_digest")
            unless valid
              raise LifecycleDenied, "module_generation_revoked"
            end

            configuration = store.configuration(
              name, active.fetch("configuration_digest")
            )
            unless configuration.generation.fetch("source_commit") ==
                   @module_execution.fetch("generation")
              raise LifecycleDenied, "module_generation_revoked"
            end
            yield Hive::Modules::CapabilityContext.new(
              configuration.grants
            )
          end
        end

        def ownership_denial(snapshot)
          return "migration_state_unavailable" unless
            snapshot.is_a?(Hash)
          return "stale_owner_epoch" unless
            snapshot["epoch"] == @capture.owner_epoch
          return "ownership_changed" unless
            snapshot["owner"] == @capture.owner
          return "admission_closed" unless
            snapshot["admission"] == true
          return if @authority == "shadow"
          return "authority_not_owner" unless
            snapshot["owner"] == @authority

          nil
        end

        def configuration_denial(config)
          settings = config.is_a?(Hash) ? config[@config_key] : nil
          return "configuration_unavailable" unless
            settings.is_a?(Hash)
          return "configuration_disabled" unless
            settings.fetch("enabled", true) == true

          nil
        end

        def load_live_config
          @config_loader.call(@project_root)
        rescue StandardError
          raise unless @diagnostic_transition

          { @config_key => { "enabled" => true } }
        end

        def normalize_module_execution(value)
          return nil if value.nil?

          data = value.transform_keys(&:to_s)
          valid = data.keys.sort ==
                    %w[configuration_digest generation module] &&
                  data.fetch("module") == @module_name &&
                  data.fetch("generation").to_s
                      .match?(/\A[0-9a-f]{40,64}\z/) &&
                  data.fetch("configuration_digest").to_s
                      .match?(/\A[0-9a-f]{64}\z/)
          unless valid
            raise Hive::ConfigError,
                  "#{@product_label} module execution identity is malformed"
          end
          data.freeze
        rescue NoMethodError, KeyError
          raise Hive::ConfigError,
                "#{@product_label} module execution identity is malformed"
        end

        def default_capability_allowed?(config:, capability_context:, **)
          return config.dig(@config_key, "enabled") != false unless
            capability_context

          capability_context.is_a?(
            Hive::Modules::CapabilityContext
          )
        end
      end
    end
  end
end
