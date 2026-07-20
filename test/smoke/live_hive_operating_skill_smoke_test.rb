require "test_helper"
require "digest"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"
require "timeout"
require "yaml"
require_relative "../../packaging/live_agent_skills/proof"

# Opt-in release-readiness proof for the canonical Hive operating skill.
# Each selected platform runs in a disposable private home and receives only
# its provider credential from the environment. The retained evidence is
# structural: native skill discovery, canonical provenance, audited Hive argv,
# event types/digests, cleanup, and secret-scan results. Agent prose is never
# retained or used as the success oracle.
class LiveHiveOperatingSkillSmokeTest < Minitest::Test
  include HiveTestHelper

  PLATFORMS = %w[openclaw claude codex pi].freeze
  INVOCATIONS = {
    "openclaw" => "/hive",
    "claude" => "/hive",
    "codex" => "$hive",
    "pi" => "/skill:hive"
  }.freeze
  REQUIRED_CREDENTIAL = {
    "openclaw" => "OPENAI_API_KEY",
    "claude" => "ANTHROPIC_API_KEY",
    "codex" => "CODEX_API_KEY",
    "pi" => "ANTHROPIC_API_KEY"
  }.freeze
  CONFIG_ENV = {
    "claude" => "CLAUDE_CONFIG_DIR",
    "codex" => "CODEX_HOME",
    "pi" => "PI_CODING_AGENT_DIR"
  }.freeze
  PASSTHROUGH_ENV = %w[
    PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  ].freeze
  TIMEOUT_SEC = 240

  PLATFORMS.each do |platform|
    define_method("test_#{platform}_discovers_and_uses_native_hive_observation") do
      run_live_proof(platform)
    end
  end

  def test_controlled_hive_uses_the_published_operational_and_watch_contracts
    with_tmp_dir do |root|
      audit_path = File.join(root, "audit.jsonl")
      binary = install_audited_hive(
        root, audit_path,
        proven_hive: File.expand_path("../../bin/hive", __dir__)
      )

      status_out, status_err, status = Open3.capture3(binary, *HiveLiveAgentProof::STATUS_ARGV)
      assert status.success?, status_err
      status_payload = JSON.parse(status_out)
      operational_schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status")))
      )
      assert operational_schema.valid?(status_payload)

      watch_out, watch_err, watch_status = Open3.capture3(binary, *HiveLiveAgentProof::WATCH_ARGV)
      assert watch_status.success?, watch_err
      watch_schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-watch-event")))
      )
      watch_events = watch_out.lines.map { |line| JSON.parse(line) }
      assert_equal %w[initial transition final], watch_events.map { |event| event.fetch("event") }
      assert watch_events.all? { |event| watch_schema.valid?(event) }
      assert_equal HiveLiveAgentProof::OBSERVATION_COMMANDS, read_audited_commands(audit_path)
    end
  end

  def test_codex_discovery_requires_the_exact_model_visible_projection
    with_tmp_dir do |root|
      workspace = File.join(root, "workspace")
      destination = File.join(root, "codex", "skills", "hive")
      skill_path = File.join(destination, "SKILL.md")
      FileUtils.mkdir_p([ workspace, destination ])
      secure_write(skill_path, "---\nname: hive\ndescription: test\n---\n")
      binary = File.join(root, "fake-codex")
      secure_write(binary, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        abort "unexpected argv" unless ARGV[0, 2] == ["debug", "prompt-input"]
        puts JSON.generate([
          { "role" => "developer", "content" => "hive (file: #{skill_path})" },
          { "role" => "user", "content" => ARGV.fetch(2) }
        ])
      RUBY
      FileUtils.chmod(0o700, binary)

      discovery = discover_skill(
        "codex", binary, { "PATH" => ENV.fetch("PATH", "") }, workspace,
        destination, "Use $hive for the controlled proof."
      )

      assert_equal "codex-model-input", discovery.fetch("kind")
      assert_equal Digest::SHA256.hexdigest(skill_path), discovery.fetch("file_path_sha256")
      prose = { "type" => "item.completed", "item" => {
        "type" => "agent_message", "text" => "I used #{skill_path}"
      } }
      refute structured_activation?("codex", discovery, [ prose ])
      event = {
        "type" => "item.completed",
        "item" => { "type" => "command_execution", "command" => "read #{skill_path}" }
      }
      assert structured_activation?("codex", discovery, [ event ])
    end
  end

  def test_pi_discovery_requires_the_exact_native_skill_command
    with_tmp_dir do |root|
      workspace = File.join(root, "workspace")
      destination = File.join(root, "pi", "skills", "hive")
      skill_path = File.join(destination, "SKILL.md")
      FileUtils.mkdir_p([ workspace, destination ])
      secure_write(skill_path, "---\nname: hive\ndescription: test\n---\n")
      binary = File.join(root, "fake-pi")
      secure_write(binary, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        request = JSON.parse($stdin.read)
        abort "unexpected request" unless request == { "id" => "hive-proof", "type" => "get_commands" }
        puts JSON.generate(
          "id" => "hive-proof", "type" => "response", "command" => "get_commands", "success" => true,
          "data" => { "commands" => [
            { "name" => "skill:hive", "source" => "skill", "sourceInfo" => { "path" => #{skill_path.dump} } }
          ] }
        )
      RUBY
      FileUtils.chmod(0o700, binary)

      discovery = discover_skill(
        "pi", binary, { "PATH" => ENV.fetch("PATH", "") }, workspace,
        destination, "/skill:hive for the controlled proof."
      )

      assert_equal "pi-rpc-command", discovery.fetch("kind")
      assert_equal Digest::SHA256.hexdigest(skill_path), discovery.fetch("file_path_sha256")
      assert structured_activation?("pi", discovery, [])
    end
  end

  private

  def run_live_proof(platform)
    availability!(ENV["HIVE_LIVE_AGENT_SKILLS"] == "1",
                  "set HIVE_LIVE_AGENT_SKILLS=1 to run authenticated Hive operating-skill proof")
    selected = ENV["HIVE_LIVE_AGENT"].to_s
    skip "HIVE_LIVE_AGENT selects #{selected}" unless selected.empty? || selected == platform

    candidate_sha = ENV["HIVE_CANDIDATE_SHA"].to_s.downcase
    artifacts = ENV["HIVE_PROOF_ARTIFACTS"].to_s
    evidence_path = ENV["HIVE_EVIDENCE_PATH"].to_s
    binary = find_executable(platform)
    credential_name = REQUIRED_CREDENTIAL.fetch(platform)
    credential = ENV[credential_name].to_s
    availability!(HiveLiveAgentProof::SAFE_SHA.match?(candidate_sha), "HIVE_CANDIDATE_SHA must be a full commit SHA")
    availability!(File.directory?(artifacts), "HIVE_PROOF_ARTIFACTS is missing")
    availability!(!evidence_path.empty?, "HIVE_EVIDENCE_PATH is missing")
    availability!(!binary.nil?, "#{platform} binary is not on PATH")
    availability!(!credential.empty?, "#{credential_name} is unavailable")

    root = Dir.mktmpdir("hive-live-#{platform}")
    FileUtils.chmod(0o700, root)
    evidence = base_evidence(platform, candidate_sha)
    failure = nil
    begin
      manifest = validate_candidate_artifacts!(artifacts, candidate_sha)
      skill_root = extract_and_validate_skill!(root, artifacts, manifest, platform)
      workspace, environment, destination = prepare_platform_home(
        root, platform, skill_root, credential_name, credential
      )
      audit_path = File.join(root, "hive-argv.jsonl")
      proven_hive = ENV["HIVE_PROVEN_HIVE_BIN"].to_s
      availability!(File.file?(proven_hive) && File.executable?(proven_hive), "HIVE_PROVEN_HIVE_BIN is unavailable")
      install_audited_hive(root, audit_path, proven_hive: proven_hive)
      environment["PATH"] = [ File.join(root, "bin"), environment.fetch("PATH") ].join(File::PATH_SEPARATOR)

      hive_version = run_version(proven_hive, environment, workspace)
      prompt = operating_prompt(platform)
      native_discovery = discover_skill(
        platform, binary, environment, workspace, destination, prompt
      )
      stdout, stderr, status = run_bounded(environment, agent_argv(platform, binary, prompt), chdir: workspace)
      safe_stdout = redact(stdout, credential)
      safe_stderr = redact(stderr, credential)
      assert status.success?, "#{platform} agent failed: #{safe_stderr.lines.first(12).join}\n#{safe_stdout.lines.first(12).join}"

      commands = read_audited_commands(audit_path)
      assert_native_observation_commands(commands)
      events = parse_native_events(stdout)
      assert structured_activation?(platform, native_discovery, events),
             "#{platform} emitted no structured Hive skill discovery/activation evidence (event types: #{event_types(events).inspect})"
      # Scan the unredacted process streams. Evidence and failure messages are
      # redacted separately; scanning only those redacted copies would make a
      # real credential leak invisible to this proof.
      findings = HiveLiveAgentProof.secret_findings("#{stdout}\n#{stderr}", exact_secrets: [ credential ])
      assert_empty findings, "#{platform} retained output contains credential material"

      projection = JSON.parse(File.read(File.join(skill_root, ".hive-skill.json")))
      evidence.merge!(
        "result" => "passed",
        "agent" => {
          "binary" => File.basename(binary),
          "version" => first_line(run_version(binary, environment, workspace)),
          "native_event_types" => event_types(events),
          "native_output_sha256" => Digest::SHA256.hexdigest(stdout),
          "native_stderr_sha256" => Digest::SHA256.hexdigest(stderr),
          "discovery_sha256" => Digest::SHA256.hexdigest(JSON.generate(native_discovery))
        },
        "hive" => { "version" => first_line(hive_version), "binary" => "proven-candidate-gem" },
        "skill" => {
          "invocation" => INVOCATIONS.fetch(platform),
          "skill_version" => projection.fetch("skill_version"),
          "canonical_digest" => projection.fetch("canonical_digest"),
          "projection_manifest_sha256" => Digest::SHA256.file(File.join(skill_root, ".hive-skill.json")).hexdigest
        },
        "hive_commands" => commands,
        "secret_scan" => { "status" => "passed", "scanner" => "hive-live-agent-proof/v1" }
      )
    rescue Minitest::Assertion, StandardError => e
      failure = e
      evidence["result"] = "failed"
      evidence["failure"] = redact(e.message.to_s, credential).byteslice(0, 1_000)
      evidence["secret_scan"] ||= { "status" => "passed", "scanner" => "hive-live-agent-proof/v1" }
    ensure
      FileUtils.rm_rf(root)
      evidence["cleanup"] = { "status" => File.exist?(root) ? "failed" : "passed" }
      write_evidence(evidence_path, evidence)
    end
    raise failure if failure
  end

  def availability!(condition, message)
    return if condition
    raise Minitest::Assertion, message if ENV["HIVE_RELEASE_GATE"] == "1"

    skip message
  end

  def base_evidence(platform, candidate_sha)
    {
      "schema" => "hive-live-agent-skill-evidence",
      "schema_version" => 1,
      "platform" => platform,
      "candidate_sha" => candidate_sha,
      "result" => "failed"
    }
  end

  def validate_candidate_artifacts!(root, candidate_sha)
    manifest = HiveLiveAgentProof.read_json(File.join(root, "artifact-manifest.json"))
    assert_equal "hive-live-agent-candidate-artifacts", manifest["schema"]
    assert_equal candidate_sha, manifest["candidate_sha"]
    manifest.fetch("files").each do |name, record|
      HiveLiveAgentProof.verify_file_record!(root, name, record)
    end
    manifest
  end

  def extract_and_validate_skill!(root, artifacts, manifest, platform)
    archive_name = "hive-agent-skills-#{manifest.fetch('candidate_sha')}.tar.gz"
    archive = HiveLiveAgentProof.relative_file!(artifacts, archive_name)
    list, list_error, list_status = Open3.capture3("tar", "-tzf", archive)
    assert list_status.success?, "cannot list skill archive: #{list_error}"
    entries = list.lines.map(&:strip).reject(&:empty?)
    assert entries.all? { |entry| safe_archive_entry?(entry) }, "skill archive contains an unsafe path"
    extract = File.join(root, "projections")
    FileUtils.mkdir_p(extract, mode: 0o700)
    _out, extract_error, extract_status = Open3.capture3("tar", "-xzf", archive, "-C", extract)
    assert extract_status.success?, "cannot extract skill archive: #{extract_error}"

    skill_root = File.join(extract, platform, "hive")
    projection = JSON.parse(File.read(File.join(skill_root, ".hive-skill.json")))
    assert_equal platform, projection.fetch("platform")
    assert_equal INVOCATIONS.fetch(platform), projection.fetch("invocation")
    assert_equal manifest.fetch("skill_version"), projection.fetch("skill_version")
    assert_equal manifest.fetch("canonical_digest"), projection.fetch("canonical_digest")
    projection.fetch("files").each do |relative, digest|
      path = HiveLiveAgentProof.relative_file!(skill_root, relative)
      assert_equal digest, Digest::SHA256.file(path).hexdigest
    end
    skill_root
  end

  def safe_archive_entry?(entry)
    normalized = entry.delete_prefix("./")
    !normalized.empty? && !normalized.start_with?("/") && !Pathname.new(normalized).each_filename.include?("..")
  end

  def prepare_platform_home(root, platform, skill_root, credential_name, credential)
    home = File.join(root, "home")
    workspace = File.join(root, "workspace")
    FileUtils.mkdir_p([ home, workspace ], mode: 0o700)
    environment = PASSTHROUGH_ENV.to_h { |name| [ name, ENV[name] ] }.compact
    environment.merge!("HOME" => home, "HIVE_LIVE_PROOF" => "1", credential_name => credential)

    destination = case platform
    when "openclaw"
      state = File.join(home, ".openclaw")
      destination = File.join(workspace, "skills", "hive")
      FileUtils.mkdir_p(state, mode: 0o700)
      model = ENV["HIVE_LIVE_MODEL"].to_s
      availability!(!model.empty?, "HIVE_LIVE_MODEL is required for OpenClaw proof")
      config = {
        "agents" => { "defaults" => { "workspace" => workspace, "model" => { "primary" => model } } },
        "tools" => { "profile" => "coding" }
      }
      config_path = File.join(state, "openclaw.json")
      secure_write(config_path, JSON.pretty_generate(config) + "\n")
      environment["OPENCLAW_STATE_DIR"] = state
      environment["OPENCLAW_CONFIG_PATH"] = config_path
      destination
    else
      config_root = File.join(home, ".#{platform}")
      config_root = File.join(home, ".pi", "agent") if platform == "pi"
      FileUtils.mkdir_p(config_root, mode: 0o700)
      environment[CONFIG_ENV.fetch(platform)] = config_root
      File.join(config_root, "skills", "hive")
    end
    FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
    FileUtils.cp_r(skill_root, destination, preserve: false)
    [ workspace, environment, destination ]
  end

  def install_audited_hive(root, audit_path, proven_hive:)
    assert File.file?(proven_hive) && File.executable?(proven_hive),
           "the audited wrapper requires an executable proven Hive candidate"

    proof_home = File.join(root, "home")
    project_root = File.join(root, "proof-project")
    hive_state = File.join(project_root, ".hive-state")
    task_folder = File.join(hive_state, "stages", "2-brainstorm", "live-agent-skill")
    state_file = File.join(task_folder, "brainstorm.md")
    FileUtils.mkdir_p(task_folder, mode: 0o700)
    project_config = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    project_config["project_name"] = "proof"
    secure_write(File.join(hive_state, "config.yml"), YAML.dump(project_config))
    secure_write(state_file, "# Live agent skill proof\n<!-- COMPLETE -->\n")
    secure_write(
      File.join(proof_home, ".config", "hive", "config.yml"),
      YAML.dump(
        "registered_projects" => [ {
          "name" => "proof",
          "path" => project_root,
          "hive_state_path" => hive_state
        } ]
      )
    )

    bin_dir = File.join(root, "bin")
    FileUtils.mkdir_p(bin_dir, mode: 0o700)
    script = <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      allowed = #{HiveLiveAgentProof::OBSERVATION_COMMANDS.inspect}
      unless allowed.include?(ARGV)
        warn "live proof permits only operational status and bounded native watch"
        exit 64
      end

      audit = #{audit_path.dump}
      File.open(audit, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        ordinal = File.foreach(audit).count + 1
        file.puts(JSON.generate("argv" => ARGV, "ordinal" => ordinal))
      end

      if ARGV == #{HiveLiveAgentProof::WATCH_ARGV.inspect}
        child = fork do
          sleep 3
          state_file = #{state_file.dump}
          temporary = "#{state_file}.transition"
          File.write(temporary, "# Live agent skill proof\\n<!-- WAITING -->\\n", mode: "w", perm: 0o600)
          File.rename(temporary, state_file)
        end
        Process.detach(child)
      end

      ENV["HOME"] = #{proof_home.dump}
      %w[
        HIVE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
      ].each { |key| ENV.delete(key) }
      exec #{File.expand_path(proven_hive).dump}, *ARGV
    RUBY
    path = File.join(bin_dir, "hive")
    secure_write(path, script)
    FileUtils.chmod(0o700, path)
    path
  end

  def discover_skill(platform, binary, environment, workspace, destination, prompt)
    skill_path = File.join(destination, "SKILL.md")
    case platform
    when "openclaw"
      stdout, stderr, status = run_bounded(
        environment, [ binary, "skills", "info", "hive", "--json" ], chdir: workspace, timeout: 60
      )
      assert status.success?, "OpenClaw skill discovery failed: #{redact(stderr, environment['OPENAI_API_KEY'])}"
      info = JSON.parse(stdout)
      assert_equal "hive", info.fetch("name")
      assert_equal true, info.fetch("eligible")
      assert_equal true, info.fetch("userInvocable")
      assert_equal File.realpath(skill_path), File.realpath(info.fetch("filePath"))
      { "kind" => "openclaw-skills-info", "name" => info.fetch("name"), "eligible" => true,
        "user_invocable" => true, "file_path_sha256" => Digest::SHA256.hexdigest(info.fetch("filePath")) }
    when "codex"
      stdout, stderr, status = run_bounded(
        environment, [ binary, "debug", "prompt-input", prompt ], chdir: workspace, timeout: 60
      )
      assert status.success?, "Codex model-input discovery failed: #{redact(stderr, environment['CODEX_API_KEY'])}"
      model_input = JSON.parse(stdout)
      serialized = JSON.generate(model_input)
      assert_includes serialized, skill_path
      assert_includes serialized, "$hive"
      { "kind" => "codex-model-input", "name" => "hive",
        "file_path_sha256" => Digest::SHA256.hexdigest(skill_path),
        "model_input_sha256" => Digest::SHA256.hexdigest(serialized) }
    when "pi"
      request = JSON.generate("id" => "hive-proof", "type" => "get_commands") + "\n"
      stdout, stderr, status = run_bounded(
        environment.merge("PI_OFFLINE" => "1"),
        [ binary, "--mode", "rpc", "--no-session", "--offline", "--no-extensions",
          "--no-context-files", "--no-approve", "--tools", "bash" ],
        chdir: workspace, timeout: 60, stdin_data: request
      )
      assert status.success?, "Pi RPC discovery failed: #{redact(stderr, environment['ANTHROPIC_API_KEY'])}"
      responses = stdout.lines.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      response = responses.find do |row|
        row["id"] == "hive-proof" && row["command"] == "get_commands" && row["success"] == true
      end
      commands = response&.dig("data", "commands")
      assert_kind_of Array, commands
      command = commands.find { |row| row["name"] == "skill:hive" && row["source"] == "skill" }
      refute_nil command, "Pi did not expose /skill:hive through its native command inventory"
      discovered_path = command.dig("sourceInfo", "path") || command["path"]
      assert_equal File.realpath(skill_path), File.realpath(discovered_path)
      { "kind" => "pi-rpc-command", "name" => command.fetch("name"),
        "file_path_sha256" => Digest::SHA256.hexdigest(discovered_path),
        "inventory_sha256" => Digest::SHA256.hexdigest(JSON.generate(response)) }
    else
      { "kind" => "native-skill-root", "name" => "hive",
        "file_path_sha256" => Digest::SHA256.hexdigest(skill_path) }
    end
  end

  def operating_prompt(platform)
    invocation = INVOCATIONS.fetch(platform)
    <<~PROMPT
      #{invocation}
      Use the installed Hive operating skill and its status-and-watch reference. This is a controlled release proof.
      Request a fresh agent operational snapshot and identify the exact active target from its structured fields.
      Only if that target is proof:live-agent-skill, follow it with one native observer bounded by settled state,
      a 20-second timeout, five events, a one-second interval, and JSON Lines output.
      Stop after the final watch record. Do not use process discovery, logs, a polling loop, a sidecar, hive act, or any mutating/admin/release command.
    PROMPT
  end

  def agent_argv(platform, binary, prompt)
    model = ENV["HIVE_LIVE_MODEL"].to_s
    case platform
    when "openclaw"
      [ binary, "agent", "--local", "--agent", "main", "--message", prompt, "--timeout", "180", "--json" ]
    when "claude"
      argv = [ binary, "-p", "--bare", "--output-format", "stream-json", "--verbose",
               "--no-session-persistence", "--tools", "Bash", "--dangerously-skip-permissions" ]
      argv.concat([ "--model", model ]) unless model.empty?
      argv << prompt
    when "codex"
      argv = [ binary, "exec", "--json", "--sandbox", "workspace-write", "-c", 'approval_policy="never"',
               "--ephemeral", "--skip-git-repo-check" ]
      argv.concat([ "--model", model ]) unless model.empty?
      argv << prompt
    when "pi"
      argv = [ binary, "-p", "--mode", "json", "--no-session", "--tools", "bash" ]
      argv.concat([ "--model", model ]) unless model.empty?
      argv << prompt
    end
  end

  def run_version(binary, environment, workspace)
    stdout, stderr, status = run_bounded(environment, [ binary, "--version" ], chdir: workspace, timeout: 30)
    assert status.success?, "version probe failed for #{File.basename(binary)}: #{stderr.lines.first}"
    stdout
  end

  def run_bounded(environment, argv, chdir:, timeout: TIMEOUT_SEC, stdin_data: nil)
    stdout = +""
    stderr = +""
    status = nil
    Open3.popen3(environment, *argv, chdir: chdir, pgroup: true, unsetenv_others: true) do |stdin, out, err, wait|
      stdin.write(stdin_data) if stdin_data
      stdin.close
      out_reader = Thread.new { out.read }
      err_reader = Thread.new { err.read }
      begin
        Timeout.timeout(timeout) { status = wait.value }
      rescue Timeout::Error
        terminate_group(wait.pid)
        status = wait.value
        raise Minitest::Assertion, "#{File.basename(argv.first)} exceeded #{timeout}s proof timeout"
      ensure
        stdout = out_reader.value
        stderr = err_reader.value
      end
    end
    [ stdout, stderr, status ]
  end

  def terminate_group(pid)
    Process.kill("TERM", -pid)
    sleep 0.2
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end

  def read_audited_commands(path)
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).map { |line| JSON.parse(line).fetch("argv") }
  end

  def assert_native_observation_commands(commands)
    assert_equal HiveLiveAgentProof::OBSERVATION_COMMANDS, commands,
                 "expected exactly one operational status and one bounded native watch"
  end

  def parse_native_events(output)
    lines = output.lines.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    return lines unless lines.empty?

    value = JSON.parse(output)
    value.is_a?(Array) ? value : [ value ]
  rescue JSON::ParserError
    []
  end

  def structured_activation?(platform, discovery, events)
    return discovery["kind"] == "openclaw-skills-info" if platform == "openclaw"
    return discovery["kind"] == "pi-rpc-command" if platform == "pi"

    events.any? do |event|
      structured_skill_key?(event) || structured_skill_access?(event)
    end
  end

  def structured_skill_access?(value)
    case value
    when Hash
      type = (value["type"] || value["kind"]).to_s
      serialized = JSON.generate(value)
      access = type.match?(/command_execution|tool_use|tool_call|file_read|read_file/i) &&
        (serialized.include?("/skills/hive/SKILL.md") || serialized.include?("\\skills\\hive\\SKILL.md"))
      access || value.values.any? { |nested| structured_skill_access?(nested) }
    when Array
      value.any? { |nested| structured_skill_access?(nested) }
    else
      false
    end
  end

  def structured_skill_key?(value)
    case value
    when Hash
      value.any? do |key, nested|
        (key.to_s.match?(/skill|plugin|resource/i) && JSON.generate(nested).match?(/(?:\$|\/skill:|\/)hive\b|SKILL\.md/)) ||
          structured_skill_key?(nested)
      end
    when Array
      value.any? { |nested| structured_skill_key?(nested) }
    else
      false
    end
  end

  def event_types(events)
    events.filter_map do |event|
      next unless event.is_a?(Hash)

      (event["type"] || event["event"] || event["kind"]).to_s.then { |type| type unless type.empty? }
    end.tally.sort.to_h
  end

  def redact(text, *secrets)
    redacted = text.to_s.dup
    secrets.flatten.compact.reject(&:empty?).each { |secret| redacted.gsub!(secret, "[REDACTED]") }
    HiveLiveAgentProof::SECRET_PATTERNS.each { |pattern| redacted.gsub!(pattern, "[REDACTED]") }
    redacted
  end

  def first_line(value)
    value.to_s.lines.first.to_s.strip.byteslice(0, 200)
  end

  def secure_write(path, body)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(body) }
  end

  def write_evidence(path, evidence)
    return if path.to_s.empty?

    findings = HiveLiveAgentProof.secret_findings(JSON.generate(evidence))
    evidence["secret_scan"] = { "status" => "failed", "scanner" => "hive-live-agent-proof/v1" } unless findings.empty?
    HiveLiveAgentProof.write_json(path, evidence)
  end

  def find_executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      path = File.join(directory, name)
      return File.expand_path(path) if File.file?(path) && File.executable?(path)
    end
    nil
  end
end
