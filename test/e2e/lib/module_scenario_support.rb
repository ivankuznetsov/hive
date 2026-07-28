require "digest"
require "fileutils"
require "json"
require "time"
require "hive/attempts/dispatcher"
require "hive/attempts/store"
require "hive/commands/module/install"
require "hive/commands/module/update"
require "hive/module_package/catalog_client"
require "hive/module_package/managed_store"
require "hive/module_package/preview"
require "hive/module_package/validator"
require "hive/modules/decision_journal"
require "hive/modules/dispatcher"
require "hive/modules/entrypoints"
require "hive/modules/event_ledger"
require "hive/modules/inspector"
require "hive/web/module_lifecycle"
require "hive/workflow_package/canonical_yaml"

module Hive
  module E2E
    # Scenario-level acceptance helpers. They use the production stores,
    # preview transaction, dispatcher, attempts, status, and Web presenter;
    # only catalog transport and detached process launch are replaced with
    # deterministic local fixtures.
    module ModuleScenarioSupport
      REPO_ROOT = File.expand_path("../../..", __dir__)
      PROJECT_ID = "e2e-project-0001"
      START = Time.utc(2026, 7, 22, 10, 0, 0)

      class RecordingLauncher
        attr_reader :launches

        def initialize
          @launches = []
        end

        def preflight! = true

        def launch(record, claim_capability:)
          @launches << [ record, claim_capability ]
          { "claimed" => true }
        end
      end

      FakeCatalog = Data.define(:package_root, :resolution) do
        def fetch(_source, destination:)
          FileUtils.cp_r(File.join(package_root, "."), destination)
          resolution
        end
      end

      module_function

      def fresh_install!(sandbox:, run_home:)
        store = module_store(sandbox)
        %w[patrol architecture-patrol].each do |name|
          package = File.join(REPO_ROOT, "modules", name)
          resolution, descriptor = resolution_for(package)
          install!(store, package, resolution, descriptor, now: START)
        end

        attempt_store = attempt_store(run_home)
        inspector_rows = Hive::Modules::Inspector.new(
          store: store, project_id: PROJECT_ID,
          attempt_store: attempt_store, clock: -> { START + 60 }
        ).all.map(&:to_h)
        project = {
          "path" => sandbox, "hive_state_path" => state_path(sandbox),
          "project_id" => PROJECT_ID
        }
        web_rows = Hive::Web::ModuleLifecycle.new(
          attempt_store: attempt_store, clock: -> { START + 60 }
        ).list(project)
        raise "CLI and Web status projections differ" unless inspector_rows == web_rows
        raise "expected two active first-party modules" unless inspector_rows.size == 2 &&
          inspector_rows.all? { |row| row.fetch("lifecycle_state") == "active" }

        write_proof(run_home, "module-fresh-install.json",
                    "ok" => true, "modules" => inspector_rows.map { |row| row.fetch("name") })
      end

      def trigger_replay!(sandbox:, run_home:)
        runtime = demo_runtime(sandbox:, run_home:, installed_at: START)
        event = record_event(runtime, key: "task-completed-1", occurred_at: START + 60)
        first = runtime.fetch(:dispatcher).dispatch(module_name: "demo", hook_id: "task", event: event)
        replay = runtime.fetch(:dispatcher).dispatch(module_name: "demo", hook_id: "task", event: event)
        attempts = runtime.fetch(:attempt_store).scan.records
        decisions = runtime.fetch(:journal).all

        raise "first occurrence was not admitted" unless first.launched?
        raise "replay was not an explainable duplicate" unless replay.decision.fetch("reason") == "duplicate"
        raise "replay created duplicate attempts" unless attempts.one? && attempts.first.module_hook?
        raise "expected launch and skip receipts" unless decisions.map { |row| row.fetch("reason") } ==
          %w[admitted duplicate]
        raise "replay launched a second owner" unless runtime.fetch(:launcher).launches.one?

        write_proof(run_home, "module-trigger-replay.json",
                    "ok" => true, "attempts" => attempts.size,
                    "decisions" => decisions.map { |row| row.fetch("reason") })
      end

      def update_rollback!(sandbox:, run_home:)
        register_demo_entrypoint!
        store = module_store(sandbox)
        packages = File.join(state_path(sandbox), "e2e-packages")
        first_root = File.join(packages, "v1")
        second_root = File.join(packages, "v2")
        failed_root = File.join(packages, "failed")
        first = write_demo_package(first_root, version: "1.0.0", commit: "a" * 40)
        second = write_demo_package(second_root, version: "1.1.0", commit: "b" * 40)
        failed = write_demo_package(failed_root, version: "2.0.0", commit: "c" * 40)

        install!(store, first_root, *first, now: START)
        update!(store, second_root, *second, now: START + 60)
        begin
          update!(store, failed_root, *failed, now: START + 120,
                  health_check: ->(*) { raise "unsafe token=not-for-output" })
          raise "failed activation unexpectedly succeeded"
        rescue Hive::ConfigError => e
          raise unless e.message.include?("activation health check failed")
        end

        after_failure = store.selected("demo")
        raise "failed activation changed active generation" unless
          after_failure.dig("active", "source_commit") == "b" * 40
        raise "failed candidate executable was retained" if
          File.exist?(store.generation_path("demo", "c" * 40))
        diagnostic = File.binread(store.failed_activation_path("demo"))
        raise "activation diagnostic leaked unsafe stderr" if diagnostic.include?("not-for-output")

        restored = store.restore_previous(
          "demo", expected_active: after_failure.fetch("active"), now: START + 180
        )
        raise "explicit rollback did not restore previous generation" unless
          restored.dig("active", "source_commit") == "a" * 40

        write_proof(run_home, "module-update-rollback.json",
                    "ok" => true, "active" => restored.dig("active", "source_commit"),
                    "previous" => restored.dig("previous", "source_commit"))
      end

      def disable_uninstall!(sandbox:, run_home:)
        runtime = demo_runtime(sandbox:, run_home:, installed_at: START)
        store = runtime.fetch(:store)
        baseline = Time.iso8601(store.selected("demo").fetch("high_water_at"))
        store.disable("demo", now: baseline + 60)
        disabled_event = record_event(
          runtime, key: "disabled-interval", occurred_at: baseline + 120
        )
        disabled = runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: disabled_event
        )
        store.enable("demo", now: baseline + 180)
        stale = runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: disabled_event
        )
        store.uninstall("demo", now: baseline + 240)
        uninstalled_event = record_event(
          runtime, key: "after-uninstall", occurred_at: baseline + 300
        )
        uninstalled = runtime.fetch(:dispatcher).dispatch(
          module_name: "demo", hook_id: "task", event: uninstalled_event
        )

        reasons = [ disabled, stale, uninstalled ].map { |result| result.decision.fetch("reason") }
        raise "lifecycle watermarks did not block admission: #{reasons.inspect}" unless
          reasons == %w[disabled cursor_stale uninstalled]
        raise "disabled or uninstalled module created an attempt" unless
          runtime.fetch(:attempt_store).scan.records.empty?
        tombstone = store.selected("demo", include_tombstone: true)
        raise "uninstall did not retain tombstone history" unless
          tombstone && !tombstone.fetch("installed") && File.directory?(store.runtime_path("demo"))

        write_proof(run_home, "module-disable-uninstall.json",
                    "ok" => true, "reasons" => reasons,
                    "history_available" => true)
      end

      def demo_runtime(sandbox:, run_home:, installed_at:)
        register_demo_entrypoint!
        store = module_store(sandbox)
        package = File.join(state_path(sandbox), "e2e-packages", "runtime")
        resolution, descriptor = write_demo_package(package, version: "1.0.0", commit: "d" * 40)
        install!(store, package, resolution, descriptor, now: installed_at)
        attempts = attempt_store(run_home)
        launcher = RecordingLauncher.new
        attempt_number = 0
        attempt_dispatcher = Hive::Attempts::Dispatcher.new(
          store: attempts, launcher: launcher,
          id_generator: -> { attempt_number += 1; "module-e2e-attempt-#{attempt_number}" },
          capability_generator: -> { "e" * 64 }
        )
        ledger_root = File.join(state_path(sandbox), "module-runtime")
        ledger = Hive::Modules::EventLedger.new(root: ledger_root)
        decision_number = 0
        journal = Hive::Modules::DecisionJournal.new(
          root: ledger_root,
          id_generator: -> { decision_number += 1; "module-e2e-decision-#{decision_number}" }
        )
        dispatcher = Hive::Modules::Dispatcher.new(
          store: store, attempt_store: attempts, attempt_dispatcher: attempt_dispatcher,
          project_id: PROJECT_ID, project: File.basename(sandbox),
          decision_journal: journal, clock: -> { START + 600 }
        )
        { store: store, attempt_store: attempts, launcher: launcher,
          ledger: ledger, journal: journal, dispatcher: dispatcher }
      end

      def record_event(runtime, key:, occurred_at:)
        selection = runtime.fetch(:store).selected("demo", include_tombstone: true)
        watermark = selection && selection["high_water_at"] &&
          Time.iso8601(selection.fetch("high_water_at")) + 1
        occurred_at = [ occurred_at, watermark ].compact.max
        runtime.fetch(:ledger).record(
          project_id: PROJECT_ID, project: "sandbox", event_name: "task.completed",
          occurred_at: occurred_at, source: { type: "task", id: key },
          idempotency_key: key, payload: { "task_id" => key }, recorded_at: occurred_at
        ).event
      end

      def register_demo_entrypoint!
        Hive::Modules::Entrypoints.register("demo.run") { 0 }
      end

      def install!(store, package, resolution, descriptor, now:)
        options = lifecycle_options(store, package, resolution, descriptor)
        preview = Hive::Commands::Module::Install.new(
          "honeycomb/#{descriptor.name}", **options,
          yes: false, dry_run: true, receipt: nil
        ).call!
        Hive::Commands::Module::Install.new(
          "honeycomb/#{descriptor.name}", **options,
          yes: true, dry_run: false, receipt: preview.fetch("preview_receipt")
        ).call!
      end

      def update!(store, package, resolution, descriptor, now:, health_check: nil)
        options = lifecycle_options(
          store, package, resolution, descriptor,
          activation_health_check: health_check
        )
        preview = Hive::Commands::Module::Update.new(
          "honeycomb/#{descriptor.name}", **options,
          yes: false, dry_run: true, receipt: nil
        ).call!
        Hive::Commands::Module::Update.new(
          "honeycomb/#{descriptor.name}", **options,
          yes: true, dry_run: false, receipt: preview.fetch("preview_receipt")
        ).call!
      end

      def lifecycle_options(store, package, resolution, descriptor, activation_health_check: nil)
        {
          project_root: File.dirname(store.hive_state_path), json: true,
          stdout: StringIO.new, settings: default_settings(descriptor).map { |key, value|
            "#{key}=#{value}"
          },
          hooks: default_hooks(descriptor).map { |key, value|
            "#{key}=#{value ? 'enabled' : 'disabled'}"
          },
          grants: grant_choices(descriptor.permissions),
          catalog_client: FakeCatalog.new(package, resolution), store: store,
          committer: ->(*) { },
          setup_context: {
            "project_id" => PROJECT_ID, "project" => File.basename(File.dirname(store.hive_state_path))
          },
          activation_health_check: activation_health_check
        }
      end

      def grant_choices(permissions)
        permissions.flat_map do |key, value|
          if key == "repository_write"
            [ "#{key}=#{value}" ]
          else
            Array(value).map { |item| "#{key}=#{item}" }
          end
        end
      end

      def default_settings(descriptor)
        descriptor.settings.to_h do |setting|
          [ setting.fetch("name"), setting.fetch("default", nil) ]
        end
      end

      def default_hooks(descriptor)
        descriptor.hooks.to_h do |hook|
          [ hook.fetch("id"), hook.fetch("default_enabled") ]
        end
      end

      def resolution_for(package)
        validation = Hive::ModulePackage::Validator.validate!(package, catalog_commit: "f" * 40)
        descriptor = validation.descriptor
        resolution = Hive::ModulePackage::CatalogClient::Resolution.new(
          name: descriptor.name, version: descriptor.version, type: descriptor.type,
          source_commit: descriptor.source.fetch("revision"), catalog_commit: "f" * 40,
          source_revision: descriptor.source.fetch("revision"),
          manifest_digest: validation.manifest.digest,
          summary: descriptor.description,
          package_path: "modules/#{descriptor.name}/#{descriptor.version}",
          descriptor: descriptor
        )
        [ resolution, descriptor ]
      end

      def write_demo_package(root, version:, commit:)
        FileUtils.mkdir_p(root)
        readme = File.join(root, "README.md")
        File.write(readme, "# Demo module\n")
        data = {
          "schema" => "hive-module/v1", "name" => "demo", "version" => version,
          "description" => "E2E demo module", "type" => "patrol",
          "author" => { "name" => "Hive", "url" => "https://hivecli.sh" },
          "license" => "MIT", "hive_min_version" => "0.6.7",
          "source" => { "url" => "https://example.test/demo", "revision" => commit },
          "workflows" => [],
          "hooks" => [
            {
              "id" => "task", "target" => { "kind" => "entrypoint", "id" => "demo.run" },
              "default_enabled" => true, "schedules" => [],
              "events" => [ "task.completed" ], "concurrency" => "drop"
            }
          ],
          "settings" => [
            { "name" => "mode", "type" => "enum", "required" => true,
              "default" => "safe", "values" => %w[safe fast] }
          ],
          "permissions" => {
            "repository_write" => false, "github_mutations" => [],
            "external_commands" => [], "network_hosts" => [],
            "filesystem_read" => [ "repository" ], "filesystem_write" => [], "secrets" => []
          },
          "templates" => [], "docs" => [ "README.md" ],
          "files" => { "README.md" => ::Digest::SHA256.file(readme).hexdigest }
        }
        data["release_sha256"] = ::Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalYAML.dump(data)
        )
        File.binwrite(File.join(root, "module.yml"), Hive::WorkflowPackage::CanonicalYAML.dump(data))
        resolution_for(root)
      end

      def module_store(sandbox)
        Hive::ModulePackage::ManagedStore.new(state_path(sandbox))
      end

      def attempt_store(run_home)
        Hive::Attempts::Store.new(root: File.join(run_home, "attempts"))
      end

      def state_path(sandbox) = File.join(sandbox, ".hive-state")

      def write_proof(run_home, filename, payload)
        File.write(File.join(run_home, filename), JSON.pretty_generate(payload) + "\n")
      end
    end
  end
end
