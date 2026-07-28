require "test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "hive/agent_skills/canonical_skill"
require_relative "../../packaging/release_candidate/aggregate"

class ReleaseContractTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  RELEASE_WORKFLOW = File.join(ROOT, ".github/workflows/release.yml")
  CANDIDATE_WORKFLOW = File.join(ROOT, ".github/workflows/release-candidate.yml")
  LIVE_AGENT_WORKFLOW = File.join(ROOT, ".github/workflows/live-agent-skills.yml")
  RELEASE_SELECTOR = File.join(ROOT, "packaging/live_agent_skills/select_release_proof.rb")
  SETUP_NODE_ACTION = "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020"
  GITHUB_SCRIPT_ACTION = "actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3"
  CANDIDATE_SHA = "a" * 40
  WORKFLOW_SHA = "b" * 40
  ATTESTATION_SHA256 = "c" * 64

  def test_release_metadata_matches_runtime_version
    version = Regexp.escape(Hive::VERSION)

    assert_match(/^    hive-cli \(#{version}\)$/, read("Gemfile.lock"))
    assert_match(/^    hive-cli \(#{version}\)$/, read("web/Gemfile.lock"))
    assert_equal 1, read("CHANGELOG.md").scan(/^## #{version}$/).size
    assert_equal 1, read("README.md").scan(%r{/v#{version}/install\.sh}).size
    assert_equal 2, read("install.md").scan(%r{/v#{version}/install\.sh}).size
  end

  def test_public_credibility_copy_matches_current_capabilities
    readme = read("README.md")
    gemspec = read("hive.gemspec")
    faq = read("docs/faq.md")
    workflows = read("docs/workflows.md")

    assert_includes readme, "Hive is a durable, local-first workflow engine for AI agents."
    assert_includes gemspec, "Durable, local-first workflow engine for AI agents"
    assert_match(/coding,\s+content, benchmark, and owner-authored workflows/, gemspec)
    assert_includes faq, "hive web"
    refute_includes faq, "Why no built-in web UI?"
    refute_includes readme, "why no built-in web UI"

    assert_includes workflows, "built-in `coding`, `content`, and `bench` workflows"
    assert_includes workflows, "hive workflow install honeycomb/architecture --yes"
    assert_includes workflows, "/hive create a three-stage editorial workflow"
    assert_includes workflows, "hive workflow validate editorial --json"
    assert_includes workflows, "hive decide <task> approve --from approval --decision-id <decision-id>"
    assert_includes workflows, "The last stage may be `kind: terminal`, `kind: agent`, `kind: council`, or `kind: human`."
    assert_includes workflows, "No task is created by workflow creation alone."
    assert_includes readme, "natural language"

    %w[OpenClaw Grok hive-bench Honeycomb].each { |capability| assert_includes readme, capability }
    assert_includes readme, "### Hive web (default native experience)"
  end

  def test_discord_announcement_uses_supported_update_command
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    step = workflow.fetch("jobs").fetch("release-finalize").fetch("steps").find do |candidate|
      candidate["name"] == "Announce release on Discord"
    end

    refute_nil step
    assert_equal "${{ env.DISCORD_RELEASE_WEBHOOK != '' }}", step.fetch("if")
    assert_equal true, step.fetch("continue-on-error")
    assert_includes step.fetch("run"), "\\`hive update\\`"
    refute_includes step.fetch("run"), "gem install hive-cli"
  end

  def test_agent_skill_release_metadata_is_derived_from_authoritative_inputs
    canonical = Hive::AgentSkills::CanonicalSkill.new
    skill_text = File.read(File.join(ROOT, "openclaw/skills/hive/SKILL.md"))
    frontmatter = skill_text.match(/\A---\n(?<yaml>.*?)\n---\n/m)[:yaml]
    openclaw = YAML.safe_load(frontmatter, aliases: false)
    projection = JSON.parse(File.read(File.join(ROOT, "openclaw/skills/hive/.hive-skill.json")))
    setup = File.read(File.join(ROOT, "openclaw/skills/hive/references/setup-and-platforms.md"))
    publish_docs = read("openclaw/README.md")
    release_docs = read("docs/RELEASING.md")

    assert_equal canonical.version, openclaw.fetch("version")
    assert_equal canonical.version, projection.fetch("skill_version")
    assert_equal canonical.canonical_digest, projection.fetch("canonical_digest")
    assert_includes setup, "/v#{Hive::VERSION}/install.sh"
    refute_match(%r{/v(?!#{Regexp.escape(Hive::VERSION)}/)[0-9]+\.[0-9]+\.[0-9]+/install\.sh}, setup)
    assert_includes publish_docs, "skills/hive/skill.json"
    refute_match(/--version\s+\d+\.\d+\.\d+/, publish_docs)
    assert_includes release_docs, "hive-site #23116"
    assert_includes release_docs, "does not block this repository"
    assert_match(/Do\s+not describe current-main workflow-creator commands as stable/, release_docs)
  end

  def test_live_agent_proof_is_protected_exact_sha_and_four_surface
    body = File.read(LIVE_AGENT_WORKFLOW)
    workflow = YAML.safe_load_file(LIVE_AGENT_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    matrix = jobs.fetch("live-agent").dig("strategy", "matrix", "include")
    action_uses = jobs.values.flat_map do |job|
      [ job["uses"], *job.fetch("steps", []).filter_map { |step| step["uses"] } ]
    end.compact
    setup_node = jobs.fetch("live-agent").fetch("steps").find do |step|
      step["uses"] == SETUP_NODE_ACTION
    end

    assert_includes body, "workflow_dispatch:"
    assert_includes body, "candidate_sha:"
    assert_includes body, '[[ "$GITHUB_REF" == "refs/heads/main" ]]'
    assert_includes body, "git merge-base --is-ancestor"
    assert_equal({ "node-version" => "22" }, setup_node.fetch("with"))
    assert_includes body, "branches/main"
    assert_equal %w[claude codex openclaw pi], matrix.map { |row| row.fetch("platform") }.sort
    assert_equal "live-agent-skills-${{ matrix.platform }}", jobs.fetch("live-agent").fetch("environment")
    assert_equal false, jobs.fetch("live-agent").dig("strategy", "fail-fast")
    assert_equal [ "validate", "build", "live-agent", "live-workflow-creator" ],
                 jobs.fetch("attest").fetch("needs")
    assert_includes body, "retention-days: 7"
    assert_includes body, 'name: "live-agent-skills"'
    assert_includes body, "checks: write"
    assert_includes body, "attestation_sha256"
    assert_includes body, "HIVE_RELEASE_GATE: \"1\""
    refute_empty action_uses
    action_uses.each do |action|
      assert_match(/\A[^@]+@[0-9a-f]{40}\z/, action)
    end

    github_script_steps = jobs.values.flat_map { |job| job.fetch("steps", []) }.select do |step|
      step.fetch("uses", "").start_with?("actions/github-script@")
    end
    assert_equal [ GITHUB_SCRIPT_ACTION ], github_script_steps.map { |step| step.fetch("uses") }
    github_script = github_script_steps.fetch(0).dig("with", "script")
    refute_includes github_script, "require('@actions/github')"
    refute_match(/\b(?:const|let|var)\s+getOctokit\b/, github_script)

    live_step = jobs.fetch("live-agent").fetch("steps").find do |step|
      step["name"] == "Run authenticated structural proof"
    end
    refute_nil live_step
    assert_includes live_step.dig("env", "CODEX_API_KEY"), "matrix.platform == 'codex'"
    assert_includes live_step.dig("env", "ANTHROPIC_API_KEY"), "matrix.platform == 'claude'"
    assert_includes live_step.dig("env", "ANTHROPIC_API_KEY"), "matrix.platform == 'pi'"
    assert_includes live_step.dig("env", "OPENAI_API_KEY"), "matrix.platform == 'openclaw'"
    install_step = jobs.fetch("live-agent").fetch("steps").find do |step|
      step["name"] == "Install the native agent CLI in the ephemeral runner"
    end
    refute install_step.fetch("env").key?("CODEX_API_KEY")
    candidate_install_step = jobs.fetch("live-agent").fetch("steps").find do |step|
      step["name"] == "Install the exact candidate gem and test dependencies"
    end
    candidate_install_body = candidate_install_step.fetch("run")
    assert_includes candidate_install_body, "install_candidate_gem.sh"
    assert_includes candidate_install_body, '"$RUNNER_TEMP/proven-gems/bin/hive" --version'
    refute_includes candidate_install_body, 'gem install "$gem_file"'

    creator = jobs.fetch("live-workflow-creator")
    assert_equal [ "validate", "build" ], creator.fetch("needs")
    assert_equal "live-agent-skills-openclaw", creator.fetch("environment")
    creator_steps = creator.fetch("steps").select do |step|
      step["name"].to_s.start_with?("Run authenticated workflow-creator proof with")
    end
    assert_equal 2, creator_steps.length
    assert_equal(
      [
        "${{ secrets.OPENAI_API_KEY }}",
        "${{ secrets.OPENROUTER_API_KEY }}"
      ],
      creator_steps.map { |step| step.dig("env", "HIVE_LIVE_PROVIDER_CREDENTIAL") }
    )
    assert creator_steps.all? { |step|
      step.fetch("if").include?("startsWith(vars.HIVE_LIVE_MODEL")
    }
    assert creator_steps.all? { |step|
      (step.fetch("env").keys & %w[OPENAI_API_KEY OPENROUTER_API_KEY]).empty?
    }
    assert creator_steps.all? { |step|
      step.fetch("run").include?("live_hive_workflow_creator_smoke_test.rb")
    }
    creator_actions = creator.fetch("steps").filter_map { |step| step["uses"] }
    assert creator_actions.all? { |action| action.match?(/@[0-9a-f]{40}\z/) }
    openclaw_install = creator.fetch("steps").find do |step|
      step["name"] == "Install OpenClaw in the ephemeral runner"
    end
    refute_nil openclaw_install
    assert_equal %w[OPENCLAW_INTEGRITY OPENCLAW_VERSION],
                 openclaw_install.fetch("env").keys.sort
    refute_match(/\$\{\{\s*secrets\./, JSON.generate(openclaw_install))
    install_body = openclaw_install.fetch("run")
    assert_includes(
      install_body,
      'npm pack "openclaw@${OPENCLAW_VERSION}" --json --pack-destination "$pack_dir"'
    )
    assert_includes install_body, "JSON.parse"
    %w[entry.version entry.integrity entry.filename].each do |metadata_field|
      assert_includes install_body, metadata_field
    end
    assert_includes install_body, 'createHash("sha512")'
    assert_includes install_body, "readFileSync(process.argv[1])"
    assert_includes install_body, '"sha512-"'
    assert_includes install_body, '[[ "$packed_version" == "$OPENCLAW_VERSION" ]]'
    assert_includes install_body, '[[ "$reported_integrity" == "$OPENCLAW_INTEGRITY" ]]'
    assert_includes install_body, '[[ "$computed_integrity" == "$OPENCLAW_INTEGRITY" ]]'
    assert_includes install_body, '[[ "$computed_integrity" == "$reported_integrity" ]]'
    assert_includes install_body, 'npm install --global "$tarball"'
    refute_includes install_body, "npm view"
    refute_match(/npm install\s+--global\s+["']?openclaw@/, install_body)
    assert_operator(
      install_body.index('[[ "$computed_integrity" == "$OPENCLAW_INTEGRITY" ]]'),
      :<,
      install_body.index('npm install --global "$tarball"')
    )
    creator_body = creator.fetch("steps").filter_map { |step| step["run"] }.join("\n")
    assert_includes body,
                    "sha512-KYPBQnAfEb/9qrxlw/96a90mMQeKdAZdUABMROOue9Ph2oFbnDGezZjd5Bmw4WhRyzgyvHOHqHje/swGipC4xA=="
    assert_includes creator_body, 'package_json="$(npm root --global)/openclaw/package.json"'
    assert_includes creator_body,
                    'node -p "require(process.argv[1]).version" "$package_json"'
    assert_includes creator_body,
                    'openclaw_version_regex="${OPENCLAW_VERSION//./\\\\.}"'
    assert_includes creator_body,
                    '^OpenClaw[[:space:]]${openclaw_version_regex}[[:space:]]\\\\(.+\\\\)$'
    assert_includes creator_body,
                    "HIVE_OPENCLAW_PACKAGE_VERSION=$OPENCLAW_VERSION"
    assert_includes creator_body,
                    "HIVE_OPENCLAW_PACKAGE_INTEGRITY=$computed_integrity"
    assert_includes creator_body, "HIVE_PROVEN_HIVE_BIN=$RUNNER_TEMP/proven-gems/bin/hive"
    assert_includes body, "workflow-creator-evidence-openclaw"
    assert_includes body, "creator-evidence"
  end

  def test_tag_release_selects_and_reverifies_exact_pre_tag_candidate
    body = File.read(RELEASE_WORKFLOW)
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    selector = jobs.fetch("select-candidate")
    selector_body = selector.fetch("steps").filter_map { |step| step["run"] }.join("\n")

    assert_equal({}, workflow.fetch("permissions"))
    assert_equal "select-candidate", jobs.fetch("install-gate").fetch("needs")
    assert_equal [ "select-candidate", "install-gate" ],
                 jobs.fetch("release-finalize").fetch("needs")
    assert_includes selector_body, 'candidate_sha="$(git rev-parse "${GITHUB_REF}^{commit}")"'
    assert_includes selector_body, "commits/${candidate_sha}/check-runs?per_page=100"
    assert_includes selector_body, "select_release_candidate.rb select"
    assert_includes selector_body, "select_release_candidate.rb verify"
    assert_includes selector_body, "select_release_candidate.rb digest"
    assert_includes selector_body, "select_release_candidate.rb extract"
    assert_includes selector_body, "select_release_candidate.rb action-lock"
    assert_includes selector_body, "select_release_candidate.rb candidate"
    assert_includes body, "select_release_candidate.rb publication"
    assert_includes selector_body, "artifact.producer_run_id"
    assert_includes selector_body, "ordinary_ci.run_id"
    assert_includes selector_body,
                    'git merge-base --is-ancestor "$workflow_sha" refs/remotes/origin/main'
    assert_includes selector_body, "install_candidate_gem.sh"
    assert_includes selector_body, "verify-managed-web-setup.sh"
    assert_includes selector_body, ".public_files | [.gem, .skills, .web]"
    %w[gem\ build git\ archive managed_web_archive.rb live_agent_skills/build.rb].each do |build|
      refute_includes body, build
    end
    refute_includes body, "OPENAI_API_KEY"
    refute_includes body, "ANTHROPIC_API_KEY"
    refute_includes body, "CODEX_API_KEY"
    assert_includes body, "hive-selected-candidate-${{ github.run_id }}"
    assert_equal "Select and verify trusted pre-tag candidate", selector.fetch("name")
  end

  def test_candidate_workflow_is_exact_sha_pinned_and_code_free_at_aggregation
    body = File.read(CANDIDATE_WORKFLOW)
    workflow = YAML.safe_load_file(CANDIDATE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    aggregate = jobs.fetch("aggregate")

    assert_includes body, "workflow_dispatch:"
    assert_includes body, "candidate_sha:"
    assert_includes body, "request_id:"
    assert_includes body, "run-name: hive-release-candidate:"
    assert_equal({}, workflow.fetch("permissions"))
    assert_equal false, workflow.dig("concurrency", "cancel-in-progress")
    assert_includes workflow.dig("concurrency", "group"), "inputs.candidate_sha"
    assert_operator body.scan("retention-days: 30").size, :>=, 2
    assert_includes body, "git merge-base --is-ancestor"
    assert_includes body, "branches/main"
    assert_includes body, "action_lock_sha256"
    assert_includes body, "source_run_id"
    assert_includes body, "source_run_attempt"
    assert_includes body, "source_artifact_id"
    assert_includes body, "source_artifact_digest"
    assert_includes body, "packaging/release_candidate/hosted_upgrade_lane.rb"
    assert_includes body, "$HIVE_RC_RUN_ROOT/candidate/manifest.json"
    assert_includes body, "/run/sandbox-attestation.json"
    assert_includes body, "/run/baseline-cache-attestation.json"
    assert_includes body, "/run/targets/"

    external_uses = body.scan(/^\s*(?:-\s*)?uses:\s+([^@\s]+)@([^#\s]+)/).reject do |action, _revision|
      action.start_with?("./")
    end
    refute_empty external_uses
    external_uses.each do |action, revision|
      assert_match(/\A[0-9a-f]{40}\z/, revision, "#{action} must be full-SHA pinned")
    end
    jobs.each_value do |job|
      Array(job["steps"]).select { |step| step["uses"].to_s.start_with?("actions/checkout@") }.each do |step|
        assert_equal false, step.dig("with", "persist-credentials")
      end
    end

    assert_equal({ "actions" => "read", "checks" => "write" }, aggregate.fetch("permissions"))
    aggregate_body = JSON.generate(aggregate)
    refute_includes aggregate_body, "actions/checkout"
    refute_includes aggregate_body, "packaging/release_candidate"
    refute_includes aggregate_body, "candidate/manifest.json"
    jobs.reject { |name, _job| name == "aggregate" }.each do |name, job|
      refute_equal "write", job.dig("permissions", "checks"), name
    end

    %w[OPENAI_API_KEY ANTHROPIC_API_KEY CODEX_API_KEY CLAUDE_API_KEY].each do |secret|
      refute_includes body, secret
    end
    refute_match(/\b(?:git tag|gh release create|gem push|docker push)\b/, body)
    verifier = read("packaging/release_candidate/verify_hosted_gate.sh")
    assert_includes verifier, "candidate-controlled harness drift"
    assert_includes body, ".trusted-control/packaging/release_candidate/verify_hosted_gate.sh"
    assert_includes body, "--cap-drop=ALL"
    assert_includes body, "--security-opt=no-new-privileges"
    assert_includes body, "--network=none"
    assert_match(/ruby@sha256:[0-9a-f]{64}/, body)
    refute_includes body, "sudo unshare"
  end

  def test_candidate_version_gate_reads_the_reviewed_catalog
    body = File.read(CANDIDATE_WORKFLOW)
    workflow = YAML.safe_load_file(CANDIDATE_WORKFLOW, aliases: true)
    job = workflow.fetch("jobs").fetch("candidate-version")
    command = job.fetch("steps").last.fetch("run")

    assert_includes command, "BaselineCatalog.load"
    assert_includes command, "latest_stable.version"
    assert_includes command, "BASELINE_VERSION"
    refute_match(/Gem::Version\.new\(\"0\.6\.9\"\)/, command)
    assert_includes body, "trusted_control=\"$RUNNER_TEMP/trusted-control\""
    assert_includes body,
                    '-r"$trusted_control/packaging/release_candidate/aggregate"'
  end

  def test_candidate_workflow_declares_the_closed_required_job_registry
    workflow = YAML.safe_load_file(CANDIDATE_WORKFLOW, aliases: true)
    names = workflow.fetch("jobs").values.flat_map do |job|
      [
        job.fetch("name"),
        *Array(job.dig("strategy", "matrix", "include")).filter_map { |row| row["job_name"] }
      ]
    end

    HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.each do |required|
      assert_includes names, required
    end
    assert_includes names, "Protected ordinary CI"
    assert_includes names, "Trusted release candidate aggregate"
  end

  def test_candidate_retry_executes_only_selected_receipted_replacements
    body = File.read(CANDIDATE_WORKFLOW)
    workflow = YAML.safe_load_file(CANDIDATE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")

    assert_includes body, "selected_gates"
    assert_includes body, "RetrySelection"
    assert_includes body, "source_evidence_sha256"
    assert_includes body, "source_artifact_run_id"
    assert_includes body, "source_artifact_run_attempt"
    assert_includes body, "source_artifact_name"
    assert_includes body, '.external_id == ("hive-release-candidate:v1:"'
    assert_includes body, "display_title"
    refute_includes body, "|| true"

    %w[catalog release-e2e package managed-web freshness candidate-version].each do |job_name|
      job = jobs.fetch(job_name)
      assert_includes job.fetch("if"), "selected_gates"
      assert_gate_receipt_precedes_execution(job, job_name)
    end
    %w[native upgrade].each do |job_name|
      job = jobs.fetch(job_name)
      executable = job.fetch("steps").reject do |step|
        step["name"].to_s.start_with?("Retain ")
      end
      executable.each do |step|
        assert_includes step.fetch("if"), "matrix.job_name", "#{job_name}: #{step["name"] || step["uses"]}"
      end
      assert_gate_receipt_precedes_execution(job, job_name)
    end

    validate_permissions = jobs.fetch("validate").fetch("permissions")
    assert_equal "read", validate_permissions.fetch("actions")
    assert_equal "read", validate_permissions.fetch("checks")
    aggregate_body = jobs.fetch("aggregate").fetch("steps").last.fetch("run")
    assert_includes aggregate_body, "conclusion=failure"
    assert_includes aggregate_body, "if test \"$qa_status\" = qa_ready"
    assert_includes aggregate_body, "external_id"
  end

  def test_release_publication_graph_waits_for_exact_selected_bytes
    workflow = YAML.safe_load_file(RELEASE_WORKFLOW, aliases: true)
    jobs = workflow.fetch("jobs")
    selector = jobs.fetch("select-candidate")
    install = jobs.fetch("install-gate")
    finalize = jobs.fetch("release-finalize")

    assert_nil selector["needs"]
    assert_equal "select-candidate", install.fetch("needs")
    assert_equal [ "select-candidate", "install-gate" ], finalize.fetch("needs")

    finalize_body = finalize.fetch("steps").filter_map { |step| step["run"] }.join("\n")
    assert_includes finalize_body, "select_release_candidate.rb publication"
    assert_includes finalize_body, "selected/dist/SHA256SUMS"
    assert_includes finalize_body, 'gh release create "$REF_NAME" selected/dist/*'
    refute_match(/\b(?:gem build|git archive)\b/, finalize_body)
  end

  def test_release_and_candidate_workflows_pin_actions_and_disable_checkout_credentials
    [ RELEASE_WORKFLOW, CANDIDATE_WORKFLOW ].each do |path|
      body = File.read(path)
      external = body.scan(/^\s*(?:-\s*)?uses:\s+([^@\s]+)@([^#\s]+)/).reject do |action, _revision|
        action.start_with?("./")
      end
      refute_empty external
      external.each do |action, revision|
        assert_match(/\A[0-9a-f]{40}\z/, revision, "#{action} in #{path}")
      end
      workflow = YAML.safe_load_file(path, aliases: true)
      workflow.fetch("jobs").each_value do |job|
        Array(job["steps"]).select do |step|
          step["uses"].to_s.start_with?("actions/checkout@")
        end.each do |step|
          assert_equal false, step.dig("with", "persist-credentials")
        end
      end
    end
  end

  def test_release_selector_executes_the_trusted_exact_sha_fixture_contract
    with_release_selector_fixture do |paths|
      out, err, status = run_release_selector("select", *paths.values_at(:checks, :run, :jobs, :artifacts))

      assert status.success?, err
      selection = JSON.parse(out)
      assert_equal CANDIDATE_SHA, selection.fetch("candidate_sha")
      assert_equal WORKFLOW_SHA, selection.fetch("workflow_revision")
      assert_equal 42, selection.fetch("proof_run_id")
      assert_equal 2, selection.fetch("proof_run_attempt")
      assert_equal 77, selection.fetch("proof_artifact_id")
      assert_equal "sha256:#{'d' * 64}", selection.fetch("proof_artifact_digest")
      assert_equal ATTESTATION_SHA256, selection.fetch("attestation_sha256")
    end
  end

  def test_release_selector_rejects_untrusted_or_incomplete_fixtures
    cases = {
      "candidate SHA" => ->(fixture) { fixture.fetch(:checks).fetch("check_runs").first["head_sha"] = "e" * 40 },
      "GitHub Actions app" => ->(fixture) { fixture.fetch(:checks).fetch("check_runs").first["app"]["slug"] = "other" },
      "run attempt" => ->(fixture) { fixture.fetch(:run)["run_attempt"] = 3 },
      "required proof job" => ->(fixture) { fixture.fetch(:jobs).fetch("jobs").shift },
      "nonexpired artifact" => ->(fixture) { fixture.fetch(:artifacts).fetch("artifacts").first["expired"] = true },
      "unique artifact" => lambda { |fixture|
        fixture.fetch(:artifacts).fetch("artifacts") << fixture.fetch(:artifacts).fetch("artifacts").first.dup
      },
      "trusted digest" => ->(fixture) { fixture.fetch(:artifacts).fetch("artifacts").first["digest"] = "sha256:short" }
    }

    cases.each do |label, mutate|
      with_release_selector_fixture(mutate: mutate) do |paths|
        _out, err, status = run_release_selector(
          "select", *paths.values_at(:checks, :run, :jobs, :artifacts)
        )
        refute status.success?, "#{label} fixture should fail"
        refute_empty err
      end
    end
  end

  def test_release_selector_executes_downloaded_archive_digest_verification
    with_tmp_dir do |dir|
      archive = File.join(dir, "proof.zip")
      File.write(archive, "proof archive bytes")
      digest = "sha256:#{Digest::SHA256.file(archive).hexdigest}"

      _out, err, status = run_release_selector("digest", digest, archive, include_identity: false)
      assert status.success?, err

      _out, err, status = run_release_selector(
        "digest", "sha256:#{'0' * 64}", archive, include_identity: false
      )
      refute status.success?
      assert_includes err, "digest does not match"
    end
  end

  def test_signed_checksum_manifest_covers_the_managed_web_bundle
    workflow = read(".github/workflows/release.yml")

    assert_match(
      /sha256sum hive-cli-\*\.gem hive-agent-skills-\*\.tar\.gz hive-web-\*\.tar\.gz > SHA256SUMS/,
      workflow
    )
    assert_includes workflow, ".public_files | [.gem, .skills, .web]"
    assert_includes workflow,
                    '--certificate-identity-regexp "^https://github\\.com/ivankuznetsov/hive/' \
                    '\\.github/workflows/release\\.yml@refs/tags/${REF_NAME}$"'
  end

  private

  def assert_gate_receipt_precedes_execution(job, label)
    steps = job.fetch("steps")
    verify_index = steps.index { |step| step["name"].to_s.start_with?("Attest exact producer") }
    upload_index = steps.index { |step| step["name"].to_s.start_with?("Retain ") }
    refute_nil verify_index, label
    refute_nil upload_index, label
    assert_operator verify_index, :<, upload_index, label
    later_run = steps[(upload_index + 1)..].any? { |step| step["run"] }
    assert later_run, "#{label} must upload its immutable receipt before gate execution"
  end

  def read(path)
    File.read(File.join(ROOT, path))
  end

  def run_release_selector(command, *paths, include_identity: true)
    argv = [ RbConfig.ruby, RELEASE_SELECTOR, command ]
    argv.concat([ CANDIDATE_SHA, "ivankuznetsov/hive" ]) if include_identity
    Open3.capture3(*argv, *paths)
  end

  def with_release_selector_fixture(mutate: nil)
    fixture = release_selector_fixture
    mutate&.call(fixture)
    with_tmp_dir do |dir|
      paths = fixture.to_h do |name, payload|
        path = File.join(dir, "#{name}.json")
        File.write(path, JSON.generate(payload))
        [ name, path ]
      end
      yield paths
    end
  end

  def release_selector_fixture
    external_id = "live-agent-skills:v1:42:2:#{ATTESTATION_SHA256}"
    required_jobs = [
      "OpenClaw live Hive operating skill",
      "Claude live Hive operating skill",
      "Codex live Hive operating skill",
      "Pi live Hive operating skill",
      "Attest exact-SHA live agent proof"
    ]
    {
      checks: {
        "check_runs" => [ {
          "name" => "live-agent-skills", "head_sha" => CANDIDATE_SHA,
          "status" => "completed", "conclusion" => "success",
          "app" => { "slug" => "github-actions" },
          "completed_at" => "2026-07-20T12:00:00Z", "external_id" => external_id,
          "details_url" => "https://github.com/ivankuznetsov/hive/actions/runs/42"
        } ]
      },
      run: {
        "id" => 42, "run_attempt" => 2, "head_sha" => WORKFLOW_SHA,
        "path" => ".github/workflows/live-agent-skills.yml",
        "event" => "workflow_dispatch", "head_branch" => "main",
        "status" => "completed", "conclusion" => "success",
        "head_repository" => { "full_name" => "ivankuznetsov/hive" }
      },
      jobs: {
        "jobs" => required_jobs.map do |name|
          {
            "name" => name, "status" => "completed", "conclusion" => "success",
            "run_id" => 42, "run_attempt" => 2
          }
        end
      },
      artifacts: {
        "artifacts" => [ {
          "id" => 77, "name" => "live-agent-skills-proof-2", "expired" => false,
          "digest" => "sha256:#{'d' * 64}",
          "workflow_run" => { "id" => 42, "head_sha" => WORKFLOW_SHA }
        } ]
      }
    }
  end
end
