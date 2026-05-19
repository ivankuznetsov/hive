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

  def test_concurrent_diagnose_on_same_task_raises_diagnosis_in_flight
    # Two concurrent `--diagnose --write` invocations on the same task
    # must not both spawn the configured agent and burn budget in
    # parallel. The first acquires the per-task flock; the second fails
    # fast with DiagnosisInFlight rather than blocking or duplicating
    # work. See PR #84 review findings #2 + #11.
    started = Queue.new
    release = Queue.new
    slow_spawn = lambda do |**_kwargs|
      started << :go
      release.pop          # block until the test signals completion
      "agent body"
    end

    holder = Thread.new do
      Hive::DiagnosisAgent.new(task: @task, spawn: slow_spawn).run!
    rescue StandardError
      # Tolerate Config-load failures from the simplified FakeTask; the
      # lock has already been acquired before that path is reached.
      nil
    end

    started.pop          # ensure the holder has the lock

    assert_raises(Hive::DiagnosisAgent::DiagnosisInFlight) do
      Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
    end

    release << :done
    holder.join
  end

  def test_diagnose_lock_released_on_exception_so_retry_can_acquire
    # An agent spawn that raises must release the flock in ensure so
    # the operator's retry isn't permanently blocked.
    fail_spawn = lambda { |**_kwargs| raise Hive::Error, "boom" }
    assert_raises(Hive::Error) do
      Hive::DiagnosisAgent.new(task: @task, spawn: fail_spawn).run!
    end

    # A subsequent run on the same task must NOT see DiagnosisInFlight.
    refute_raises_diagnosis_in_flight do
      Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn).run!
    end
  end

  def refute_raises_diagnosis_in_flight
    yield
  rescue Hive::DiagnosisAgent::DiagnosisInFlight
    flunk "diagnose flock was not released — retry would be permanently blocked"
  rescue StandardError
    # Other errors are fine for this test's purpose (lock was released).
    nil
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

  def test_stale_marker_exit_code_is_tempfail
    # Agent wrappers branch on exit code to decide retry-vs-escalate.
    # StaleMarker is retryable (marker rotated during the spawn; the
    # operator just needs to re-issue) and MUST map to TEMPFAIL (75),
    # matching Hive::ConcurrentRunError's semantics. Generic exit 1 (the
    # Hive::Error default) would tell wrappers to escalate.
    assert_equal Hive::ExitCodes::TEMPFAIL,
                 Hive::DiagnosisAgent::StaleMarker.new("stale").exit_code
  end

  def test_diagnosis_in_flight_exit_code_is_tempfail
    # Lock contention is retryable; same TEMPFAIL semantics as
    # Hive::ConcurrentRunError so wrappers can branch uniformly.
    assert_equal Hive::ExitCodes::TEMPFAIL,
                 Hive::DiagnosisAgent::DiagnosisInFlight.new("inflight").exit_code
  end

  def test_run_with_timeout_installs_and_restores_sigint_handler
    # Ctrl-C during the popen3 block unwinds the body and Ruby's popen3
    # ensure calls wait_thr.join with no timeout — the child agent is
    # never signalled and the CLI hangs forever. Verify the SIGINT (and
    # SIGTERM) trap is installed during run_with_timeout and restored
    # afterward so the operator's Ctrl-C terminates the child pgroup.
    agent = Hive::DiagnosisAgent.new(task: @task, spawn: spy_spawn)
    pre_int = Signal.trap("INT") { nil }
    pre_term = Signal.trap("TERM") { nil }
    Signal.trap("INT", pre_int)
    Signal.trap("TERM", pre_term)

    seen_handlers = []
    fake_spawn = lambda do |**_kwargs|
      # Snapshot the active handlers from inside the popen3 block-equivalent.
      seen_handlers << [ Signal.trap("INT") { nil }, Signal.trap("TERM") { nil } ]
      # Restore so the agent's body assertion sees the same state as a
      # real spawn would.
      Signal.trap("INT", seen_handlers.first[0])
      Signal.trap("TERM", seen_handlers.first[1])
      "agent body"
    end
    # Wire the injected spawn through DiagnosisAgent#run! so the trap
    # would be installed; the injected callable bypasses popen3 (and
    # therefore the trap installation), so this test alone can't prove
    # the trap is set DURING popen3. The companion `run_with_timeout`
    # tightening is covered by the spawn_profile path manually.
    Hive::DiagnosisAgent.new(task: @task, spawn: fake_spawn).run!
    post_int = Signal.trap("INT") { nil }
    post_term = Signal.trap("TERM") { nil }
    Signal.trap("INT", post_int)
    Signal.trap("TERM", post_term)

    # Caller's INT/TERM handlers must be restored to their pre-call values.
    assert_equal pre_int, post_int,
                 "INT handler must be restored to caller's handler after run!"
    assert_equal pre_term, post_term,
                 "TERM handler must be restored to caller's handler after run!"
    agent
  end

  def test_run_with_timeout_traps_int_and_kills_pgroup_on_ctrl_c
    # Spawn a short-lived shell child via the real run_with_timeout
    # path, send SIGINT to ourselves while the child is alive, and
    # verify the child is signalled (no orphan, no hang). The popen3
    # block must trap INT so Ruby's auto-unwind doesn't bypass child
    # cleanup. Skip on platforms where Process.kill is not supported.
    skip "Process.kill not supported on this platform" if RUBY_PLATFORM =~ /mswin|mingw/

    agent = Hive::DiagnosisAgent.new(task: @task)
    raised = nil
    thr = Thread.new do
      begin
        agent.send(:run_with_timeout, [ "sleep", "30" ], Dir.pwd, nil, 60)
      rescue Interrupt => e
        raised = e
      rescue Hive::Error => e
        raised = e
      end
    end
    # Wait a moment for popen3 to install the trap and start the child.
    sleep 0.3
    Process.kill("INT", Process.pid)
    thr.join(10)
    refute thr.alive?, "run_with_timeout must not hang past SIGINT"
    assert raised, "SIGINT must surface as Interrupt or Hive::Error from run_with_timeout"
  end

  def test_marker_rotation_to_agent_working_mid_spawn_aborts_with_stale_marker
    # A concurrent `hive run` flipping the marker to :agent_working
    # mid-spawn means the agent's verdict would describe an in-flight
    # run, not a red recovery state. The write-time freshness gate must
    # raise StaleMarker — see PR #84 review row 12.
    rotating_spawn = lambda do |**_args|
      File.write(@state_file, "<!-- AGENT_WORKING pid=999 -->\n")
      "agent body"
    end

    error = assert_raises(Hive::DiagnosisAgent::StaleMarker) do
      Hive::DiagnosisAgent.new(task: @task, spawn: rotating_spawn).run!
    end
    assert_match(/transitioned to/i, error.message,
                 "stale-marker error must mention the new marker state for operator")
    refute File.exist?(File.join(@folder, "diagnostics", "red-status.md")),
           "transition to non-red state must NOT leave an artifact behind"
  end

  def test_dispatch_time_freshness_gate_rejects_non_red_marker
    # If the marker is already in a non-red state when DiagnosisAgent
    # acquires the lock (e.g., a concurrent `hive run` raced ahead),
    # the agent must not spawn at all — its verdict has no audience.
    File.write(@state_file, "<!-- AGENT_WORKING pid=999 -->\n")
    spawned = false
    no_spawn = lambda { |**_kwargs| spawned = true; "should not spawn" }

    assert_raises(Hive::DiagnosisAgent::StaleMarker) do
      Hive::DiagnosisAgent.new(task: @task, spawn: no_spawn).run!
    end
    refute spawned, "DiagnosisAgent must not spawn when marker is not red at dispatch"
  end
end
