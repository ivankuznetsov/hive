require "tmpdir"
require "hive/commands/workflow/base"
require "hive/commands/workflow/configuration_resolver"
require "hive/workflow_package/registry_client"
require "hive/workflow_package/validator"
require "hive/workflows/project"

module Hive
  module Commands
    class Workflow
      class Install < Base
        SCHEMA = "hive-workflow-install".freeze

        def initialize(source, project_root:, json: false, yes: false, dry_run: false, stdout: $stdout, stdin: $stdin,
                       registry_client: nil, committer: nil, allow_escalation: false,
                       mapping_overrides: [], input_bindings: [])
          super(project_root: project_root, json: json, stdout: stdout, stdin: stdin, yes: yes, committer: committer)
          @source = source
          @dry_run = dry_run
          @registry_client = registry_client || Hive::WorkflowPackage::RegistryClient.new
          @allow_escalation = allow_escalation
          @mapping_overrides = mapping_overrides
          @input_bindings = input_bindings
        end

        def call!
          Dir.mktmpdir("hive-workflow-install-") do |package_root|
            resolution = @registry_client.fetch(@source, destination: package_root)
            validated = Hive::WorkflowPackage::Validator.validate!(
              package_root, expected_name: resolution.name,
              expected_manifest_digest: resolution.manifest_digest
            )
            current = store.selected(resolution.name, cfg: project_config)
            same_generation = current && current.fetch("source_commit") == resolution.source_commit
            previous_configuration = if same_generation
              store.configuration(
                resolution.name, current.fetch("configuration_digest"), cfg: project_config
              )
            end
            resolver = configuration_resolver(validated, resolution, previous: previous_configuration)
            if interactive?
              if @mapping_overrides.empty?
                resolver = customize_interactively(
                  resolver, validated, resolution, previous: previous_configuration
                )
              else
                human_disclosure(resolution, resolver, verb: "proposed").each { |line| @stdout.puts line }
              end
            end
            if same_generation && current.fetch("configuration_digest") == resolver.configuration.digest
              return emit(payload(resolution, resolver, "already_installed"), human_lines: [
                "hive: honeycomb/#{resolution.name} is already installed at #{resolution.source_commit}",
                *optional_input_disclosure(resolver.inputs)
              ])
            end
            if current && !same_generation
              raise UpdateRequired,
                    "honeycomb/#{resolution.name} is already managed at another commit; use `hive workflow update #{resolution.name}`"
            end

            admit_runtime!(
              validated.workflow, package_root, configuration: resolver.configuration
            )
            if @dry_run
              return emit(payload(resolution, resolver, "dry_run"),
                          human_lines: human_disclosure(resolution, resolver, verb: "would install"))
            end
            disclosure = payload(resolution, resolver, "cancelled")
            unless confirmed?("Install honeycomb/#{resolution.name}@#{resolution.version} with the disclosed policy?")
              return emit(disclosure, human_lines: [ "hive: install cancelled; no project state changed" ])
            end
            unless escalation_confirmed?(resolver, resolution)
              return emit(disclosure, human_lines: [ "hive: high-risk install cancelled; no project state changed" ])
            end

            store.place_generation(package_root, resolution)
            begin
              store.activate(
                resolution, configuration: resolver.configuration,
                cfg: project_config,
                expected_current: current,
                commit: -> { commit_state(resolution.name, "installed") }
              )
            rescue StandardError
              store.cleanup_unreferenced(resolution.name)
              raise
            end
            Hive::Workflows::Project.reset!
            emit(payload(resolution, resolver, "installed"), human_lines: human_disclosure(resolution, resolver))
          end
        end

        private

        def payload(resolution, resolver, status)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => status,
            "name" => resolution.name,
            "version" => resolution.version,
            "catalog_commit" => resolution.catalog_commit,
            "source_commit" => resolution.source_commit,
            "manifest_digest" => resolution.manifest_digest,
            "permissions" => resolution.permissions,
            "configuration_digest" => resolver.configuration.digest,
            "mappings" => resolver.mappings,
            "optional_inputs" => resolver.inputs
          }
        end

        def human_disclosure(resolution, resolver, verb: "installed")
          mapping_lines = resolver.mappings.map do |mapping|
            identity = [ mapping.fetch("agent"), mapping["model"], mapping["effort"] ].compact.join(" / ")
            "map: #{mapping.fetch('slot')} -> #{identity} (#{mapping.fetch('mapping_role')})"
          end
          permissions = resolution.permissions
          if permissions.key?("risk")
            return [
              "hive: #{verb} honeycomb/#{resolution.name}@#{resolution.version}",
              "registry: #{resolution.catalog_commit} source provenance: #{resolution.source_revision} manifest: #{resolution.manifest_digest}",
              "risk: #{permissions['risk']}; capabilities: #{Array(permissions['capabilities']).join(', ')}",
              "network: #{Array(permissions['network_hosts']).join(', ')}; read: #{Array(permissions['filesystem_read']).join(', ')}; " \
                "write: #{Array(permissions['filesystem_write']).join(', ')}; secrets: #{Array(permissions['secrets']).join(', ')}",
              *optional_input_disclosure(resolver.inputs),
              *mapping_lines
            ]
          end
          [
            "hive: #{verb} honeycomb/#{resolution.name}@#{resolution.version}",
            "source: #{resolution.source_commit} manifest: #{resolution.manifest_digest}",
            "tools: #{Array(permissions['tools']).join(', ')}; deny: #{Array(permissions['deny']).join(', ')}",
            "commands: #{Array(permissions['commands']).join(', ')}; domains: #{Array(permissions['domains']).join(', ')}",
            *optional_input_disclosure(resolver.inputs),
            *mapping_lines
          ]
        end

        def configuration_resolver(validated, resolution, overrides: @mapping_overrides, previous: nil)
          ConfigurationResolver.new(
            validated: validated, resolution: resolution, cfg: project_config,
            mapping_overrides: overrides, input_bindings: @input_bindings, previous: previous
          )
        end

        def customize_interactively(resolver, validated, resolution, previous: nil)
          human_disclosure(resolution, resolver, verb: "suggested").each { |line| @stdout.puts line }
          @stdout.print "Use all suggested agent mappings? [Y/n] "
          answer = @stdin.gets
          return resolver if answer.nil? || !%w[n no].include?(answer.strip.downcase)

          overrides = resolver.mappings.map do |mapping|
            slot = mapping.fetch("slot")
            @stdout.print "#{slot} agent [#{mapping.fetch('agent')}]: "
            agent = @stdin.gets.to_s.strip
            agent = mapping.fetch("agent") if agent.empty?
            "#{slot}=#{agent}"
          end
          configured = configuration_resolver(validated, resolution, overrides: overrides, previous: previous)
          human_disclosure(resolution, configured, verb: "proposed").each { |line| @stdout.puts line }
          configured
        end

        def escalation_confirmed?(resolver, resolution)
          high_risk = resolver.unbounded? || resolution.permissions["risk"] == "high"
          return true unless high_risk
          return true if @allow_escalation
          unless interactive?
            raise ConsentRequired,
                  "unbounded/high-risk installation requires --allow-escalation in addition to --yes"
          end
          @stdout.print "This workflow includes unbounded actors. Allow high-risk execution? [y/N] "
          %w[y yes].include?(@stdin.gets.to_s.strip.downcase)
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
