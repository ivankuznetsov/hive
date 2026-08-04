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
      document.fetch("cases") << document.fetch("cases").first.dup
      File.binwrite(observations, JSON.generate(document))
      duplicate_id = assert_raises(Hive::E2E::PatrolQualification::Error) do
        ObservationReader.new(
          project_root: project, observations_path: observations, catalog: catalog
        ).each { }
      end
      assert_match(/IDs are duplicated/, duplicate_id.message)

      document.fetch("cases").pop
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

  def test_shadow_inventory_rejects_special_oversized_and_unbounded_evidence
    Dir.mktmpdir("patrol-qualification-bounds") do |root|
      project = File.join(root, "project")
      state = File.join(project, ".hive-state")
      FileUtils.mkdir_p(state)
      File.binwrite(File.join(state, "config.yml"), {}.to_yaml)
      catalog = Catalog.load(CATALOG_PATH)
      observations = write_records_and_observations(root, state, catalog)
      directory = File.join(state, "module-runtime/migration/shadow/architecture-patrol")
      special_path = File.join(directory, "#{'f' * 64}.json")

      File.mkfifo(special_path)
      assert_raises(Error) { qualification_reader(project, observations, catalog).each { } }
      FileUtils.rm_f(special_path)

      target = Dir.glob(File.join(directory, "*.json")).first
      File.symlink(target, special_path)
      assert_raises(Error) { qualification_reader(project, observations, catalog).each { } }
      FileUtils.rm_f(special_path)

      File.binwrite(special_path, "x" * (MAX_EVIDENCE_BYTES + 1))
      assert_raises(Error) { qualification_reader(project, observations, catalog).each { } }
      FileUtils.rm_f(special_path)

      excess_paths = 45.times.map do |index|
        path = File.join(directory, "#{format('%064x', 1_000 + index)}.json")
        File.binwrite(path, Hive::E2E::PatrolQualification.canonical({}))
        path
      end
      count_error = assert_raises(Error) do
        qualification_reader(project, observations, catalog).each { }
      end
      assert_match(/file-count bound/, count_error.message)
      excess_paths.each { |path| FileUtils.rm_f(path) }

      aggregate_paths = 16.times.map do |index|
        path = File.join(directory, "#{format('%064x', 2_000 + index)}.json")
        value = { "comparable" => false, "padding" => "x" * (MAX_EVIDENCE_BYTES - 100) }
        File.binwrite(path, Hive::E2E::PatrolQualification.canonical(value))
        path
      end
      byte_error = assert_raises(Error) do
        qualification_reader(project, observations, catalog).each { }
      end
      assert_match(/aggregate byte bound/, byte_error.message)
      aggregate_paths.each { |path| FileUtils.rm_f(path) }

      reader = qualification_reader(project, observations, catalog)
      reader.instance_variable_set(:@deadline, monotonic)
      assert_raises(CampaignTimeout) { reader.each { } }
    end
  end

  def test_report_reader_is_no_follow_bounded_and_deadline_limited
    Dir.mktmpdir("patrol-qualification-report") do |root|
      controller = Controller.allocate
      controller.instance_variable_set(:@deadline, monotonic + 5)
      report = File.join(root, "report.json")
      target = File.join(root, "target.json")
      File.binwrite(target, "{}\n")

      File.mkfifo(report)
      assert_raises(Error) { controller.send(:read_report, report) }
      FileUtils.rm_f(report)

      File.symlink(target, report)
      assert_raises(Error) { controller.send(:read_report, report) }
      FileUtils.rm_f(report)

      File.binwrite(report, "x" * (MAX_EVIDENCE_BYTES + 1))
      assert_raises(Error) { controller.send(:read_report, report) }

      controller.instance_variable_set(:@deadline, monotonic)
      assert_raises(CampaignTimeout) { controller.send(:read_report, target) }
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

  def test_child_process_reaps_descendants_after_terminal_leader_results
    Dir.mktmpdir("patrol-qualification-terminal-cleanup") do |root|
      process = ChildProcess.new(deadline: monotonic + 5, env: { "PATH" => "/usr/bin:/bin" })

      [ 0, 7 ].each do |exit_status|
        pid_path = File.join(root, "descendant-#{exit_status}.pid")
        command = "sleep 30 & child=$!; echo $child > #{pid_path}; exit #{exit_status}"
        if exit_status.zero?
          process.run("/bin/sh", "-c", command, label: "success", cwd: root)
        else
          error = assert_raises(ProcessFailure) do
            process.run("/bin/sh", "-c", command, label: "failure", cwd: root)
          end
          assert_equal [ "exit", exit_status ], [ error.kind, error.status ]
        end
        descendant_pid = Integer(File.binread(pid_path))
        refute process_alive?(descendant_pid), "terminal leader must not leave a descendant"
      end
    end
  end

  def test_controller_uses_only_the_archived_installed_public_boundary
    source = File.binread(File.expand_path("patrol_qualification.rb", __dir__))

    assert_includes source, '"archive", "--format=tar"'
    assert_includes source, "packaging/live_agent_skills/install_candidate_gem.sh"
    assert_includes source, "GIT_CONFIG_KEY_0"
    assert_includes source, '"GIT_CONFIG_NOSYSTEM" => "1"'
    assert_includes source, '"GIT_CONFIG_GLOBAL" => "/dev/null"'
    assert_includes source, '"GIT_CONFIG_SYSTEM" => "/dev/null"'
    assert_includes source, '"GIT_ATTR_NOSYSTEM" => "1"'
    assert_includes source, 'File.join(candidate.fetch("root"), "test/e2e/fixtures/patrol_qualification/catalog.json")'
    assert_includes source, "executing qualification controller differs from the archived candidate"
    assert_includes source, "candidate checkout changed while its archive was captured"
    assert_includes source, '"module", "migration", "deterministic-receipt", "--json"'
    assert_includes source,
                    '"module", "migration", "deterministic-qualification", "--yes", "--json"'
    %w[ManagedStore ModuleScenarioSupport Scheduler Dispatcher].each do |forbidden|
      refute_includes source, forbidden
    end
  end

  def test_controller_closes_git_configuration_and_keeps_one_catalogue_rewrite
    Dir.mktmpdir("patrol-qualification-git-env") do |root|
      controller = Controller.allocate
      controller.instance_variable_set(:@hive_home, File.join(root, "home"))
      controller.instance_variable_set(:@deadline, monotonic + 5)
      controller.send(:setup_process, root)
      env = controller.instance_variable_get(:@env)

      assert_equal "1", env.fetch("GIT_CONFIG_NOSYSTEM")
      assert_equal "/dev/null", env.fetch("GIT_CONFIG_GLOBAL")
      assert_equal "/dev/null", env.fetch("GIT_CONFIG_SYSTEM")
      assert_equal "1", env.fetch("GIT_ATTR_NOSYSTEM")
      assert_equal "4", env.fetch("GIT_CONFIG_COUNT")
      assert_equal %w[core.hooksPath commit.gpgsign tag.gpgsign credential.helper],
                   4.times.map { |index| env.fetch("GIT_CONFIG_KEY_#{index}") }

      source = File.binread(File.expand_path("patrol_qualification.rb", __dir__))
      assert_includes source, '"GIT_CONFIG_COUNT" => "5"'
      assert_includes source, '"GIT_CONFIG_KEY_4" => "url.file://#{catalog_repo}/.insteadOf"'
      refute_includes source, '"GIT_CONFIG_KEY_5"'
    end
  end

  def test_candidate_capture_pins_archive_and_rechecks_the_checkout
    Dir.mktmpdir("patrol-qualification-candidate") do |root|
      fixture = File.join(root, "fixture")
      archived_controller = File.join(fixture, "test/e2e/lib/patrol_qualification.rb")
      FileUtils.mkdir_p(File.dirname(archived_controller))
      FileUtils.cp(File.expand_path("patrol_qualification.rb", __dir__), archived_controller)
      run_root = File.join(root, "run")
      FileUtils.mkdir_p(run_root)
      sha = "a" * 40
      labels = []
      controller = Controller.allocate
      controller.instance_variable_set(:@repo_root, fixture)
      controller.instance_variable_set(:@deadline, monotonic + 5)
      controller.define_singleton_method(:git) do |*arguments, label:, **|
        labels << label
        case label
        when "resolve candidate", "recheck candidate head"
          Result.new("#{sha}\n", "", 0)
        when "inspect candidate", "recheck candidate cleanliness"
          Result.new("", "", 0)
        when "archive candidate"
          archive = arguments.fetch(arguments.index("--output") + 1)
          system("tar", "-cf", archive, "-C", fixture, ".", exception: true)
          Result.new("", "", 0)
        else
          flunk("unexpected Git label #{label}")
        end
      end
      controller.define_singleton_method(:run) do |*command, **|
        system(*command, exception: true)
        Result.new("", "", 0)
      end

      candidate = controller.send(:materialize_candidate, run_root)

      assert_equal sha, candidate.fetch("sha")
      assert_equal [
        "resolve candidate", "inspect candidate", "archive candidate",
        "recheck candidate head", "recheck candidate cleanliness"
      ], labels
    end
  end

  def test_module_install_contract_rejects_noop_or_unbound_responses
    controller = Controller.allocate
    expected = {
      "version" => "0.1.0", "catalog_commit" => "a" * 40,
      "source_commit" => "b" * 40, "manifest_digest" => "c" * 64,
      "configuration_digest" => "d" * 64
    }
    lifecycle = {
      "schema" => "hive-module-lifecycle", "schema_version" => 1,
      "ok" => true, "operation" => "install", "status" => "installed",
      "name" => "patrol", "selection" => { "active" => expected }
    }
    inspection = {
      "schema" => "hive-module-status", "schema_version" => 1, "ok" => true,
      "modules" => [
        {
          "name" => "patrol", "lifecycle_state" => "active", "installed" => true,
          "enabled" => true, "failure_reason" => nil, "active" => expected,
          "integrity" => {
            "configuration_valid" => true, "generation_present" => true,
            "activation_fenced" => false, "journal_present" => false
          }
        }
      ]
    }

    controller.send(:validate_lifecycle!, lifecycle, name: "patrol", statuses: [ "installed" ])
    controller.send(:validate_generation!, expected, expected, name: "patrol")
    controller.send(:validate_inspection!, inspection, name: "patrol", expected: expected)
    assert_raises(Hive::E2E::PatrolQualification::Error) do
      controller.send(:validate_lifecycle!, {}, name: "patrol", statuses: [ "installed" ])
    end
    assert_raises(Hive::E2E::PatrolQualification::Error) do
      controller.send(:validate_generation!, {}, expected, name: "patrol")
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

      noisy_pid_path = File.join(root, "noisy.pids")
      noisy = ChildProcess.new(deadline: monotonic + 5, env: { "PATH" => "/usr/bin:/bin" })
      timeout = 0.25
      started = monotonic
      assert_raises(ChildTimeout) do
        program = <<~RUBY
          STDOUT.sync = true
          worker = spawn(#{RbConfig.ruby.inspect}, "-e", "sleep 30")
          File.write(#{noisy_pid_path.inspect}, "\#{Process.pid} \#{worker}")
          chunk = "x" * 16_384
          loop { STDOUT.write(chunk) }
        RUBY
        noisy.run(
          RbConfig.ruby, "-e", program, label: "noisy", cwd: root,
          stdin_data: "i" * (2 * 1024 * 1024), timeout: timeout
        )
      end
      elapsed = monotonic - started
      assert_operator elapsed, :>=, timeout * 0.6,
                      "timeout should track the requested deadline instead of firing immediately"
      assert_operator elapsed, :<, 1.5,
                      "blocked stdin and noisy stdout must remain under the child deadline"
      leader_pid, worker_pid = File.binread(noisy_pid_path).split.map { |value| Integer(value) }
      refute process_alive?(leader_pid), "timed-out leader must be gone"
      refute process_group_alive?(leader_pid), "timed-out process group must be gone"
      refute process_alive?(worker_pid), "timed-out worker must be gone"
    end
  end

  def test_process_outcome_statuses_are_kind_specific
    reader = ObservationReader.allocate
    valid = ->(kind, status, fault = "provider_failure") do
      reader.send(:valid_process_outcomes?,
                  "fault_observed" => fault,
                  "process_outcomes" => [ { "kind" => kind, "status" => status } ])
    end

    assert valid.call("exit", 0, "none")
    assert valid.call("exit", 255)
    assert valid.call("signal", Signal.list.fetch("TERM"))
    assert valid.call("child_timeout", CHILD_TIMEOUT_STATUS)
    [ -1, 256, "7" ].each { |status| refute valid.call("exit", status) }
    [ 0, 999, "15" ].each { |status| refute valid.call("signal", status) }
    [ 0, 123, "124" ].each { |status| refute valid.call("child_timeout", status) }
  end

  def test_evidence_redacts_secret_patterns_inside_error_strings
    Dir.mktmpdir("patrol-qualification-redaction") do |root|
      controller = Controller.allocate
      controller.instance_variable_set(:@evidence_root, root)
      token = "github_pat_#{'A' * 40}"

      path = controller.send(:write_evidence,
                             "status" => "failed", "error" => "request rejected: #{token}")
      bytes = File.binread(path)

      refute_includes bytes, token
      assert_includes bytes, "[REDACTED:github_fine_grained_pat]"
      assert_empty Hive::SecretPatterns.scan(bytes)
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
    candidate = {
      "sha" => "a" * 40, "archive_sha256" => "b" * 64,
      "gem_sha256" => "c" * 64, "installed_hive_sha256" => "d" * 64
    }
    prepared = qualification_prepared(catalog, candidate, case_results)
    report = qualification_report(catalog, candidate, prepared)

    proof = controller.send(:proof, candidate, catalog, report, prepared)

    assert_equal 20, proof.fetch("e2e_case_count")
    assert_equal 4, proof.fetch("focused_contract_count")
    assert_equal "d" * 64, proof.fetch("installed_hive_sha256")
    assert_equal catalog.cases.map(&:id).sort,
                 proof.fetch("case_results").map { |row| row.fetch("id") }
    assert proof.fetch("case_results").all? { |row| row.fetch("process_outcomes").is_a?(Array) }

    stale = Marshal.load(Marshal.dump(report))
    stale["candidate_sha"] = "f" * 40
    stale["report_id"] = digest_id("report", stale, "report_id")
    assert_raises(Hive::E2E::PatrolQualification::Error) do
      controller.send(:proof, candidate, catalog, stale, prepared)
    end
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

  def qualification_prepared(catalog, candidate, case_results)
    common = {
      "run_id" => "u3br-test", "candidate_sha" => candidate.fetch("sha"),
      "catalog_digest" => "1" * 64, "source_digest" => "2" * 64,
      "manifest_digest" => "3" * 64, "scenario_manifest_digest" => "4" * 64
    }
    receipts = catalog.cases.map.with_index do |case_row, index|
      module_index = catalog.cases.count do |candidate_row|
        candidate_row.module_name == case_row.module_name && candidate_row.id <= case_row.id
      end - 1
      repository_sha = if case_row.module_name == "patrol"
        (module_index < 5 ? "a" : "b") * 40
      else
        format("%040x", module_index + 1)
      end
      common.merge(
        "receipt_id" => "evidence-#{format('%064x', index + 1)}",
        "configuration_digest" => (case_row.module_name == "patrol" ? "c" : "d") * 64,
        "module_projection" => { "module" => case_row.module_name },
        "decision_class" => case_row.decision_class,
        "repository" => {
          "id" => "github.com/acme/demo", "sha" => repository_sha,
          "change_window" => "window-#{case_row.id}"
        }
      )
    end
    { "receipts" => receipts, "case_results" => case_results, "common" => common }
  end

  def qualification_report(catalog, candidate, prepared)
    summaries = MODULES.to_h do |name|
      receipts = prepared.fetch("receipts").select do |receipt|
        receipt.dig("module_projection", "module") == name
      end
      [ name, {
        "decision_count" => receipts.size,
        "decision_identities" => receipts.each_index.map { |index| "decision-#{format('%064x', index + 1)}" },
        "decision_classes" => receipts.map { |row| row.fetch("decision_class") }.uniq.sort,
        "repository_shas" => receipts.map { |row| row.dig("repository", "sha") }.uniq.sort,
        "change_windows" => receipts.map { |row| row.dig("repository", "change_window") }.uniq.sort,
        "configuration_digest" => receipts.first.fetch("configuration_digest"),
        "elapsed_seconds" => 1, "blockers" => []
      } ]
    end
    common = prepared.fetch("common")
    lane = common.merge(
      "lane" => "deterministic", "status" => "qualified",
      "receipt_ids" => prepared.fetch("receipts").map { |row| row.fetch("receipt_id") }.sort,
      "decision_replay_count" => 0, "modules" => summaries,
      "effect_count" => 0, "effect_replay_count" => 0,
      "duplicate_effects" => [], "unsettled_effects" => [], "elapsed_seconds" => 1,
      "evidence_started_at" => "2026-08-04T10:00:00.000000Z", "blockers" => [],
      "supersedes" => nil, "contradiction" => nil,
      "generated_at" => "2026-08-04T10:01:00.000000Z"
    )
    lane["qualification_id"] = digest_id("qualification", lane, "qualification_id")
    report = {
      "schema" => "hive-module-migration-report", "schema_version" => 2,
      "generated_at" => "2026-08-04T10:01:00.000000Z",
      "candidate_sha" => candidate.fetch("sha"),
      "scenario_manifest_digest" => common.fetch("scenario_manifest_digest"),
      "status" => "evidence_required",
      "lanes" => { "deterministic" => lane, "installed_live" => nil },
      "blockers" => [ "installed_live:evidence_required" ],
      "supersedes" => nil, "migration" => nil
    }
    report.merge("report_id" => digest_id("report", report, "report_id"))
  end

  def digest_id(prefix, value, key)
    payload = value.reject { |name, _| name == key }
    "#{prefix}-#{Digest::SHA256.hexdigest(Hive::E2E::PatrolQualification.canonical(payload))}"
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

  def qualification_reader(project, observations, catalog)
    ObservationReader.new(
      project_root: project, observations_path: observations, catalog: catalog,
      deadline: monotonic + 5
    )
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def process_group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  end
end
