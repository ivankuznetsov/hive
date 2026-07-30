require "test_helper"
require "digest"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "timeout"
require "yaml"
require_relative "../../packaging/live_agent_skills/proof"

# Authenticated, opt-in proof that OpenClaw discovers the exact candidate
# /hive skill and follows its workflow-creator route. The success oracle is the
# controlled Hive command stream plus the authored files and validation graph;
# agent prose is never retained or trusted.
class LiveHiveWorkflowCreatorSmokeTest < Minitest::Test
  include HiveTestHelper

  TIMEOUT_SEC = 240
  PASSTHROUGH_ENV = %w[
    PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  ].freeze

  def test_openclaw_creates_and_validates_editorial_workflow_without_a_task
    availability!(ENV["HIVE_LIVE_AGENT_SKILLS"] == "1",
                  "set HIVE_LIVE_AGENT_SKILLS=1 to run authenticated workflow-creator proof")
    candidate_sha = ENV["HIVE_CANDIDATE_SHA"].to_s.downcase
    artifacts = ENV["HIVE_PROOF_ARTIFACTS"].to_s
    evidence_path = ENV["HIVE_CREATOR_EVIDENCE_PATH"].to_s
    credential = ENV["OPENAI_API_KEY"].to_s
    binary = find_executable("openclaw")
    availability!(!evidence_path.empty?, "HIVE_CREATOR_EVIDENCE_PATH is missing")

    store = HiveLiveAgentProof::WorkflowCreatorEvidence.new(path: evidence_path)
    store.initialize!(candidate_sha: candidate_sha)
    root = nil
    model_loop_executed = false
    succeeded = false
    failure = nil
    begin
      availability!(HiveLiveAgentProof::SAFE_SHA.match?(candidate_sha),
                    "HIVE_CANDIDATE_SHA must be a full commit SHA")
      availability!(File.directory?(artifacts), "HIVE_PROOF_ARTIFACTS is missing")
      availability!(!credential.empty?, "OPENAI_API_KEY is unavailable")
      availability!(!binary.nil?, "openclaw binary is not on PATH")

      root = Dir.mktmpdir("hive-live-workflow-creator")
      FileUtils.chmod(0o700, root)
      manifest = validate_candidate_artifacts!(artifacts, candidate_sha)
      skill_root = extract_openclaw_skill!(root, artifacts, manifest)
      workspace, environment, destination = prepare_openclaw_home(
        root, skill_root, credential
      )
      audit_path = File.join(root, "hive-argv.jsonl")
      validation_path = File.join(root, "workflow-validation.json")
      task_proof_path = File.join(root, "task-proof.json")
      install_controlled_hive(workspace, root, audit_path, validation_path, task_proof_path)
      environment["PATH"] = [ File.join(root, "bin"), environment.fetch("PATH") ].join(File::PATH_SEPARATOR)

      discover_openclaw_skill(binary, environment, workspace, destination, credential)
      stdout, stderr, status = run_bounded(
        environment,
        [
          binary, "agent", "--local", "--agent", "main",
          "--message", HiveLiveAgentProof::WORKFLOW_CREATOR_PROMPT,
          "--timeout", "180", "--json"
        ],
        chdir: workspace
      )
      assert status.success?,
             "OpenClaw workflow creator failed: #{redact(stderr, credential).lines.first(12).join}\n" \
             "#{redact(stdout, credential).lines.first(12).join}"
      model_loop_executed = true

      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.first(5),
                   read_audited_commands(audit_path)
      validation = JSON.parse(File.read(validation_path))
      assert_equal true, validation.fetch("valid")
      created_files = created_file_records(workspace)
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_FILES,
                   created_files.map { |record| record.fetch("path") }.sort
      assert_equal 0, task_count(workspace)
      task_stdout, task_stderr, task_status = run_bounded(
        environment,
        [
          binary, "agent", "--local", "--agent", "main",
          "--message", HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_PROMPT,
          "--timeout", "180", "--json"
        ],
        chdir: workspace
      )
      assert task_status.success?,
             "OpenClaw workflow task retry failed: #{redact(task_stderr, credential).lines.first(12).join}\n" \
             "#{redact(task_stdout, credential).lines.first(12).join}"

      commands = read_audited_commands(audit_path)
      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS, commands
      assert_equal 1, task_count(workspace)
      findings = HiveLiveAgentProof.secret_findings("#{stdout}\n#{stderr}", exact_secrets: [ credential ])
      findings.concat(
        HiveLiveAgentProof.secret_findings(
          "#{task_stdout}\n#{task_stderr}", exact_secrets: [ credential ]
        )
      )
      assert_empty findings, "OpenClaw retained output contains credential material"
      succeeded = true
    rescue Minitest::Assertion, StandardError => e
      failure = e
    ensure
      FileUtils.rm_rf(root) if root
      terminal = HiveLiveAgentProof::WorkflowCreatorContract.terminal_failure(
        candidate_sha: candidate_sha,
        proof_succeeded: succeeded,
        model_loop_executed: model_loop_executed,
        detail: failure&.message,
        exact_secrets: [ credential ]
      )
      store.replace_nonpassing!(terminal, exact_secrets: [ credential ])
    end
    raise failure if failure
  end

  def test_controlled_hive_enforces_the_editorial_graph_and_command_order
    with_tmp_dir do |root|
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      audit_path = File.join(root, "audit.jsonl")
      validation_path = File.join(root, "validation.json")
      task_proof_path = File.join(root, "task-proof.json")
      binary = install_controlled_hive(
        workspace, root, audit_path, validation_path, task_proof_path
      )

      run_controlled!(binary, workspace, "version")
      run_controlled!(binary, workspace, "workflow", "list", "--json")
      scaffold = JSON.parse(run_controlled!(binary, workspace, "workflow", "new", "editorial", "--json"))
      author_editorial(scaffold)
      validation = JSON.parse(
        run_controlled!(binary, workspace, "workflow", "validate", "editorial", "--json")
      )
      run_controlled!(binary, workspace, "workflow", "commit", "editorial")
      first = JSON.parse(
        run_controlled!(binary, workspace, *HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_NEW_ARGV)
      )
      run_controlled!(binary, workspace, "run", HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_SLUG)
      retry_payload = JSON.parse(
        run_controlled!(binary, workspace, *HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_NEW_ARGV)
      )
      run_controlled!(binary, workspace, "status", "--operational", "--json")
      task = JSON.parse(File.read(task_proof_path))

      assert_equal HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS, read_audited_commands(audit_path)
      assert_equal %w[research draft approval], validation.fetch("stages").map { |stage| stage.fetch("name") }
      assert_equal true, validation.fetch("valid")
      assert_equal true, first.fetch("created")
      assert_equal false, retry_payload.fetch("created")
      assert_equal 1, task.fetch("run_count")
      assert_equal 1, task_count(workspace)
    end
  end

  def test_controlled_hive_rejects_out_of_order_commands_before_audit
    with_tmp_dir do |root|
      workspace = File.join(root, "workspace")
      FileUtils.mkdir_p(workspace)
      audit_path = File.join(root, "audit.jsonl")
      binary = install_controlled_hive(
        workspace, root, audit_path,
        File.join(root, "validation.json"), File.join(root, "task-proof.json")
      )

      stdout, stderr, status = Open3.capture3(
        binary, "workflow", "list", "--json", chdir: workspace
      )

      assert_equal 64, status.exitstatus
      assert_empty stdout
      assert_equal(
        "workflow-creator proof expected [\"version\"], got [\"workflow\", \"list\", \"--json\"]\n",
        stderr
      )
      assert_empty read_audited_commands(audit_path)
    end
  end

  private

  def availability!(condition, message)
    return if condition
    raise Minitest::Assertion, message if ENV["HIVE_RELEASE_GATE"] == "1"

    skip message
  end

  def validate_candidate_artifacts!(root, candidate_sha)
    manifest = HiveLiveAgentProof.read_json(File.join(root, "artifact-manifest.json"))
    assert_equal "hive-live-agent-candidate-artifacts", manifest.fetch("schema")
    assert_equal candidate_sha, manifest.fetch("candidate_sha")
    manifest.fetch("files").each do |name, record|
      HiveLiveAgentProof.verify_file_record!(root, name, record)
    end
    manifest
  end

  def extract_openclaw_skill!(root, artifacts, manifest)
    archive_name = "hive-agent-skills-#{manifest.fetch('candidate_sha')}.tar.gz"
    archive = HiveLiveAgentProof.relative_file!(artifacts, archive_name)
    listing, list_error, list_status = Open3.capture3("tar", "-tzf", archive)
    assert list_status.success?, "cannot list skill archive: #{list_error}"
    entries = listing.lines.map(&:strip).reject(&:empty?)
    assert entries.all? { |entry| safe_archive_entry?(entry) },
           "skill archive contains an unsafe path"

    extract = File.join(root, "projections")
    FileUtils.mkdir_p(extract, mode: 0o700)
    _out, extract_error, extract_status = Open3.capture3("tar", "-xzf", archive, "-C", extract)
    assert extract_status.success?, "cannot extract skill archive: #{extract_error}"
    skill_root = File.join(extract, "openclaw", "hive")
    projection = JSON.parse(File.read(File.join(skill_root, ".hive-skill.json")))
    assert_equal "openclaw", projection.fetch("platform")
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
    !normalized.empty? && !normalized.start_with?("/") &&
      !Pathname.new(normalized).each_filename.include?("..")
  end

  def prepare_openclaw_home(root, skill_root, credential)
    home = File.join(root, "home")
    workspace = File.join(root, "workspace")
    state = File.join(home, ".openclaw")
    destination = File.join(workspace, "skills", "hive")
    FileUtils.mkdir_p([ state, workspace, File.dirname(destination) ], mode: 0o700)
    FileUtils.cp_r(skill_root, destination, preserve: false)
    model = ENV["HIVE_LIVE_MODEL"].to_s
    availability!(!model.empty?, "HIVE_LIVE_MODEL is required for OpenClaw proof")
    config = {
      "agents" => {
        "defaults" => { "workspace" => workspace, "model" => { "primary" => model } }
      },
      "tools" => { "profile" => "coding" }
    }
    config_path = File.join(state, "openclaw.json")
    secure_write(config_path, JSON.pretty_generate(config) + "\n")
    environment = PASSTHROUGH_ENV.to_h { |name| [ name, ENV[name] ] }.compact
    environment.merge!(
      "HOME" => home,
      "OPENAI_API_KEY" => credential,
      "OPENCLAW_STATE_DIR" => state,
      "OPENCLAW_CONFIG_PATH" => config_path,
      "HIVE_LIVE_PROOF" => "1"
    )
    [ workspace, environment, destination ]
  end

  def discover_openclaw_skill(binary, environment, workspace, destination, credential)
    stdout, stderr, status = run_bounded(
      environment, [ binary, "skills", "info", "hive", "--json" ],
      chdir: workspace, timeout: 60
    )
    assert status.success?, "OpenClaw skill discovery failed: #{redact(stderr, credential)}"
    info = JSON.parse(stdout)
    assert_equal "hive", info.fetch("name")
    assert_equal true, info.fetch("eligible")
    assert_equal true, info.fetch("userInvocable")
    assert_equal File.realpath(File.join(destination, "SKILL.md")),
                 File.realpath(info.fetch("filePath"))
    {
      "kind" => "openclaw-skills-info",
      "name" => info.fetch("name"),
      "file_path_sha256" => Digest::SHA256.hexdigest(info.fetch("filePath"))
    }
  end

  def install_controlled_hive(workspace, root, audit_path, validation_path, task_proof_path)
    state = File.join(workspace, ".hive-state")
    workflows = File.join(state, "workflows")
    FileUtils.mkdir_p(workflows, mode: 0o700)
    secure_write(
      File.join(state, "config.yml"),
      YAML.dump(
        "project_name" => "workflow-creator-proof",
        "hive_state_path" => state,
        "agents" => { "default" => "codex" },
        "models" => { "default" => "project-default" }
      )
    )
    bin_dir = File.join(root, "bin")
    FileUtils.mkdir_p(bin_dir, mode: 0o700)
    script = <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      require "fileutils"
      require "yaml"

      allowed = #{HiveLiveAgentProof::WORKFLOW_CREATOR_COMMANDS.inspect}
      audit = #{audit_path.dump}
      ordinal = File.file?(audit) ? File.foreach(audit).count : 0
      unless ARGV == allowed[ordinal]
        warn "workflow-creator proof expected \#{allowed[ordinal].inspect}, got \#{ARGV.inspect}"
        exit 64
      end
      File.open(audit, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |file|
        file.puts(JSON.generate("argv" => ARGV, "ordinal" => ordinal + 1))
      end

      workspace = #{workspace.dump}
      workflows = File.join(workspace, ".hive-state", "workflows")
      descriptor = File.join(workflows, "editorial.yml")
      instruction_dir = File.join(workflows, "editorial")
      task_dir = File.join(
        workspace, ".hive-state", "stages", "1-research",
        #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_SLUG.dump}
      )
      case ARGV
      when ["version"]
        puts #{Hive::VERSION.dump}
      when ["workflow", "list", "--json"]
        puts JSON.generate(
          "schema" => "hive-workflow-list", "schema_version" => 2,
          "ok" => true, "workflows" => []
        )
      when ["workflow", "new", "editorial", "--json"]
        abort "workflow already exists" if File.exist?(descriptor) || File.exist?(instruction_dir)
        FileUtils.mkdir_p(instruction_dir)
        File.write(File.join(instruction_dir, "work.md"), "Describe this stage.\\n")
        File.write(descriptor, <<~YAML)
          id: editorial
          stages:
            - name: work
              kind: agent
              state_file: work.md
              instruction: editorial/work.md
              permissions: yolo
        YAML
        puts JSON.generate(
          "schema" => "hive-workflow-new", "schema_version" => 1, "ok" => true,
          "id" => "editorial", "descriptor_path" => descriptor,
          "instruction_path" => File.join(instruction_dir, "work.md"),
          "next" => "hive new workflow-creator-proof --workflow editorial \\"<your idea>\\""
        )
      when ["workflow", "validate", "editorial", "--json"]
        expected = {
          "id" => "editorial",
          "stages" => [
            {
              "name" => "research", "kind" => "agent", "state_file" => "research.md",
              "instruction" => "editorial/research.md", "permissions" => "yolo"
            },
            {
              "name" => "draft", "kind" => "agent", "state_file" => "draft.md",
              "instruction" => "editorial/draft.md", "permissions" => "yolo"
            },
            {
              "name" => "approval", "kind" => "human", "state_file" => "approval.md",
              "input" => "draft.md",
              "outcomes" => {
                "approve" => { "complete" => true, "artifact" => "draft.md" },
                "reject" => { "to" => "draft" }
              }
            }
          ]
        }
        actual = YAML.safe_load(File.read(descriptor), aliases: false)
        abort "editorial descriptor differs from the accepted graph" unless actual == expected
        %w[research draft].each do |name|
          path = File.join(instruction_dir, "\#{name}.md")
          abort "missing or empty instruction \#{path}" unless File.file?(path) && !File.read(path).strip.empty?
        end
        expected_files = %w[draft.md research.md]
        actual_files = Dir.children(instruction_dir).sort
        abort "unexpected editorial instruction files: \#{actual_files.inspect}" unless actual_files == expected_files
        payload = {
          "schema" => "hive-workflow-validate", "schema_version" => 1,
          "valid" => true, "id" => "editorial", "origin" => "authored",
          "descriptor_path" => descriptor,
          "instruction_paths" => expected_files.map { |name| File.join(instruction_dir, name) },
          "stages" => [
            { "name" => "research", "kind" => "agent" },
            { "name" => "draft", "kind" => "agent" },
            { "name" => "approval", "kind" => "human" }
          ],
          "automatic_edges" => [
            { "from" => "research", "to" => "draft" },
            { "from" => "draft", "to" => "approval" }
          ],
          "human_outcomes" => [
            { "stage" => "approval", "name" => "approve", "complete" => true,
              "artifact" => "draft.md", "to" => nil },
            { "stage" => "approval", "name" => "reject", "complete" => false,
              "artifact" => nil, "to" => "draft" }
          ]
        }
        File.write(#{validation_path.dump}, JSON.pretty_generate(payload) + "\\n")
        puts JSON.generate(payload)
      when ["workflow", "commit", "editorial"]
        abort "workflow was not validated before commit" unless File.file?(#{validation_path.dump})
        puts "hive: committed populated workflow editorial"
      when #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_NEW_ARGV.inspect}
        created = !File.directory?(task_dir)
        if created
          FileUtils.mkdir_p(task_dir)
          File.write(File.join(task_dir, "research.md"), "<!-- WAITING -->\\n")
          File.write(
            File.join(task_dir, "meta.yml"),
            YAML.dump(
              "slug" => #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_SLUG.dump},
              "workflow" => "editorial",
              "idempotency_key" => #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_KEY.dump}
            )
          )
          proof = {
            "slug" => #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_SLUG.dump},
            "workflow" => "editorial", "first_created" => true,
            "retry_created" => nil, "run_count" => 0, "current_stage" => "1-research"
          }
        else
          proof = JSON.parse(File.read(#{task_proof_path.dump}))
          proof["retry_created"] = false
        end
        File.write(#{task_proof_path.dump}, JSON.pretty_generate(proof) + "\\n")
        puts JSON.generate(
          "schema" => "hive-new", "schema_version" => 1, "ok" => true,
          "created" => created, "slug" => proof.fetch("slug"), "workflow" => "editorial",
          "current_stage" => "1-research", "task_folder" => task_dir,
          "next_action" => {
            "kind" => "run", "command" => "hive run \#{proof.fetch('slug')}"
          }
        )
      when ["run", #{HiveLiveAgentProof::WORKFLOW_CREATOR_TASK_SLUG.dump}]
        abort "task is missing" unless File.directory?(task_dir)
        proof = JSON.parse(File.read(#{task_proof_path.dump}))
        abort "first stage was dispatched more than once" unless proof.fetch("run_count") == 0
        proof["run_count"] = 1
        File.write(#{task_proof_path.dump}, JSON.pretty_generate(proof) + "\\n")
        puts JSON.generate(
          "schema" => "hive-run", "schema_version" => 1, "ok" => true,
          "slug" => proof.fetch("slug"), "current_stage" => "1-research"
        )
      when ["status", "--operational", "--json"]
        proof = JSON.parse(File.read(#{task_proof_path.dump}))
        abort "idempotent retry did not occur" unless proof["retry_created"] == false
        File.write(#{task_proof_path.dump}, JSON.pretty_generate(proof) + "\\n")
        puts JSON.generate(
          "schema" => "hive-operational-status", "schema_version" => 1,
          "tasks" => [
            {
              "identity" => { "slug" => proof.fetch("slug") },
              "position" => { "stage" => "1-research" },
              "runtime" => { "daemon_disposition" => "manual" },
              "transition" => { "next" => "draft" }
            }
          ]
        )
      end
    RUBY
    path = File.join(bin_dir, "hive")
    secure_write(path, script)
    FileUtils.chmod(0o700, path)
    path
  end

  def author_editorial(scaffold)
    descriptor = scaffold.fetch("descriptor_path")
    instruction_dir = File.dirname(scaffold.fetch("instruction_path"))
    FileUtils.rm_f(File.join(instruction_dir, "work.md"))
    secure_write(File.join(instruction_dir, "research.md"), "Research and write research.md.\n")
    secure_write(File.join(instruction_dir, "draft.md"), "Draft from research.md into draft.md.\n")
    secure_write(descriptor, <<~YAML)
      id: editorial
      stages:
        - name: research
          kind: agent
          state_file: research.md
          instruction: editorial/research.md
          permissions: yolo
        - name: draft
          kind: agent
          state_file: draft.md
          instruction: editorial/draft.md
          permissions: yolo
        - name: approval
          kind: human
          state_file: approval.md
          input: draft.md
          outcomes:
            approve:
              complete: true
              artifact: draft.md
            reject:
              to: draft
    YAML
  end

  def run_controlled!(binary, workspace, *argv)
    stdout, stderr, status = Open3.capture3(binary, *argv, chdir: workspace)
    assert status.success?, stderr
    stdout
  end

  def read_audited_commands(path)
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).map { |line| JSON.parse(line).fetch("argv") }
  end

  def created_file_records(workspace)
    HiveLiveAgentProof::WORKFLOW_CREATOR_FILES.map do |relative|
      path = File.join(workspace, relative)
      assert File.file?(path), "missing created file #{relative}"
      {
        "path" => relative,
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "size" => File.size(path)
      }
    end
  end

  def task_count(workspace)
    Dir.glob(File.join(workspace, ".hive-state", "stages", "*", "*"))
       .count { |path| File.directory?(path) }
  end

  def run_bounded(environment, argv, chdir:, timeout: TIMEOUT_SEC)
    stdout = +""
    stderr = +""
    status = nil
    Open3.popen3(environment, *argv, chdir: chdir, pgroup: true, unsetenv_others: true) do |stdin, out, err, wait|
      stdin.close
      out_reader = Thread.new { out.read }
      err_reader = Thread.new { err.read }
      begin
        Timeout.timeout(timeout) { status = wait.value }
      rescue Timeout::Error
        Process.kill("TERM", -wait.pid)
        status = wait.value
        raise Minitest::Assertion, "#{File.basename(argv.first)} exceeded #{timeout}s proof timeout"
      ensure
        stdout = out_reader.value
        stderr = err_reader.value
      end
    end
    [ stdout, stderr, status ]
  end

  def redact(text, *secrets)
    HiveLiveAgentProof::WorkflowCreatorContract.sanitize(
      text.to_s,
      exact_secrets: secrets.flatten.compact
    )
  end

  def secure_write(path, body)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(body) }
  end

  def find_executable(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      path = File.join(directory, name)
      return File.expand_path(path) if File.file?(path) && File.executable?(path)
    end
    nil
  end
end
