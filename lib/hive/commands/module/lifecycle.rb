require "tmpdir"
require "hive/commands/module/base"
require "hive/module_package/catalog_client"

module Hive
  module Commands
    class Module
      class Lifecycle < Base
        def initialize(subject, operation:, settings:, hooks:, grants:, catalog_client: nil, **options)
          super(**options)
          @subject = subject.to_s
          @operation = operation
          @setting_choices = Array(settings)
          @hook_choices = Array(hooks)
          @grant_choices = Array(grants)
          @catalog_client = catalog_client || Hive::ModulePackage::CatalogClient.new
        end

        def call!
          validate_subject!
          Dir.mktmpdir("hive-module-candidate-") do |candidate_root|
            resolution = @catalog_client.fetch(source, destination: candidate_root)
            descriptor = resolution.descriptor
            current = store.selected(resolution.name, include_tombstone: true)
            if current && !current.fetch("installed")
              current = nil if @operation == "install"
            end
            current_configuration = active_configuration(current)
            issued_at, supplied_digest = receipt_parts_for_apply
            if @operation == "install" && current
              candidate_configuration = Hive::ModulePackage::Configuration.build(
                descriptor, generation: resolution, settings: parse_settings(descriptor),
                hooks: parse_hooks, grants: parse_grants(descriptor, current_configuration)
              )
              if replay?(current, candidate_configuration, resolution, supplied_digest)
                return emit(
                  lifecycle_payload(
                    operation: @operation, status: "already_current", name: resolution.name,
                    selection: current
                  ),
                  human_lines: [ "hive: module #{resolution.name} is already current" ]
                )
              end
              raise OwnershipError, "module #{resolution.name.inspect} is already installed; use update"
            end
            preview = build_preview(
              descriptor, resolution, current, current_configuration,
              now: issued_at || Time.now.utc
            )
            if replay?(current, preview.configuration, resolution, supplied_digest)
              return emit(
                lifecycle_payload(
                  operation: @operation, status: "already_current", name: resolution.name,
                  preview: preview, selection: current
                ),
                human_lines: [ "hive: module #{resolution.name} is already current" ]
              )
            end
            if @dry_run
              return emit(
                lifecycle_payload(
                  operation: @operation, status: "preview", name: resolution.name, preview: preview,
                  selection: current
                ),
                human_lines: preview_lines(preview)
              )
            end
            require_noninteractive_receipt!
            if supplied_digest
              preview.verify!(digest: supplied_digest, current: current)
            end
            confirm_mutation!("Apply #{@operation} for honeycomb/#{resolution.name}?")
            selection = store.apply(
              preview, package_root: candidate_root, resolution: resolution,
              commit: -> { commit_state(resolution.name, @operation == "install" ? "installed" : "updated") }
            )
            status = @operation == "install" ? "installed" : "updated"
            emit(
              lifecycle_payload(
                operation: @operation, status: status, name: resolution.name,
                preview: preview, selection: selection
              ),
              human_lines: [ "hive: #{status} honeycomb/#{resolution.name}@#{resolution.version}" ]
            )
          end
        end

        private

        def source
          @operation == "install" ? @subject : "honeycomb/#{@subject.delete_prefix('honeycomb/')}"
        end

        def validate_subject!
          raise Hive::ConfigError, "module source or name is required" if @subject.strip.empty?
        end

        def active_configuration(current)
          digest = current&.dig("active", "configuration_digest")
          store.configuration(current.fetch("name"), digest) if digest
        end

        def build_preview(descriptor, resolution, current, current_configuration, now:)
          Hive::ModulePackage::Preview.build(
            operation: @operation, descriptor: descriptor, generation: resolution,
            current: current, current_configuration: current_configuration,
            settings: parse_settings(descriptor), hooks: parse_hooks,
            grants: parse_grants(descriptor, current_configuration), now: now
          )
        end

        def parse_settings(descriptor)
          raw = choice_map(@setting_choices, "setting")
          specs = descriptor.settings.to_h { |spec| [ spec.fetch("name"), spec ] }
          raw.to_h do |name, value|
            spec = specs[name] or raise Hive::ConfigError, "unknown module setting #{name.inspect}"
            [ name, typed_value(value, spec) ]
          end
        end

        def parse_hooks
          choice_map(@hook_choices, "hook").to_h do |name, value|
            case value.to_s.downcase
            when "true", "enabled", "on" then [ name, true ]
            when "false", "disabled", "off" then [ name, false ]
            else raise Hive::ConfigError, "module hook #{name.inspect} must be enabled or disabled"
            end
          end
        end

        def parse_grants(descriptor, current_configuration)
          requested = descriptor.permissions
          current = current_configuration&.grants || {}
          grants = Hive::ModulePackage::Manifest::PERMISSION_KEYS.to_h do |key|
            if key == "repository_write"
              [ key, requested.fetch(key) && !!current[key] ]
            else
              [ key, Array(current[key]) & requested.fetch(key) ]
            end
          end
          @grant_choices.each do |choice|
            key, value = choice.to_s.split("=", 2)
            unless Hive::ModulePackage::Manifest::PERMISSION_KEYS.include?(key)
              raise Hive::ConfigError, "unknown module grant #{key.inspect}"
            end
            if key == "repository_write"
              grants[key] = value.nil? || %w[true yes on].include?(value.downcase)
            else
              raise Hive::ConfigError, "module grant #{key.inspect} requires =VALUE" if value.to_s.empty?
              grants[key] << value unless grants[key].include?(value)
            end
          end
          grants
        end

        def choice_map(values, label)
          values.each_with_object({}) do |choice, out|
            name, value = choice.to_s.split("=", 2)
            raise Hive::ConfigError, "module #{label} choice must be NAME=VALUE" if name.to_s.empty? || value.nil?
            raise Hive::ConfigError, "duplicate module #{label} choice #{name.inspect}" if out.key?(name)
            out[name] = value
          end
        end

        def typed_value(value, spec)
          return nil if value.empty? && !spec.fetch("required")
          case spec.fetch("type")
          when "boolean"
            return true if %w[true yes on].include?(value.downcase)
            return false if %w[false no off].include?(value.downcase)
            value
          when "integer" then Integer(value, 10)
          when "number" then Float(value)
          else value
          end
        rescue ArgumentError
          value
        end

        def receipt_parts_for_apply
          return [ nil, nil ] if @receipt.to_s.empty?
          Hive::ModulePackage::Preview.receipt_parts(@receipt)
        end

        def replay?(current, configuration, resolution, supplied_digest)
          return false unless current && supplied_digest
          active = current["active"]
          active && active["source_commit"] == resolution.source_commit &&
            active["manifest_digest"] == resolution.manifest_digest &&
            active["configuration_digest"] == configuration.digest &&
            current["receipt_digest"] == supplied_digest
        end

        def preview_lines(preview)
          [
            "module: #{preview.data.dig('candidate', 'name')}@#{preview.data.dig('candidate', 'version')}",
            "hooks: #{preview.configuration.hooks.map { |id, enabled| "#{id}=#{enabled}" }.join(', ')}",
            "grants: #{preview.configuration.grants.keys.join(', ')}",
            "preview receipt: #{preview.receipt}"
          ]
        end
      end
    end
  end
end
