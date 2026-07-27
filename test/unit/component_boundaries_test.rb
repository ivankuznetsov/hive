require "test_helper"
require_relative "../support/component_boundary_contract"

class ComponentBoundariesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CATALOG = File.join(ROOT, "config", "component-boundaries.yml")

  def setup
    @document = YAML.safe_load_file(CATALOG, aliases: false)
  end

  def test_committed_catalog_describes_all_retained_components
    contract = ComponentBoundaryContract.new(@document, root: ROOT)

    assert contract.validate!
    assert_equal %w[
      agent-abi
      agent-artifact-firewall
      attempts
      safe-agent-git-gate
      skillpack
      user-service
      work-ledger
    ], contract.components.map { |component| component.fetch("id") }.sort

    attempts = contract.component("attempts")
    assert_equal "candidate", attempts.fetch("state")
    assert_equal "hive/attempts/api", attempts.dig("entrypoint", "require")
    assert_equal "Hive::Attempts::API", attempts.dig("entrypoint", "constant")
    assert_equal [ "work-ledger" ], attempts.fetch("component_dependencies")
    assert_equal(
      [
        {
          "reason" => "WorkLedger-owned lib/hive/task_projection/store.rb still requires and constructs Hive::Attempts::Store, creating a reciprocal Attempts/WorkLedger source edge that blocks an acyclic boundary-ready graph.",
          "removal_unit" => "U8"
        }
      ],
      attempts.fetch("migration_exceptions")
    )
    assert_equal %w[
      Hive::Attempts::ClientResult
      Hive::Attempts::DispatchResult
    ], attempts.dig("public_contract", "values")
    expected_internal_collaborators = %w[
      Hive::Attempts::CapacitySnapshot
      Hive::Attempts::Client
      Hive::Attempts::ConfiguredDispatcher
      Hive::Attempts::DetachedLauncher
      Hive::Attempts::Dispatcher
      Hive::Attempts::Entrypoint
      Hive::Attempts::LostOutcomeProcessor
      Hive::Attempts::LostOutcomeStore
      Hive::Attempts::ProcessIdentity
      Hive::Attempts::Reconciler
      Hive::Attempts::Store
      Hive::Attempts::Supervisor
    ]
    assert_equal expected_internal_collaborators,
                 attempts.fetch("internal_collaborators").sort
    assert_equal expected_internal_collaborators,
                 attempts.fetch("forbidden_constructions").sort
    assert_equal(
      {
        "Hive::Attempts::LostOutcomeProcessor" => [ "lib/hive/commands/daemon.rb" ],
        "Hive::Attempts::LostOutcomeStore" => [ "lib/hive/commands/daemon.rb" ],
        "Hive::Attempts::ProcessIdentity" => [ "lib/hive/commands/daemon.rb" ],
        "Hive::Attempts::Reconciler" => [ "lib/hive/commands/daemon.rb" ],
        "Hive::Attempts::Store" => [
          "lib/hive/commands/attempt_supervise.rb",
          "lib/hive/commands/daemon.rb",
          "lib/hive/conditions/execute_boundary.rb",
          "lib/hive/implementation_identity/store.rb",
          "lib/hive/task_closure.rb",
          "lib/hive/task_projection/store.rb"
        ],
        "Hive::Attempts::Supervisor" => [ "lib/hive/commands/attempt_supervise.rb" ]
      },
      attempts.fetch("authorized_internal_constructions").to_h do |entry|
        [ entry.fetch("constant"), entry.fetch("files") ]
      end
    )
    user_service = contract.component("user-service")
    assert_equal "boundary-ready", user_service.fetch("state")
    assert_equal "hive/user_service", user_service.dig("entrypoint", "require")
    assert_equal "Hive::UserService", user_service.dig("entrypoint", "constant")
    assert_equal(
      %w[
        Hive::UserService::Definition
        Hive::UserService::Plan
        Hive::UserService::Result
        Hive::UserService::Status
      ],
      user_service.dig("public_contract", "values").sort
    )
    assert_equal [ "Hive::UserService::Manager" ],
                 user_service.fetch("forbidden_constructions")
    assert_empty user_service.fetch("migration_exceptions")

    ready_components = [ user_service ]

    clean_load = contract.validate_clean_load!("attempts")
    assert_equal "Hive::Attempts::API", clean_load.fetch("constant")
    assert_empty clean_load.fetch("forbidden_loaded_features")
    assert_empty clean_load.fetch("forbidden_constants")

    agent_abi = contract.component("agent-abi")
    assert_equal "boundary-ready", agent_abi.fetch("state")
    assert_equal "hive/agent_runtime", agent_abi.dig("entrypoint", "require")
    assert_equal "Hive::AgentRuntime", agent_abi.dig("entrypoint", "constant")
    assert_includes agent_abi.dig("public_contract", "values"),
                    "Hive::AgentRuntime::ObservableResult"
    assert_includes agent_abi.dig("public_contract", "errors"),
                    "Hive::AgentRuntime::UnsupportedCapability"
    assert_empty agent_abi.fetch("migration_exceptions")

    artifact_firewall = contract.component("agent-artifact-firewall")
    assert_equal "boundary-ready", artifact_firewall.fetch("state")
    assert_equal "hive/artifact_firewall",
                 artifact_firewall.dig("entrypoint", "require")
    assert_equal "Hive::ArtifactFirewall",
                 artifact_firewall.dig("entrypoint", "constant")
    assert_includes artifact_firewall.dig("public_contract", "values"),
                    "Hive::ArtifactFirewall::Report"
    assert_includes artifact_firewall.dig("public_contract", "errors"),
                    "Hive::ArtifactFirewall::InvalidManifest"
    assert_equal [ "Hive::ProtectedFiles" ],
                 artifact_firewall.fetch("internal_collaborators")
    assert_empty artifact_firewall.fetch("migration_exceptions")

    skillpack = contract.component("skillpack")
    assert_equal "boundary-ready", skillpack.fetch("state")
    assert_equal "hive/agent_skills", skillpack.dig("entrypoint", "require")
    assert_equal "Hive::AgentSkills", skillpack.dig("entrypoint", "constant")
    assert_equal(
      %w[
        Hive::AgentSkills::Plan
        Hive::AgentSkills::Projection
        Hive::AgentSkills::ProjectionReport
      ],
      skillpack.dig("public_contract", "values").sort
    )
    assert_includes skillpack.dig("public_contract", "errors"),
                    "Hive::AgentSkills::StalePlan"
    assert_includes skillpack.fetch("forbidden_constructions"),
                    "Hive::AgentSkills::DirectoryPublisher"
    assert_empty skillpack.fetch("migration_exceptions")

    ready_components.push(agent_abi, artifact_firewall, skillpack)
    remaining_candidates = contract.components.reject do |component|
      ready_components.include?(component)
    end
    assert remaining_candidates.all? { |component| component.fetch("state") == "candidate" }

    ready_loads = contract.validate_clean_loads!
    assert_equal %w[
      agent-abi
      agent-artifact-firewall
      skillpack
      user-service
    ], ready_loads.keys.sort
    agent_abi_load = ready_loads.fetch("agent-abi")
    assert_equal "Hive::AgentRuntime", agent_abi_load.fetch("constant")
    assert_empty agent_abi_load.fetch("forbidden_loaded_features")
    assert_empty agent_abi_load.fetch("forbidden_constants")
    user_service_load = ready_loads.fetch("user-service")
    assert_equal "Hive::UserService", user_service_load.fetch("constant")
    assert_empty user_service_load.fetch("forbidden_loaded_features")
    assert_empty user_service_load.fetch("forbidden_constants")
    artifact_firewall_load = ready_loads.fetch("agent-artifact-firewall")
    assert_equal "Hive::ArtifactFirewall", artifact_firewall_load.fetch("constant")
    assert_empty artifact_firewall_load.fetch("forbidden_loaded_features")
    assert_empty artifact_firewall_load.fetch("forbidden_constants")
    skillpack_load = ready_loads.fetch("skillpack")
    assert_equal "Hive::AgentSkills", skillpack_load.fetch("constant")
    assert_empty skillpack_load.fetch("forbidden_loaded_features")
    assert_empty skillpack_load.fetch("forbidden_constants")
  end

  def test_production_consumers_do_not_bypass_artifact_firewall
    allowed = %w[
      lib/hive/artifact_firewall.rb
      lib/hive/protected_files.rb
    ]
    offenders = Dir.glob(File.join(ROOT, "lib", "hive", "**", "*.rb")).filter_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next if allowed.include?(relative)

      source = File.read(path)
      relative if source.include?("Hive::ProtectedFiles") ||
                  source.match?(/require ["']hive\/protected_files["']/)
    end

    assert_empty offenders,
                 "Hive production consumers must use Hive::ArtifactFirewall: #{offenders.join(', ')}"
  end

  def test_production_consumers_do_not_require_skillpack_internals
    owned = contract_component_owned_files("skillpack")
    internal_require = %r{
      require\ ["']hive/agent_skills/
      (?:adapters|canonical_skill|command_runner|directory_publisher|
         errors|filesystem_inventory|inspector|manifest|provisioner|target_resolver)
    }x
    offenders = Dir.glob(File.join(ROOT, "lib", "hive", "**", "*.rb")).filter_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next if owned.include?(relative)

      relative if File.read(path).match?(internal_require)
    end

    assert_empty offenders,
                 "Hive production consumers must require hive/agent_skills: #{offenders.join(', ')}"
  end

  def test_invalid_catalog_rows_name_the_component_and_field
    cases = {
      "missing entry point" => lambda do |document|
        component(document, "attempts").fetch("entrypoint")["file"] = "lib/hive/missing.rb"
      end,
      "duplicate owned path" => lambda do |document|
        component(document, "user-service").fetch("owned_paths") <<
          component(document, "attempts").fetch("owned_paths").first
      end,
      "unknown dependency" => lambda do |document|
        component(document, "attempts").fetch("component_dependencies") << "missing"
      end,
      "dependency cycle" => lambda do |document|
        component(document, "attempts").fetch("component_dependencies") << "user-service"
        component(document, "user-service").fetch("component_dependencies") << "attempts"
      end,
      "missing wiki page" => lambda do |document|
        component(document, "attempts")["wiki_page"] = "wiki/modules/missing.md"
      end,
      "unbounded migration exception" => lambda do |document|
        component(document, "attempts")["migration_exceptions"] = [
          { "reason" => "temporary upward edge" }
        ]
      end
    }

    cases.each do |label, mutation|
      document = Marshal.load(Marshal.dump(@document))
      mutation.call(document)

      error = assert_raises(ComponentBoundaryContract::ValidationError, label) do
        ComponentBoundaryContract.new(document, root: ROOT).validate_catalog!
      end

      assert_match(/attempts|user-service/, error.message, label)
      assert_match(/entrypoint|owned_paths|component_dependencies|wiki_page|migration_exceptions/,
                   error.message, label)
    end
  end

  def test_boundary_ready_component_rejects_bounded_migration_exception
    with_contract_fixture(
      entrypoint_source: example_api_source,
      migration_exceptions: [
        { "reason" => "temporary upward edge", "removal_unit" => "U3" }
      ]
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_catalog!
      end

      assert_match(/example\.migration_exceptions/, error.message)
      assert_match(/boundary-ready components cannot retain exceptions/, error.message)
    end
  end

  def test_candidate_component_accepts_bounded_migration_exception
    with_contract_fixture(
      entrypoint_source: example_api_source,
      state: "candidate",
      migration_exceptions: [
        { "reason" => "temporary upward edge", "removal_unit" => "U3" }
      ]
    ) do |contract|
      assert contract.validate_catalog!
    end
  end

  def test_attempts_cannot_be_promoted_while_work_ledger_remains_candidate
    document = Marshal.load(Marshal.dump(@document))
    attempts = component(document, "attempts")
    attempts["state"] = "boundary-ready"
    attempts["migration_exceptions"] = []

    error = assert_raises(ComponentBoundaryContract::ValidationError) do
      ComponentBoundaryContract.new(document, root: ROOT).validate_catalog!
    end

    assert_match(/attempts\.component_dependencies/, error.message)
    assert_match(/cannot depend on candidate "work-ledger"/, error.message)
  end

  def test_migration_exception_requires_valid_removal_unit
    with_contract_fixture(
      entrypoint_source: example_api_source,
      state: "candidate",
      migration_exceptions: [
        { "reason" => "temporary upward edge", "removal_unit" => "later" }
      ]
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_catalog!
      end

      assert_match(/example\.migration_exceptions\[0\]\.removal_unit/, error.message)
      assert_match(/must name a plan unit such as U3/, error.message)
    end
  end

  def test_migration_exception_requires_non_blank_reason
    with_contract_fixture(
      entrypoint_source: example_api_source,
      state: "candidate",
      migration_exceptions: [
        { "reason" => " ", "removal_unit" => "U3" }
      ]
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_catalog!
      end

      assert_match(/example\.migration_exceptions\[0\]\.reason/, error.message)
      assert_match(/must be a non-empty string/, error.message)
    end
  end

  def test_boundary_ready_entrypoint_loads_cleanly
    with_contract_fixture(entrypoint_source: example_api_source) do |contract|
      result = contract.validate_clean_loads!

      assert_equal [ "example" ], result.keys
      assert_equal "Example::API", result.fetch("example").fetch("constant")
      assert_empty result.fetch("example").fetch("forbidden_loaded_features")
      assert_empty result.fetch("example").fetch("forbidden_constants")
    end
  end

  def test_clean_load_rejects_missing_documented_constant
    with_contract_fixture(entrypoint_source: "module Example; end\n") do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_clean_loads!
      end

      assert_match(/example\.entrypoint\.constant/, error.message)
      assert_match(/Example::API was not defined/, error.message)
    end
  end

  def test_clean_load_reports_entrypoint_failure
    with_contract_fixture(entrypoint_source: "raise \"fixture boom\"\n") do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_clean_loads!
      end

      assert_match(/example\.entrypoint/, error.message)
      assert_match(/clean load failed/, error.message)
      assert_match(/fixture boom/, error.message)
    end
  end

  def test_clean_load_rejects_forbidden_constant
    with_contract_fixture(
      entrypoint_source: <<~RUBY
        module Hive
          module Commands; end
        end
        #{example_api_source}
      RUBY
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_clean_loads!
      end

      assert_match(/example\.entrypoint\.constant/, error.message)
      assert_match(/Hive::Commands/, error.message)
    end
  end

  def test_static_enforcement_uses_ruby_syntax_not_comments_or_examples
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
        end
      RUBY
      consumer_source: <<~RUBY
        # require "hive/commands/run"
        EXAMPLE = 'Example::Internal.new'
        Example::API.new
      RUBY
    ) do |contract|
      assert contract.validate_static_boundaries!
    end
  end

  def test_boundary_ready_upward_require_fails_with_component_and_file
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        require "hive/commands/run"
        module Example
          class API; end
        end
      RUBY
      consumer_source: "Example::API.new\n"
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_static_boundaries!
      end

      assert_match(/example/, error.message)
      assert_match(/lib\/example\.rb/, error.message)
      assert_match(/hive\/commands\/run/, error.message)
    end
  end

  def test_forbidden_upward_require_cannot_be_allowlisted
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        require "hive/commands/run"
        #{example_api_source}
      RUBY
      allowed_hive_dependencies: [ "hive/commands/run" ]
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_catalog!
      end

      assert_match(/example\.allowed_hive_dependencies/, error.message)
      assert_match(/forbidden upward dependency/, error.message)
    end
  end

  def test_require_relative_upward_edge_in_owned_file_fails
    with_contract_fixture(
      entrypoint_source: example_api_source,
      entrypoint_file: "lib/hive/example/api.rb",
      entrypoint_require: "hive/example/api",
      owned_paths: [ "lib/hive/example" ],
      extra_files: {
        "lib/hive/example/worker.rb" => "require_relative \"../commands/run\"\n",
        "lib/hive/commands/run.rb" => "module Hive; module Commands; end; end\n"
      }
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_static_boundaries!
      end

      assert_match(/lib\/hive\/example\/worker\.rb/, error.message)
      assert_match(/hive\/commands\/run/, error.message)
    end
  end

  def test_undeclared_internal_component_require_fails
    with_support_component do |fixture|
      with_contract_fixture(
        entrypoint_source: <<~RUBY,
          require "support/internal"
          #{example_api_source}
        RUBY
        extra_components: [ fixture.fetch(:component) ],
        extra_files: fixture.fetch(:files)
      ) do |contract|
        error = assert_raises(ComponentBoundaryContract::ValidationError) do
          contract.validate_static_boundaries!
        end

        assert_match(/example\.component_dependencies/, error.message)
        assert_match(/support\/internal/, error.message)
      end
    end
  end

  def test_declared_internal_component_require_passes_static_and_clean_load_checks
    with_support_component(state: "boundary-ready") do |fixture|
      with_contract_fixture(
        entrypoint_source: <<~RUBY,
          require "support/internal"
          #{example_api_source}
        RUBY
        component_dependencies: [ "support" ],
        extra_components: [ fixture.fetch(:component) ],
        extra_files: fixture.fetch(:files)
      ) do |contract|
        assert contract.validate_static_boundaries!
        assert_equal "Example::API", contract.validate_clean_load!("example").fetch("constant")
      end
    end
  end

  def test_clean_load_rejects_unrelated_component_owned_feature
    with_support_component do |fixture|
      with_contract_fixture(
        entrypoint_source: <<~RUBY,
          require "support/internal"
          #{example_api_source}
        RUBY
        extra_components: [ fixture.fetch(:component) ],
        extra_files: fixture.fetch(:files)
      ) do |contract|
        error = assert_raises(ComponentBoundaryContract::ValidationError) do
          contract.validate_clean_loads!
        end

        assert_match(/clean load pulled forbidden features/, error.message)
        assert_match(/support\/internal\.rb/, error.message)
      end
    end
  end

  def test_direct_internal_construction_fails_with_component_and_file
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
          class Internal; end
        end
      RUBY
      consumer_source: "Example::Internal.new\n"
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_static_boundaries!
      end

      assert_match(/example/, error.message)
      assert_match(/lib\/consumer\.rb/, error.message)
      assert_match(/Example::Internal/, error.message)
    end
  end

  def test_candidate_still_rejects_direct_internal_construction
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
          class Internal; end
        end
      RUBY
      consumer_source: "Example::Internal.new\n",
      state: "candidate"
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_static_boundaries!
      end

      assert_match(/example\.forbidden_constructions/, error.message)
      assert_match(/lib\/consumer\.rb/, error.message)
      assert_match(/Example::Internal/, error.message)
    end
  end

  def test_unlisted_consumer_cannot_construct_internal_constant
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
          class Internal; end
        end
      RUBY
      consumer_source: "Example::API.new\n",
      extra_files: {
        "lib/unlisted_consumer.rb" => "Example::Internal.new\n"
      }
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_static_boundaries!
      end

      assert_match(/example/, error.message)
      assert_match(/lib\/unlisted_consumer\.rb/, error.message)
      assert_match(/Example::Internal/, error.message)
    end
  end

  def test_named_internal_construction_site_is_allowed
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
          class Internal; end
        end
      RUBY
      consumer_source: "Example::Internal.new\n",
      authorized_internal_constructions: [
        {
          "constant" => "Example::Internal",
          "files" => [ "lib/consumer.rb" ],
          "reason" => "Application composition root"
        }
      ]
    ) do |contract|
      assert contract.validate_static_boundaries!
    end
  end

  def test_named_internal_construction_site_does_not_allow_other_files
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
          class Internal; end
        end
      RUBY
      consumer_source: "Example::Internal.new\n",
      authorized_internal_constructions: [
        {
          "constant" => "Example::Internal",
          "files" => [ "lib/consumer.rb" ],
          "reason" => "Application composition root"
        }
      ],
      extra_files: {
        "lib/unlisted_consumer.rb" => "Example::Internal.new\n"
      }
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_static_boundaries!
      end

      assert_match(/example/, error.message)
      assert_match(/lib\/unlisted_consumer\.rb/, error.message)
      assert_match(/Example::Internal/, error.message)
    end
  end

  def test_named_internal_construction_site_must_remain_in_use
    with_contract_fixture(
      entrypoint_source: <<~RUBY,
        module Example
          class API; end
          class Internal; end
        end
      RUBY
      consumer_source: "Example::API.new\n",
      authorized_internal_constructions: [
        {
          "constant" => "Example::Internal",
          "files" => [ "lib/consumer.rb" ],
          "reason" => "Stale composition root"
        }
      ]
    ) do |contract|
      error = assert_raises(ComponentBoundaryContract::ValidationError) do
        contract.validate_catalog!
      end

      assert_match(/example\.authorized_internal_constructions/, error.message)
      assert_match(/lib\/consumer\.rb does not construct Example::Internal/, error.message)
    end
  end

  def test_invalid_internal_construction_authorizations_name_the_exact_field
    cases = {
      "malformed constant" => {
        mutate: ->(site, _sites) { site["constant"] = "not a constant" },
        field: /authorized_internal_constructions\[0\]\.constant/,
        message: /must be a constant path/
      },
      "undeclared and non-forbidden constant" => {
        mutate: ->(site, _sites) { site["constant"] = "Example::Other" },
        field: /authorized_internal_constructions\[0\]\.constant/,
        message: /must name a declared internal collaborator/
      },
      "declared but non-forbidden constant" => {
        mutate: ->(site, _sites) { site["constant"] = "Example::Other" },
        internal_collaborators: %w[Example::Internal Example::Other],
        field: /authorized_internal_constructions\[0\]\.constant/,
        message: /must name a forbidden construction/
      },
      "duplicate constant entry" => {
        mutate: ->(site, sites) { sites << Marshal.load(Marshal.dump(site)) },
        field: /authorized_internal_constructions\[1\]\.constant/,
        message: /duplicates "Example::Internal"/
      },
      "duplicate file" => {
        mutate: ->(site, _sites) { site["files"] << site.fetch("files").first },
        field: /authorized_internal_constructions\[0\]\.files/,
        message: /must not contain duplicates/
      },
      "component-owned file" => {
        mutate: ->(site, _sites) { site["files"] = [ "lib/owned_builder.rb" ] },
        field: /authorized_internal_constructions\[0\]\.files\[0\]/,
        message: /component-owned files do not need construction authorization/
      },
      "blank reason" => {
        mutate: ->(site, _sites) { site["reason"] = " " },
        field: /authorized_internal_constructions\[0\]\.reason/,
        message: /must be a non-empty string/
      }
    }

    cases.each do |label, expectation|
      sites = [
        {
          "constant" => "Example::Internal",
          "files" => [ "lib/consumer.rb" ],
          "reason" => "Application composition root"
        }
      ]
      expectation.fetch(:mutate).call(sites.first, sites)

      with_contract_fixture(
        entrypoint_source: <<~RUBY,
          module Example
            class API; end
            class Internal; end
          end
        RUBY
        consumer_source: "Example::Internal.new\n",
        owned_paths: [ "lib/example.rb", "lib/owned_builder.rb" ],
        internal_collaborators: expectation[:internal_collaborators],
        authorized_internal_constructions: sites,
        extra_files: {
          "lib/owned_builder.rb" => "Example::Internal.new\n"
        }
      ) do |contract|
        error = assert_raises(ComponentBoundaryContract::ValidationError, label) do
          contract.validate_catalog!
        end

        assert_match expectation.fetch(:field), error.message, label
        assert_match expectation.fetch(:message), error.message, label
      end
    end
  end

  private

  def contract_component_owned_files(id)
    component(@document, id).fetch("owned_paths").flat_map do |relative|
      absolute = File.join(ROOT, relative)
      if File.directory?(absolute)
        Dir.glob(File.join(absolute, "**", "*.rb")).map do |path|
          path.delete_prefix("#{ROOT}/")
        end
      else
        relative
      end
    end
  end

  def component(document, id)
    document.fetch("components").find { |entry| entry.fetch("id") == id }
  end

  def example_api_source
    <<~RUBY
      module Example
        class API; end
      end
    RUBY
  end

  def with_support_component(state: "candidate")
    component = fixture_component(
      id: "support",
      state: state,
      entrypoint_file: "lib/support.rb",
      entrypoint_require: "support",
      entrypoint_constant: "Support::API",
      owned_paths: [ "lib/support.rb", "lib/support" ]
    )
    files = {
      "lib/support.rb" => "module Support; class API; end; end\n",
      "lib/support/internal.rb" => "module Support; class Internal; end; end\n"
    }
    yield({ component: component, files: files })
  end

  def with_contract_fixture(entrypoint_source:, consumer_source: "Example::API.new\n",
                            state: "boundary-ready", entrypoint_file: "lib/example.rb",
                            entrypoint_require: "example", owned_paths: nil,
                            component_dependencies: [], allowed_hive_dependencies: [],
                            migration_exceptions: [], authorized_internal_constructions: [],
                            internal_collaborators: nil,
                            extra_components: [], extra_files: {})
    Dir.mktmpdir do |root|
      write_fixture(root, entrypoint_file, entrypoint_source)
      write_fixture(root, "lib/consumer.rb", consumer_source)
      write_fixture(root, "wiki/example.md", "# Example\n")
      write_fixture(root, "test/example_test.rb", "# fixture\n")
      extra_files.each { |relative, content| write_fixture(root, relative, content) }

      document = {
        "schema_version" => 1,
        "components" => [
          fixture_component(
            id: "example",
            state: state,
            entrypoint_file: entrypoint_file,
            entrypoint_require: entrypoint_require,
            entrypoint_constant: "Example::API",
            owned_paths: owned_paths || [ entrypoint_file ],
            component_dependencies: component_dependencies,
            allowed_hive_dependencies: allowed_hive_dependencies,
            migration_exceptions: migration_exceptions,
            authorized_internal_constructions: authorized_internal_constructions,
            internal_collaborators: internal_collaborators
          ),
          *extra_components
        ]
      }

      yield ComponentBoundaryContract.new(document, root: root)
    end
  end

  def fixture_component(id:, state:, entrypoint_file:, entrypoint_require:, entrypoint_constant:,
                        owned_paths:, component_dependencies: [], allowed_hive_dependencies: [],
                        migration_exceptions: [], authorized_internal_constructions: [],
                        internal_collaborators: nil)
    namespace = entrypoint_constant.split("::").first
    internal_collaborators ||= [ "#{namespace}::Internal" ]
    {
      "id" => id,
      "name" => id.split("-").map(&:capitalize).join(" "),
      "state" => state,
      "entrypoint" => {
        "file" => entrypoint_file,
        "require" => entrypoint_require,
        "constant" => entrypoint_constant
      },
      "public_contract" => {
        "values" => [ entrypoint_constant ],
        "errors" => []
      },
      "owned_paths" => owned_paths,
      "state_contracts" => [ "none" ],
      "schema_contracts" => [ "none" ],
      "lock_contracts" => [ "none" ],
      "component_dependencies" => component_dependencies,
      "allowed_hive_dependencies" => allowed_hive_dependencies,
      "internal_collaborators" => internal_collaborators,
      "forbidden_constructions" => [ "#{namespace}::Internal" ],
      "authorized_internal_constructions" => authorized_internal_constructions,
      "hive_consumers" => [ "lib/consumer.rb" ],
      "mutation_authority" => "none",
      "recovery_surface" => "none",
      "wiki_page" => "wiki/example.md",
      "focused_tests" => [ "test/example_test.rb" ],
      "migration_exceptions" => migration_exceptions
    }
  end

  def write_fixture(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
