require "test_helper"
require "json"
require "hive/config"
require "hive/patrol/reviewer"
require "hive/patrol/feature"
require "hive/usage_db"

class HivePatrolReviewerTest < Minitest::Test
  include HiveTestHelper

  def cfg
    Hive::Config.deep_dup(Hive::Config::DEFAULTS)
  end

  def feature
    Hive::Patrol::Feature.new(
      id: "route-users",
      kind: "route",
      entrypoints: [ "app.rb" ],
      owned_files: [ "app.rb" ],
      context_files: [],
      tests: []
    )
  end

  def qualified_finding(file:, title: "Crash")
    {
      "category" => "bug",
      "severity" => "high",
      "confidence" => "medium",
      "scope" => "cross_feature",
      "title" => title,
      "description" => "A reachable request crashes before returning a response.",
      "recommendation" => "Repair the shared lookup invariant and cover all callers.",
      "contract" => "A missing record must produce a not-found response.",
      "impact" => "A normal user request terminates with an internal error.",
      "root_cause" => "The shared lookup path assumes every id resolves.",
      "reproduction" => "Request the endpoint with a well-formed unknown id.",
      "validation" => "Run the focused request regression and request suite.",
      "evidence" => [
        { "file" => file, "line" => 1, "snippet" => "user.name", "role" => "root_cause" }
      ]
    }
  end

  def with_usage_db
    old_path = Hive::UsageDb.path
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      yield
    ensure
      Hive::UsageDb.path = old_path
    end
  end

  def usage_rows
    require "sqlite3"

    db = SQLite3::Database.new(Hive::UsageDb.path)
    db.results_as_hash = true
    db.execute("SELECT agent, model, project_slug, task_slug, stage, input, output, cached FROM token_usage")
  ensure
    db&.close
  end

  def test_persists_schema_valid_findings_from_agent_output
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [ qualified_finding(file: "app.rb") ]
        ))
      end

      findings = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ])

      assert_equal 1, findings.size
      assert_match(/\Aroute-users-\d{8}T\d{6}Z-[0-9a-f]{8}-1\z/, findings.first.id)
      assert_equal "cross_feature", findings.first.scope
      assert_equal "The shared lookup path assumes every id resolves.", findings.first.root_cause
      assert File.exist?(File.join(dir, ".hive-state", "patrol", "findings", "#{findings.first.id}.json"))
    end
  end

  def test_repeated_reviews_preserve_immutable_finding_records
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate("findings" => [ qualified_finding(file: "app.rb") ]))
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      first = reviewer.call([ feature ]).first
      second = reviewer.call([ feature ]).first

      refute_equal first.id, second.id
      records = Dir[File.join(dir, ".hive-state", "patrol", "findings", "route-users-*.json")]
      assert_equal 2, records.size
    end
  end

  def test_rejects_generic_findings_without_alpha_proof
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [
            {
              "category" => "bug", "severity" => "high", "confidence" => "high",
              "title" => "Could crash", "description" => "Maybe nil.",
              "recommendation" => "Add a guard.",
              "evidence" => [ { "file" => "app.rb", "line" => 1, "snippet" => "user.name" } ]
            }
          ]
        ))
      end

      findings = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ])

      assert_empty findings, "ordinary patrol must reject quota-filling findings without contract, impact, root cause, reproduction, and validation"
    end
  end

  def test_rejects_findings_without_repository_confined_production_evidence
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "test", "app_test.rb"), "assert true\n")
      runner = lambda do |output_path:, **|
        payload = qualified_finding(file: "test/app_test.rb")
        File.write(output_path, JSON.generate("findings" => [ payload ]))
      end

      findings = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ])

      assert_empty findings, "a production finding needs at least one production-code anchor"
    end
  end

  def test_rejects_findings_whose_primary_evidence_does_not_belong_to_the_slice
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      File.write(File.join(dir, "other.rb"), "queue.delete(id)\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [ qualified_finding(file: "other.rb") ]
        ))
      end

      findings = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ])

      assert_empty findings, "cross-feature context may support a finding, but its primary defect must be anchored in the mapped slice"
    end
  end

  def test_orders_owned_root_cause_before_cross_feature_supporting_evidence
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      File.write(File.join(dir, "other.rb"), "request.call\n")
      runner = lambda do |output_path:, **|
        payload = qualified_finding(file: "app.rb")
        payload["evidence"] = [
          { "file" => "other.rb", "line" => 1, "snippet" => "request.call", "role" => "impact" },
          { "file" => "app.rb", "line" => 1, "snippet" => "user.name", "role" => "root_cause" }
        ]
        File.write(output_path, JSON.generate("findings" => [ payload ]))
      end

      finding = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ]).first

      assert_equal "app.rb", finding.evidence.first.fetch("file"),
                   "the primary semantic fingerprint anchor must belong to the mapped slice"
    end
  end

  def test_prompt_prefers_zero_findings_and_requests_root_cause_proof
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      captured = nil
      runner = lambda do |prompt:, output_path:, **|
        captured = prompt
        File.write(output_path, JSON.generate("findings" => []))
      end

      Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ])

      assert_includes captured, "Prefer zero findings"
      assert_includes captured, '"root_cause"'
      assert_includes captured, '"reproduction"'
      assert_includes captured, "Do not return documentation"
      assert_includes captured, "test-gap, or maintainability"
      assert_includes captured, "exact substring"
      assert_includes captured, "single source line"
      assert_match(/Never span multiple\s+lines/, captured)
      assert_includes captured, "rejects the complete finding"
      assert_includes captured, '"snippet": "exact single-line source substring"'
    end
  end

  def test_malformed_agent_json_records_error_and_returns_no_findings
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      runner = ->(output_path:, **) { File.write(output_path, "not-json") }

      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)
      findings = reviewer.call([ feature ])

      assert_empty findings
      error_logs = Dir[File.join(dir, ".hive-state", "patrol", "runs", "review-error-*.json")]
      refute_empty error_logs
      assert_equal 1, reviewer.review_errors.size
      assert_equal "malformed_json", reviewer.review_errors.first["error"]
    end
  end

  def test_explicit_empty_findings_array_is_a_clean_review
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      runner = ->(output_path:, **) { File.write(output_path, JSON.generate("findings" => [])) }
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      assert_empty reviewer.call([ feature ])
      assert_empty reviewer.review_errors
    end
  end

  def test_requires_exact_top_level_findings_envelope
    invalid_documents = [
      nil,
      [],
      {},
      { "findings" => nil },
      { "findings" => {} },
      { "findings" => [], "extra" => true }
    ]

    invalid_documents.each do |document|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        runner = ->(output_path:, **) { File.write(output_path, JSON.generate(document)) }
        reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

        assert_empty reviewer.call([ feature ]), document.inspect
        assert_equal "schema_invalid", reviewer.review_errors.first.fetch("error"), document.inspect
      end
    end
  end

  def test_one_invalid_finding_rejects_the_capped_batch_without_persisting_partial_results
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      invalid = qualified_finding(file: "app.rb", title: "Second")
      invalid.delete("root_cause")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [ qualified_finding(file: "app.rb"), invalid ]
        ))
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      assert_empty reviewer.call([ feature ])
      assert_equal "schema_invalid", reviewer.review_errors.first.fetch("error")
      assert_empty Dir[File.join(dir, ".hive-state", "patrol", "findings", "*.json")]
    end
  end

  def test_malformed_finding_inside_the_cap_records_schema_invalid
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [ qualified_finding(file: "app.rb"), nil ]
        ))
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      assert_empty reviewer.call([ feature ])
      assert_equal "schema_invalid", reviewer.review_errors.first.fetch("error")
      assert_empty Dir[File.join(dir, ".hive-state", "patrol", "findings", "*.json")]
    end
  end

  def test_items_after_the_configured_cap_are_ignored
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      limited = cfg
      limited["patrol"]["max_findings_per_feature"] = 1
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [ qualified_finding(file: "app.rb"), nil ]
        ))
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: limited, agent_runner: runner)

      assert_equal 1, reviewer.call([ feature ]).size
      assert_empty reviewer.review_errors
    end
  end

  def test_rejects_hallucinated_and_out_of_range_evidence_as_schema_invalid
    invalid_evidence = [
      { "file" => "app.rb", "line" => 1, "snippet" => "admin.destroy!", "role" => "root_cause" },
      { "file" => "app.rb", "line" => 2, "snippet" => "user.name", "role" => "root_cause" }
    ]

    invalid_evidence.each do |evidence|
      with_tmp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".hive-state"))
        File.write(File.join(dir, "app.rb"), "return user.name if user\n")
        payload = qualified_finding(file: "app.rb")
        payload["evidence"] = [ evidence ]
        runner = ->(output_path:, **) { File.write(output_path, JSON.generate("findings" => [ payload ])) }
        reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

        assert_empty reviewer.call([ feature ]), evidence.inspect
        assert_equal "schema_invalid", reviewer.review_errors.first.fetch("error"), evidence.inspect
      end
    end
  end

  def test_evidence_line_must_exist_within_bounded_source_content
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      prefix = "x" * Hive::Patrol::SourceReader::MAX_SOURCE_BYTES
      File.write(File.join(dir, "app.rb"), "#{prefix}\nuser.name\n")
      payload = qualified_finding(file: "app.rb")
      payload["evidence"] = [
        { "file" => "app.rb", "line" => 2, "snippet" => "user.name", "role" => "root_cause" }
      ]
      runner = ->(output_path:, **) { File.write(output_path, JSON.generate("findings" => [ payload ])) }
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      assert_empty reviewer.call([ feature ])
      assert_equal "schema_invalid", reviewer.review_errors.first.fetch("error")
    end
  end

  def test_oversized_agent_output_records_review_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      runner = lambda do |output_path:, **|
        File.binwrite(output_path, " " * (Hive::Patrol::Reviewer::MAX_OUTPUT_BYTES + 1))
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      assert_empty reviewer.call([ feature ])
      assert_equal "review_error", reviewer.review_errors.first.fetch("error")
      assert_includes reviewer.review_errors.first.fetch("message"), "exceeds"
    end
  end

  def test_symlinked_agent_output_records_review_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      target = File.join(dir, "agent-controlled.json")
      File.write(target, JSON.generate("findings" => []))
      runner = ->(output_path:, **) { File.symlink(target, output_path) }
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      assert_empty reviewer.call([ feature ])
      assert_equal "review_error", reviewer.review_errors.first.fetch("error")
    end
  end

  def test_missing_agent_output_records_review_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: ->(**) { {} })

      assert_empty reviewer.call([ feature ])
      assert_equal "review_error", reviewer.review_errors.first.fetch("error")
    end
  end

  def other_feature
    Hive::Patrol::Feature.new(
      id: "route-admin",
      kind: "route",
      entrypoints: [ "admin.rb" ],
      owned_files: [ "admin.rb" ],
      context_files: [],
      tests: []
    )
  end

  # One feature's agent failing (Agent#run! returns status :error and
  # writes no output) must not abort the whole scan. The other feature's
  # findings survive and the failure is recorded so the caller can refuse
  # to advance last_scanned_sha.
  def test_one_feature_agent_failure_is_non_fatal
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "admin.rb"), "user.name\n")
      runner = lambda do |feature:, output_path:, **|
        if feature.id == "route-users"
          {
            status: :error,
            error_message: "token cap reached",
            resource_exhaustion: { reason: "token_limit", limit: 50, observed: 53 }
          }
        else
          File.write(output_path, JSON.generate(
            "findings" => [ qualified_finding(file: "admin.rb") ]
          ))
        end
      end

      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)
      findings = reviewer.call([ feature, other_feature ])

      assert_equal 1, findings.size, "the healthy feature's findings must survive a sibling's agent failure"
      assert_match(/\Aroute-admin-\d{8}T\d{6}Z-[0-9a-f]{8}-1\z/, findings.first.id)
      assert_equal 1, reviewer.review_errors.size
      assert_equal "agent_failed", reviewer.review_errors.first["error"]
      assert_equal({ "reason" => "token_limit", "limit" => 50, "observed" => 53 },
                   reviewer.review_errors.first.dig("details", "resource_exhaustion"))
    end
  end

  # Agent#run! reports a timed-out reviewer via status :timeout (not
  # :error). The truncated run may still have written a plausible findings
  # file; it must be recorded as an agent failure, never parsed as success.
  def test_timed_out_review_agent_is_recorded_and_its_output_is_not_trusted
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      File.write(File.join(dir, "app.rb"), "user.name\n")
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [ qualified_finding(file: "app.rb") ]
        ))
        { status: :timeout }
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)

      findings = reviewer.call([ feature ])

      assert_empty findings, "output written by a timed-out reviewer must not be parsed as success"
      assert_equal 1, reviewer.review_errors.size
      assert_equal "agent_failed", reviewer.review_errors.first["error"]
      assert_includes reviewer.review_errors.first["message"], "timed out"
      assert_empty Dir[File.join(dir, ".hive-state", "patrol", "findings", "*.json")]
    end
  end

  def test_unexpected_review_error_is_recorded
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      reviewer = Hive::Patrol::Reviewer.new(
        dir,
        cfg: cfg,
        agent_runner: ->(**) { raise IOError, "boom" }
      )

      assert_empty reviewer.call([ feature ])
      assert_equal "review_error", reviewer.review_errors.first["error"]
    end
  end

  def test_run_agent_wrapper_constructs_agent
    with_tmp_dir do |dir|
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
      fake_agent = Object.new
      def fake_agent.run! = { status: :ok }
      captured = nil

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      profiles_singleton.define_method(:lookup) { |*| :profile }
      agent_singleton.define_method(:new) { |**kwargs| captured = kwargs; fake_agent }
      assert_equal({ status: :ok },
                   reviewer.send(:run_agent, prompt: "p",
                                             output_path: File.join(dir, "out.json"),
                                             run_dir: dir))
      assert_equal 50_000, captured.fetch(:max_tokens)
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_new
    end
  end

  def test_run_agent_wrapper_refuses_an_exhausted_patrol_budget
    with_tmp_dir do |dir|
      budget = Object.new
      budget.define_singleton_method(:acquire) do |stage:, minimum_tokens:|
        minimum_tokens >= 0 && stage != "patrol-review"
      end
      budget.define_singleton_method(:exhaustion_message) { "cycle exhausted" }
      budget.define_singleton_method(:resource_exhaustion) do
        { reason: "cycle_agent_spawn_limit", limit: 3, observed: 3 }
      end
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, token_budget: budget)
      profile = Struct.new(:name, :initial_context_tokens) do
        def require_cli_capability!(name)
          raise "unexpected capability #{name.inspect}" unless name == :patrol_review_context

          [ "--safe-mode", "--disable-slash-commands" ]
        end
      end.new(:claude, 20_000)

      result = with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        reviewer.send(
          :run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir
        )
      end

      assert_equal :error, result.fetch(:status)
      assert_equal "cycle exhausted", result.fetch(:error_message)
      assert_equal(
        { reason: "cycle_agent_spawn_limit", limit: 3, observed: 3 },
        result.fetch(:resource_exhaustion)
      )
    end
  end

  def test_run_agent_wrapper_records_patrol_review_usage
    with_tmp_dir do |dir|
      with_usage_db do
        cfg = self.cfg
        cfg["patrol"]["agent"] = "codex"
        reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
        fake_agent = Object.new
        def fake_agent.run!
          {
            status: :ok,
            model: "fallback-model",
            usage: { model: "usage-model", input: 123, output: 45, cached: 6 }
          }
        end

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        profile = Struct.new(:name).new("codex")
        profiles_singleton.define_method(:lookup) { |*| profile }
        agent_singleton.define_method(:new) { |*| fake_agent }

        reviewer.send(:run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)

        rows = usage_rows
        assert_equal 1, rows.size
        row = rows.first
        assert_equal "codex", row["agent"]
        assert_equal "usage-model", row["model"]
        assert_equal File.basename(dir), row["project_slug"]
        assert_equal "patrol-review", row["task_slug"]
        assert_equal "patrol-review", row["stage"]
        assert_equal 123, row["input"]
        assert_equal 45, row["output"]
        assert_equal 6, row["cached"]
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_run_agent_wrapper_without_usage_records_an_unmetered_launch
    with_tmp_dir do |dir|
      with_usage_db do
        reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
        fake_agent = Object.new
        def fake_agent.run! = { status: :ok }

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        profiles_singleton.define_method(:lookup) { |*| Struct.new(:name).new("claude") }
        agent_singleton.define_method(:new) { |*| fake_agent }

        reviewer.send(:run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)

        rows = usage_rows
        assert_equal 1, rows.size
        assert_equal "patrol-review-unmetered", rows.first.fetch("stage")
        assert_equal 0, rows.first.fetch("input")
        assert_equal 0, rows.first.fetch("output")
        assert_equal 0, rows.first.fetch("cached")
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_run_agent_wrapper_does_not_raise_when_usage_recording_fails
    with_tmp_dir do |dir|
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
      fake_agent = Object.new
      def fake_agent.run!
        { status: :ok, usage: { input: 1, output: 2, cached: 3 } }
      end

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      usage_singleton = class << Hive::UsageDb; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      usage_record = Hive::UsageDb.method(:record!)
      # A profile object WITHOUT #name exercises profile_name's config fallback.
      profiles_singleton.define_method(:lookup) { |*| Object.new }
      agent_singleton.define_method(:new) { |*| fake_agent }
      usage_singleton.define_method(:record!) { |**| raise "db locked" }

      result = nil
      _out, err = capture_io do
        result = reviewer.send(:run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)
      end

      assert_equal({ status: :ok, usage: { input: 1, output: 2, cached: 3 } }, result)
      assert_match(/usage record failed: db locked/, err)
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      usage_singleton.define_method(:record!, usage_record) if usage_singleton && usage_record
    end
  end
end
