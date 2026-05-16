require "test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
require "hive/diagnosis_agent"
require "hive/markers"
require "hive/task_action"

# Pins the load-bearing invariants for Hive::DiagnosisAgent:
#   * no marker writes (no :agent_working pre-spawn, no terminal marker)
#   * no task-lock claim (compatible with a concurrent `hive run`)
#   * ADR-019 per-spawn <user_supplied_<nonce>> wrap around every
#     disk-derived value interpolated into the prompt
#   * SecretPatterns redaction over prompt interpolations AND over the
#     written artifact body, but NOT over the YAML frontmatter
#   * write-time freshness gate: marker rotation mid-spawn aborts the
#     artifact write instead of describing the stale state
#   * marker_signature wire-compatible with TaskAction (canonical impl)
class DiagnosisAgentTest < Minitest::Test
  FakeTask = Struct.new(
    :slug, :stage_name, :stage_index, :folder, :state_file,
    :project_root, :worktree_path,
    keyword_init: true
  )

  def setup
    @tmp = Dir.mktmpdir("hive-diagnosis-agent")
    @project_root = File.join(@tmp, "project")
    @slug = "red-task-260516-aaaa"
    @folder = File.join(@project_root, ".hive-state", "stages", "6-review", @slug)
    FileUtils.mkdir_p(@folder)
    @state_file = File.join(@folder, "task.md")
    File.write(@state_file, "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
    @task = FakeTask.new(
      slug: @slug, stage_name: "review", stage_index: 6,
      folder: @folder, state_file: @state_file,
      project_root: @project_root,
      worktree_path: nil
    )
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # `spawn:` injection captures the prompt the agent would have received
  # so the assertions can inspect the wrap shape + redaction without
  # actually exec-ing claude/codex.
  def spy_spawn(return_value: "agent body", capture_to: [])
    lambda do |profile:, prompt:, cwd:, add_dirs:, timeout_sec:, max_budget_usd:|
      capture_to << {
        profile: profile, prompt: prompt, cwd: cwd, add_dirs: add_dirs,
        timeout_sec: timeout_sec, max_budget_usd: max_budget_usd
      }
      return_value
    end
  end

  def test_does_not_write_markers_or_claim_task_lock
    capture = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: capture)).run!

    refute File.exist?(File.join(@folder, ".lock")),
           "DiagnosisAgent must not write a .lock file (no task-lock claim)"
    state_body = File.read(@state_file)
    refute_includes state_body, "<!-- AGENT_WORKING",
                    "DiagnosisAgent must not write :agent_working marker"
    refute_includes state_body, "<!-- COMPLETE",
                    "DiagnosisAgent must not write terminal markers"
  end

  def test_writes_artifact_at_fixed_path
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!

    path = File.join(@folder, "diagnostics", "red-status.md")
    assert File.exist?(path), "expected artifact at #{path}"
    body = File.read(path)
    assert_match(/\A---\n/, body, "artifact must begin with YAML frontmatter")
    assert_match(/^# Red Status Diagnosis$/, body)
  end

  def test_prompt_wraps_user_supplied_content_in_per_spawn_nonce
    capture = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: capture)).run!

    prompt = capture.first[:prompt]
    assert_match(/<user_supplied_[0-9a-f]{16}>/, prompt,
                 "ADR-019 nonce wrap must surround interpolated content")
    nonce = prompt.match(/<(user_supplied_[0-9a-f]{16})>/)[1]
    assert_includes prompt, "<#{nonce}>"
    assert_includes prompt, "</#{nonce}>"
    # Slug, marker name, and marker attrs all wrapped in the same nonce.
    assert_match(/<#{Regexp.escape(nonce)}>#{Regexp.escape(@slug)}<\/#{Regexp.escape(nonce)}>/, prompt)
    assert_match(/<#{Regexp.escape(nonce)}>review_error<\/#{Regexp.escape(nonce)}>/, prompt)
  end

  def test_each_spawn_uses_a_fresh_nonce
    first = []
    second = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: first)).run!
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: second)).run!

    first_nonce = first.first[:prompt].match(/<(user_supplied_[0-9a-f]+)>/)[1]
    second_nonce = second.first[:prompt].match(/<(user_supplied_[0-9a-f]+)>/)[1]
    refute_equal first_nonce, second_nonce,
                 "consecutive DiagnosisAgent runs must mint distinct ADR-019 nonces"
  end

  def test_marker_attrs_with_secret_values_are_redacted_in_prompt
    token = "ghp_#{'a' * 40}"
    File.write(@state_file, "<!-- REVIEW_ERROR reason=\"creds leaked #{token}\" -->\n")
    capture = []
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(capture_to: capture)).run!

    prompt = capture.first[:prompt]
    refute_includes prompt, token,
                    "SecretPatterns must scrub credentials before they leave the host"
    assert_includes prompt, "[REDACTED:github_token]"
  end

  def test_artifact_body_is_redacted_but_frontmatter_is_not
    token = "ghp_#{'a' * 40}"
    body = "Agent reports: #{token} leaked in logs"
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn(return_value: body)).run!

    artifact = File.read(File.join(@folder, "diagnostics", "red-status.md"))
    frontmatter = artifact.split("---", 3)[1]
    body_part = artifact.split("---", 3)[2]

    refute_includes frontmatter, "[REDACTED",
                    "frontmatter must not be processed by SecretPatterns (would corrupt YAML)"
    assert_match(/marker_signature: [0-9a-f]{64}/, frontmatter)
    assert_includes body_part, "[REDACTED:github_token]"
    refute_includes body_part, token
  end

  def test_artifact_frontmatter_carries_canonical_marker_signature
    Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!

    frontmatter = YAML.safe_load(
      File.read(File.join(@folder, "diagnostics", "red-status.md")).split("---")[1],
      permitted_classes: [ Time ]
    )
    # Reproduce TaskAction#marker_signature for the same (marker, attrs)
    # pair. Producer + consumer must agree byte-for-byte.
    expected = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
    assert_equal expected, frontmatter["marker_signature"]
  end

  def test_marker_rotation_during_spawn_aborts_write_with_stale_marker
    rotating_spawn = lambda do |**_args|
      # Simulate a concurrent `hive run` writing a new marker between
      # DiagnosisAgent#run!'s pre-spawn read and post-spawn freshness
      # check. The freshness gate must refuse the write so we never
      # produce an artifact that describes a state the task is no
      # longer in.
      File.write(@state_file, "<!-- REVIEW_ERROR phase=fix pass=2 -->\n")
      "agent body"
    end

    assert_raises(Hive::DiagnosisAgent::StaleMarker) do
      Hive::DiagnosisAgent.new(task: @task, spawn: rotating_spawn).run!
    end

    refute File.exist?(File.join(@folder, "diagnostics", "red-status.md")),
           "stale-marker abort must NOT leave an artifact behind"
  end

  def test_missing_execute_agent_config_surfaces_actionable_error
    # An unknown agent profile is rejected by AgentProfiles.lookup with
    # Hive::ConfigError → exit 78. DiagnosisAgent must propagate that
    # without writing a partial artifact.
    FileUtils.mkdir_p(File.dirname(@state_file).then { |d| File.join(@project_root, ".hive-state") })
    File.write(
      File.join(@project_root, ".hive-state", "config.yml"),
      YAML.dump("execute" => { "agent" => "no-such-agent" })
    )

    assert_raises(Hive::ConfigError) do
      Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
    end
  end
end
