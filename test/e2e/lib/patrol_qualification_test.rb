require_relative "../../test_helper"
require_relative "patrol_qualification"

class E2EPatrolQualificationSupportTest < Minitest::Test
  include Hive::E2E::PatrolQualification

  CATALOG_PATH = File.expand_path(
    "../fixtures/patrol_qualification/catalog.json", __dir__
  )
  REPO_ROOT = File.expand_path("../../..", __dir__)

  def test_committed_catalogue_has_exact_e2e_inventory_and_real_focused_links
    catalog = Catalog.load(CATALOG_PATH)

    assert_equal 20, catalog.cases.size
    assert_equal 4, catalog.contracts.size
    assert_equal({ "architecture-patrol" => 10, "patrol" => 10 },
                 catalog.cases.map(&:module_name).tally)
    assert_equal %w[e2e], JSON.parse(File.read(CATALOG_PATH)).fetch("cases")
                                     .map { |row| row.fetch("proof_kind") }.uniq
    catalog.contracts.each do |contract|
      path = File.join(REPO_ROOT, contract.fetch("test_file"))
      assert File.file?(path), contract.fetch("test_file")
      assert_match(/^\s*def #{Regexp.escape(contract.fetch('test_method'))}\b/,
                   File.binread(path), contract.fetch("id"))
    end
  end

  def test_real_reader_enforces_semantics_cardinality_and_does_not_mutate_records
    Dir.mktmpdir("patrol-qualification-reader") do |root|
      project = File.join(root, "project")
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.binwrite(File.join(state, "config.yml"), {}.to_yaml)
      catalog = Catalog.load(CATALOG_PATH)
      observations = write_records_and_observations(root, state, catalog)
      before = tree_digest(state)
      seen = []

      ObservationReader.new(
        project_root: project, observations_path: observations, catalog: catalog
      ).each { |case_row, _, record| seen << [ case_row.id, record.fetch("module") ] }

      assert_equal 20, seen.size
      assert_equal before, tree_digest(state), "the evidence reader must be observation-only"
    end
  end

  def test_reader_rejects_semantic_and_cardinality_drift
    Dir.mktmpdir("patrol-qualification-drift") do |root|
      project = File.join(root, "project")
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.binwrite(File.join(state, "config.yml"), {}.to_yaml)
      catalog = Catalog.load(CATALOG_PATH)
      observations = write_records_and_observations(root, state, catalog)
      path = Dir.glob(File.join(state, "module-runtime/migration/shadow/patrol/*.json")).first
      record = JSON.parse(File.binread(path))
      record.fetch("module_decision")["rationale"] = "fabricated"
      File.binwrite(path, Hive::E2E::PatrolQualification.canonical(record))

      error = assert_raises(Hive::E2E::PatrolQualification::Error) do
        ObservationReader.new(
          project_root: project, observations_path: observations, catalog: catalog
        ).each { }
      end
      assert_match(/decision class differs/, error.message)

      record.fetch("module_decision")["rationale"] = "due"
      File.binwrite(path, Hive::E2E::PatrolQualification.canonical(record))
      document = JSON.parse(File.binread(observations))
      document.fetch("cases")[1]["trigger_id"] = document.fetch("cases")[0].fetch("trigger_id")
      File.binwrite(observations, JSON.generate(document))
      duplicate = assert_raises(Hive::E2E::PatrolQualification::Error) do
        ObservationReader.new(
          project_root: project, observations_path: observations, catalog: catalog
        ).each { }
      end
      assert_match(/selectors do not cover/, duplicate.message)
    end
  end

  def test_child_process_has_allowlisted_environment_and_typed_failures
    Dir.mktmpdir("patrol-qualification-child") do |root|
      env = { "PATH" => "/usr/bin:/bin", "ONLY_ALLOWED" => "yes" }
      process = ChildProcess.new(deadline: monotonic + 5, env: env)
      result = process.run(
        RbConfig.ruby, "-e", "puts ENV.keys.sort", label: "env", cwd: root
      )
      assert_equal %w[ONLY_ALLOWED PATH], result.stdout.lines.map(&:strip)

      exit_error = assert_raises(ProcessFailure) do
        process.run("/bin/sh", "-c", "exit 7", label: "exit", cwd: root)
      end
      assert_equal [ "exit", 7 ], [ exit_error.kind, exit_error.status ]

      signal_error = assert_raises(ProcessFailure) do
        process.run("/bin/sh", "-c", "kill -TERM $$", label: "signal", cwd: root)
      end
      assert_equal "signal", signal_error.kind

      spawn_error = assert_raises(ProcessFailure) do
        process.run(File.join(root, "missing"), label: "spawn", cwd: root)
      end
      assert_equal "spawn", spawn_error.kind
    end
  end

  def test_controller_uses_only_the_archived_installed_public_boundary
    source = File.binread(File.expand_path("patrol_qualification.rb", __dir__))

    assert_includes source, '"archive", "--format=tar"'
    assert_includes source, "packaging/live_agent_skills/install_candidate_gem.sh"
    assert_includes source, "GIT_CONFIG_KEY_0"
    assert_includes source, '"module", "migration", "deterministic-receipt", "--json"'
    assert_includes source,
                    '"module", "migration", "deterministic-qualification", "--yes", "--json"'
    %w[ManagedStore ModuleScenarioSupport Scheduler Dispatcher].each do |forbidden|
      refute_includes source, forbidden
    end
  end

  def test_child_and_campaign_timeouts_are_distinct_and_kill_the_process_group
    Dir.mktmpdir("patrol-qualification-timeout") do |root|
      pid_path = File.join(root, "child.pid")
      command = "sleep 30 & child=$!; echo $child > #{pid_path}; wait"
      process = ChildProcess.new(deadline: monotonic + 5, env: { "PATH" => "/usr/bin:/bin" })
      assert_raises(ChildTimeout) do
        process.run("/bin/sh", "-c", command, label: "child", cwd: root, timeout: 0.1)
      end
      child_pid = Integer(File.read(pid_path))
      refute process_alive?(child_pid), "timeout must kill descendants in the owned group"

      campaign = ChildProcess.new(deadline: monotonic + 0.1, env: { "PATH" => "/usr/bin:/bin" })
      assert_raises(CampaignTimeout) do
        campaign.run("/bin/sh", "-c", "sleep 30", label: "campaign", cwd: root, timeout: 5)
      end

      noisy = ChildProcess.new(deadline: monotonic + 5, env: { "PATH" => "/usr/bin:/bin" })
      started = monotonic
      assert_raises(ChildTimeout) do
        noisy.run(
          RbConfig.ruby, "-e", 'STDOUT.sync = true; chunk = "x" * 16_384; loop { STDOUT.write(chunk) }',
          label: "noisy", cwd: root, stdin_data: "i" * (2 * 1024 * 1024), timeout: 0.1
        )
      end
      assert_operator monotonic - started, :<, 2.0,
                      "blocked stdin and noisy stdout must remain under the child deadline"
    end
  end

  def test_proof_retains_typed_case_results_and_exact_proof_counts
    catalog = Catalog.load(CATALOG_PATH)
    controller = Controller.allocate
    controller.instance_variable_set(:@catalog_commit, "e" * 40)
    case_results = catalog.cases.reverse.map do |case_row|
      {
        "id" => case_row.id, "module" => case_row.module_name,
        "fault" => case_row.fault, "process_outcomes" => process_outcomes(case_row.fault)
      }
    end
    report = {
      "lanes" => {
        "deterministic" => {
          "status" => "qualified", "qualification_id" => "qualification-1",
          "modules" => catalog.expectations.transform_values do |row|
            { "decision_count" => row.fetch("decision_count") }
          end
        }
      }
    }
    prepared = { "receipts" => Array.new(20) { {} }, "case_results" => case_results }
    candidate = {
      "sha" => "a" * 40, "archive_sha256" => "b" * 64,
      "gem_sha256" => "c" * 64, "installed_hive_sha256" => "d" * 64
    }

    proof = controller.send(:proof, candidate, catalog, report, prepared)

    assert_equal 20, proof.fetch("e2e_case_count")
    assert_equal 4, proof.fetch("focused_contract_count")
    assert_equal "d" * 64, proof.fetch("installed_hive_sha256")
    assert_equal catalog.cases.map(&:id).sort,
                 proof.fetch("case_results").map { |row| row.fetch("id") }
    assert proof.fetch("case_results").all? { |row| row.fetch("process_outcomes").is_a?(Array) }
  end

  private

  def write_records_and_observations(root, state, catalog)
    observations = catalog.cases.map.with_index do |case_row, index|
      module_index = catalog.cases.count do |candidate|
        candidate.module_name == case_row.module_name && candidate.id <= case_row.id
      end - 1
      repository_sha = if case_row.module_name == "patrol"
        (module_index < 5 ? "a" : "b") * 40
      else
        format("%040x", module_index + 1)
      end
      trigger_id = "trigger-#{case_row.id}"
      record = {
        "module" => case_row.module_name,
        "trigger" => { "id" => trigger_id },
        "comparable" => true,
        "configuration_digest" => (case_row.module_name == "patrol" ? "c" : "d") * 64,
        "legacy_capture" => {
          "capture_id" => "capture-#{case_row.id}",
          "project" => { "repository" => "github.com/acme/demo" }
        },
        "module_decision" => {
          "module" => case_row.module_name, "rationale" => case_row.decision_class
        },
        "legacy_effects" => [],
        "module_effects" => []
      }
      directory = File.join(state, "module-runtime", "migration", "shadow", case_row.module_name)
      FileUtils.mkdir_p(directory)
      File.binwrite(File.join(directory, "#{format('%064x', index + 1)}.json"),
                    Hive::E2E::PatrolQualification.canonical(record))
      {
        "id" => case_row.id, "trigger_id" => trigger_id,
        "repository_sha" => repository_sha,
        "change_window" => "window-#{case_row.id}",
        "fault_observed" => case_row.fault,
        "process_outcomes" => process_outcomes(case_row.fault)
      }
    end
    path = File.join(root, "observations.json")
    File.binwrite(path, JSON.generate(
      "schema" => "hive-patrol-reduced-observations", "schema_version" => 1,
      "cases" => observations
    ))
    path
  end

  def tree_digest(root)
    Digest::SHA256.hexdigest(
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next unless File.file?(path)
        "#{path.delete_prefix(root)}\0#{Digest::SHA256.file(path).hexdigest}"
      end.join("\0")
    )
  end

  def process_outcomes(fault)
    success = { "kind" => "exit", "status" => 0 }
    case fault
    when "none" then [ success ]
    when "provider_failure", "cli_failure" then [ { "kind" => "exit", "status" => 70 } ]
    when "post_reservation_capture_decision_restart", "finalized_outbox_reconciliation_recovery"
      [ { "kind" => "signal", "status" => 15 }, success ]
    when "released_attempt_retry"
      [ { "kind" => "exit", "status" => 70 }, success ]
    else flunk("unknown fault #{fault}")
    end
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
