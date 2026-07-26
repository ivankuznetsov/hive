require "tmpdir"
require "hive/commands/module/base"
require "hive/commands/workflow/configuration_resolver"
require "hive/module_package/catalog_client"
require "hive/module_package/permission_atoms"
require "hive/module_package/workflow_compatibility"
require "hive/modules/target_executor"
require "hive/stringify_keys"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/semantic_diff"

module Hive
  module Commands
    class Module
      class Lifecycle < Base
        def initialize(subject, operation:, settings:, hooks:, grants:, catalog_client: nil,
                       mapping_overrides: [], input_bindings: [], allow_escalation: false,
                       workflow_store: nil, activation_health_check: nil,
                       setup_context: nil, **options)
          super(**options)
          @subject = subject.to_s
          @operation = operation
          @setting_choices = Array(settings)
          @hook_choices = Array(hooks)
          @grant_choices = Array(grants)
          @catalog_client = catalog_client || Hive::ModulePackage::CatalogClient.new
          @mapping_overrides = Array(mapping_overrides)
          @input_bindings = Array(input_bindings)
          @allow_escalation = allow_escalation
          @workflow_store = workflow_store
          @activation_health_check = activation_health_check ||
                                     Hive::Modules::TargetExecutor.new.health_check
          @setup_context = setup_context
        end

        def call!
          validate_subject!
          Dir.mktmpdir("hive-module-candidate-") do |candidate_root|
            resolution = @catalog_client.fetch(source, destination: candidate_root)
            descriptor = resolution.descriptor
            if descriptor.legacy_honeycomb
              return call_legacy!(
                candidate_root: candidate_root, resolution: resolution
              )
            end
            if workflow_compatibility.selected(resolution.name)
              raise OwnershipError,
                    "module #{resolution.name.inspect} is already installed as a managed workflow"
            end
            collect_interactive_install_choices!(descriptor)
            current = store.selected(resolution.name, include_tombstone: true)
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
            confirm_permission_atoms!(preview)
            confirm_mutation!("Apply #{@operation} for honeycomb/#{resolution.name}?")
            selection = store.apply(
              preview, package_root: candidate_root, resolution: resolution,
              health_check: @activation_health_check,
              setup_context: setup_context_for(preview.configuration),
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

        def setup_context_for(configuration)
          return nil unless setup_hook_enabled?(configuration)
          return Hive::StringifyKeys.call(@setup_context) if @setup_context

          identity = registered_project_identity
          {
            "project_id" => identity.fetch("project_id").to_s,
            "project" => identity.fetch("name").to_s
          }
        end

        def setup_hook_enabled?(configuration)
          configuration.contract.fetch("hooks").any? do |hook|
            configuration.hooks.fetch(hook.fetch("id")) &&
              hook.fetch("events").include?("project.registered")
          end
        end

        def call_legacy!(candidate_root:, resolution:)
          candidate = workflow_compatibility.adopt(
            module_resolution: resolution, package_root: candidate_root
          )
          name = resolution.name
          if store.inspect_selection(name, include_tombstone: true)
            raise OwnershipError,
                  "module #{name.inspect} is already installed in the native module store"
          end
          current = workflow_compatibility.selected(name)
          if @operation == "install" && current &&
             current.fetch("source_commit") != candidate.resolution.source_commit
            raise OwnershipError,
                  "module #{name.inspect} is already installed; use update"
          end
          if @operation == "update" && !current
            raise OwnershipError, "module #{name.inspect} is not installed"
          end
          previous_configuration = current && workflow_compatibility.configuration(
            name, current.fetch("configuration_digest")
          )
          resolver = Hive::Commands::Workflow::ConfigurationResolver.new(
            validated: candidate.validated, resolution: candidate.resolution,
            cfg: project_config, mapping_overrides: @mapping_overrides,
            input_bindings: @input_bindings, previous: previous_configuration
          )
          grants = parse_grants(resolution.descriptor, nil)
          issued_at, supplied_digest = receipt_parts_for_apply
          preview = legacy_preview(
            candidate: candidate, current: current, resolver: resolver,
            grants: grants, issued_at: issued_at || Time.now.utc
          )
          if legacy_replay?(
            candidate: candidate, resolver: resolver, current: current,
            supplied_digest: supplied_digest, grants: grants,
            issued_at: issued_at
          )
            return emit(
              legacy_lifecycle_payload(
                preview: preview, status: "already_current",
                selection: legacy_selection(current)
              ),
              human_lines: [ "hive: module #{name} is already current" ]
            )
          end
          if @operation == "install" && current
            raise OwnershipError,
                  "module #{name.inspect} is already installed; use update"
          end

          workflow_compatibility.admit_runtime!(
            candidate.validated.workflow, candidate.package_root,
            configuration: resolver.configuration
          )
          if @dry_run
            return emit(
              legacy_lifecycle_payload(
                preview: preview, status: "preview",
                selection: legacy_selection(current)
              ),
              human_lines: legacy_preview_lines(preview)
            )
          end

          require_noninteractive_receipt!
          verify_legacy_preview!(preview, supplied_digest)
          confirm_mutation!("Apply #{@operation} for honeycomb/#{name}?")
          confirm_legacy_escalation!(resolver, candidate.resolution)
          selected = workflow_compatibility.activate!(
            candidate: candidate, configuration: resolver.configuration,
            expected_current: current,
            commit: -> { commit_workflow_state(name, legacy_state_action) },
            admit: false
          )
          legacy_post_commit(name)
          emit(
            legacy_lifecycle_payload(
              preview: preview,
              status: @operation == "install" ? "installed" : "updated",
              selection: legacy_selection(selected)
            ),
            human_lines: [
              "hive: #{@operation == 'install' ? 'installed' : 'updated'} " \
              "honeycomb/#{name}@#{candidate.resolution.version}"
            ]
          )
        end

        def legacy_preview(candidate:, current:, resolver:, grants:, issued_at:)
          issued_at = Time.at(issued_at.to_i, in: "UTC")
          data = {
            "schema_version" => 1, "kind" => "legacy_workflow",
            "operation" => @operation,
            "issued_at" => issued_at.utc.iso8601(6),
            "expires_at" => (
              issued_at.utc + Hive::ModulePackage::Preview::TTL_SECONDS
            ).iso8601(6),
            "candidate" => legacy_candidate(candidate),
            "current" => legacy_selection(current),
            "configuration_digest" => resolver.configuration.digest,
            "mappings" => resolver.mappings,
            "optional_inputs" => resolver.inputs,
            "grants" => grants,
            "permission_digest" => digest(candidate.descriptor.permissions),
            "diff" => legacy_diff(candidate, current, resolver)
          }
          preview_digest = digest(data)
          {
            data: data, digest: preview_digest,
            receipt: "#{issued_at.to_i}.#{preview_digest}",
            candidate: candidate, resolver: resolver, grants: grants
          }
        end

        def legacy_candidate(candidate)
          resolution = candidate.resolution
          {
            "name" => resolution.name, "version" => resolution.version,
            "type" => "workflow", "catalog_commit" => resolution.catalog_commit,
            "source_commit" => resolution.source_commit,
            "source_revision" => resolution.source_revision,
            "manifest_digest" => resolution.manifest_digest,
            "descriptor_digest" => candidate.descriptor.digest
          }
        end

        def legacy_selection(selection)
          return nil unless selection

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

        def legacy_diff(candidate, current, resolver)
          return nil unless current

          old_manifest = workflow_store.manifest(
            current.fetch("name"), current.fetch("source_commit"),
            current.fetch("manifest_digest")
          )
          diff = Hive::WorkflowPackage::SemanticDiff.compare(
            old_manifest, candidate.validated.manifest
          )
          values = diff.to_h
          actor_changed = resolver.actor_policy_changed?
          values.merge(
            "actor_policy_changed" => actor_changed,
            "input_bindings_changed" => resolver.input_bindings_changed?,
            "escalation" => diff.escalation? || actor_changed,
            "escalation_reasons" => (
              values.fetch("escalation_reasons") +
              (actor_changed ? [ "actor_policy_redistribution" ] : [])
            ).uniq
          )
        end

        def legacy_lifecycle_payload(preview:, status:, selection:)
          data = preview.fetch(:data)
          {
            "schema" => "hive-module-lifecycle",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(
              "hive-module-lifecycle"
            ),
            "ok" => true, "operation" => @operation, "status" => status,
            "name" => data.dig("candidate", "name"),
            "preview_receipt" => preview.fetch(:receipt),
            "candidate" => data.fetch("candidate"),
            "configuration_digest" => data.fetch("configuration_digest"),
            "diff" => data.fetch("diff"),
            "proposed" => {
              "settings" => [], "hooks" => [],
              "grants" => data.fetch("grants"),
              "permission_digest" => data.fetch("permission_digest"),
              "mappings" => data.fetch("mappings"),
              "optional_inputs" => data.fetch("optional_inputs")
            },
            "selection" => selection
          }
        end

        def verify_legacy_preview!(preview, supplied_digest, now: Time.now.utc)
          unless supplied_digest && secure_equal?(preview.fetch(:digest), supplied_digest)
            raise Hive::ConfigError, "module preview receipt does not match"
          end
          if now.utc > Time.iso8601(preview.dig(:data, "expires_at"))
            raise Hive::ConfigError, "module preview receipt expired; preview again"
          end
          true
        end

        def legacy_replay?(candidate:, resolver:, current:, supplied_digest:, grants:,
                           issued_at:)
          return false unless current && supplied_digest && issued_at
          return false unless current.fetch("source_commit") == candidate.resolution.source_commit &&
                              current.fetch("manifest_digest") == candidate.resolution.manifest_digest &&
                              current.fetch("configuration_digest") == resolver.configuration.digest

          baselines = [ current ]
          baselines.unshift(nil) if @operation == "install"
          baselines.any? do |baseline|
            replay = legacy_preview(
              candidate: candidate, current: baseline, resolver: resolver,
              grants: grants, issued_at: issued_at
            )
            secure_equal?(replay.fetch(:digest), supplied_digest)
          end
        end

        def confirm_legacy_escalation!(resolver, resolution)
          high_risk = resolver.unbounded? || resolution.permissions["risk"] == "high"
          return true unless high_risk
          return true if @allow_escalation
          unless interactive?
            raise ConsentRequired,
                  "unbounded/high-risk Honeycomb requires --allow-escalation in addition to explicit grants"
          end
          @stdout.print "This Honeycomb includes unbounded actors. Allow high-risk execution? [y/N] "
          answer = @stdin.gets.to_s.strip.downcase
          return true if %w[y yes].include?(answer)

          raise ConsentRequired, "high-risk module change cancelled; no project state changed"
        end

        def legacy_post_commit(name)
          if @operation == "update"
            workflow_compatibility.cleanup_unreferenced(name)
          end
          workflow_compatibility.reset_cache!
        rescue StandardError => error
          warn(
            "hive module: post-commit workflow cleanup failed " \
            "(#{error.class}: #{error.message}); the selection change already succeeded"
          )
        end

        def legacy_preview_lines(preview)
          data = preview.fetch(:data)
          [
            "module: #{data.dig('candidate', 'name')}@#{data.dig('candidate', 'version')}",
            "mappings: #{data.fetch('mappings').length}",
            "grants: #{data.fetch('grants').keys.join(', ')}",
            "preview receipt: #{preview.fetch(:receipt)}"
          ]
        end

        def legacy_state_action
          @operation == "install" ? "installed" : "updated"
        end

        def digest(value)
          ::Digest::SHA256.hexdigest(
            Hive::WorkflowPackage::CanonicalJSON.generate(value)
          )
        end

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
                .merge(@interactive_setting_choices || {})
          specs = descriptor.settings.to_h { |spec| [ spec.fetch("name"), spec ] }
          raw.to_h do |name, value|
            spec = specs[name] or raise Hive::ConfigError, "unknown module setting #{name.inspect}"
            [ name, typed_value(value, spec) ]
          end
        end

        def parse_hooks
          choices = choice_map(@hook_choices, "hook").merge(@interactive_hook_choices || {})
          choices.to_h do |name, value|
            return_value = if [ true, false ].include?(value)
              value
            else
              case value.to_s.downcase
              when "true", "enabled", "on" then true
              when "false", "disabled", "off" then false
              else raise Hive::ConfigError, "module hook #{name.inspect} must be enabled or disabled"
              end
            end
            [ name, return_value ]
          end
        end

        def parse_grants(descriptor, current_configuration)
          requested = descriptor.permissions
          current = current_configuration&.grants || {}
          grants = if @operation == "install" && interactive?
            requested.to_h do |key, value|
              [ key, value.is_a?(Array) ? value.dup : value ]
            end
          else
            Hive::ModulePackage::Manifest::PERMISSION_KEYS.to_h do |key|
              if key == "repository_write"
                [ key, requested.fetch(key) && !!current[key] ]
              else
                [ key, Array(current[key]) & requested.fetch(key) ]
              end
            end
          end
          @grant_choices.each do |choice|
            key, value = choice.to_s.split("=", 2)
            unless Hive::ModulePackage::Manifest::PERMISSION_KEYS.include?(key)
              raise Hive::ConfigError, "unknown module grant #{key.inspect}"
            end
            if key == "repository_write"
              grants[key] = if value.nil? || %w[true yes on].include?(value.downcase)
                true
              elsif %w[false no off].include?(value.downcase)
                false
              else
                raise Hive::ConfigError,
                      "module grant #{key.inspect} must be true or false"
              end
            else
              raise Hive::ConfigError, "module grant #{key.inspect} requires =VALUE" if value.to_s.empty?
              grants[key] << value unless grants[key].include?(value)
            end
          end
          grants
        end

        def collect_interactive_install_choices!(descriptor)
          return unless @operation == "install" && interactive?

          supplied_settings = choice_map(@setting_choices, "setting")
          @interactive_setting_choices = descriptor.settings.each_with_object({}) do |spec, values|
            name = spec.fetch("name")
            next if supplied_settings.key?(name)

            default = spec["default"]
            detail = [ spec.fetch("type"), spec.fetch("required") ? "required" : "optional" ].join(", ")
            suffix = spec.key?("default") ? " [#{default}]" : ""
            @stdout.print "Setting #{name} (#{detail})#{suffix}: "
            answer = @stdin.gets.to_s.strip
            answer = default if answer.empty? && spec.key?("default")
            values[name] = answer.to_s
          end

          supplied_hooks = choice_map(@hook_choices, "hook")
          @interactive_hook_choices = descriptor.hooks.each_with_object({}) do |hook, values|
            id = hook.fetch("id")
            next if supplied_hooks.key?(id)

            default = hook.fetch("default_enabled")
            suffix = default ? "[Y/n]" : "[y/N]"
            @stdout.print "Enable hook #{id}? #{suffix} "
            answer = @stdin.gets.to_s.strip.downcase
            values[id] = if answer.empty?
              default
            elsif %w[y yes].include?(answer)
              true
            elsif %w[n no].include?(answer)
              false
            else
              raise Hive::ConfigError, "module hook #{id.inspect} must be answered yes or no"
            end
          end
        end

        def confirm_permission_atoms!(preview)
          return unless interactive?

          Hive::ModulePackage::PermissionAtoms.expand(preview.configuration.grants).each do |atom|
            category = atom.fetch("category").tr("_", " ")
            value = atom.fetch("value") == true ? "enabled" : atom.fetch("value")
            @stdout.print "Grant #{category}: #{value}? [y/N] "
            answer = @stdin.gets.to_s.strip.downcase
            next if %w[y yes].include?(answer)

            raise ConsentRequired,
                  "module permission #{atom.fetch('category')}=#{atom.fetch('value')} declined; " \
                  "no project state changed"
          end
          true
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
