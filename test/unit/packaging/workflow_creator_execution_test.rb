require "test_helper"
require "digest"
require "json"
require "rubygems/package"
require "stringio"
require "zlib"
require_relative "../../../packaging/live_agent_skills/workflow_creator_execution"

class WorkflowCreatorExecutionTest < Minitest::Test
  include HiveTestHelper

  Creator = HiveLiveAgentProof::WorkflowCreator
  Execution = HiveLiveAgentProof::WorkflowCreatorExecution
  SHA = "a" * 40
  SLUG = "created-editorial-42"

  def setup
    skip "Linux process custody is required" unless RUBY_PLATFORM.include?("linux")
  end

  def test_real_outer_processes_interleave_gateway_commands_and_publish_support_last
    with_fixture do |fixture|
      primary_path = File.join(fixture.fetch(:bundle_directory), "openclaw-workflow-creator.json")
      session = start_session(fixture)

      session.run_outer_workflow_creator(
        argv: [ "creator" ], environment: outer_environment(session, fixture),
        stdin_data: Creator::Vocabulary.fetch("prompt")
      )
      session.run_outer_authorized_work(
        argv: [ "work" ], environment: outer_environment(session, fixture),
        stdin_data: Creator::Vocabulary.fetch("task_prompt")
      )
      fixture_pids = File.readlines(fixture.fetch(:outer_pids), chomp: true).map { |value| Integer(value) }
      observation = file_record(fixture.fetch(:workspace_path), Creator::Vocabulary.fetch("executed_instruction"))
      draft = session.draft!(executed_instruction: observation)

      assert_equal %i[receipt_bytes receipt_sha256 receipt_size], draft.members
      assert_equal Digest::SHA256.hexdigest(draft.receipt_bytes), draft.receipt_sha256
      assert_equal draft.receipt_bytes.bytesize, draft.receipt_size
      refute File.exist?(primary_path)
      refute Dir.exist?(fixture.fetch(:workspace_path))
      assert fixture_pids.none? { |pid| process_alive?(pid) }
      refute File.exist?(File.join(fixture.dig(:candidate, "root"), "audit", ".workflow-creator-gateway.sock"))

      receipt = JSON.parse(draft.receipt_bytes)
      candidate_record, openclaw_record = receipt.fetch("installed_manifests")
      primary = primary_row(fixture, draft, observation, candidate_record, openclaw_record)
      primary_bytes = publish_primary(fixture, primary)
      result = session.finish!(primary_row: primary)

      assert_equal "passed", result.status
      assert_equal primary_bytes, File.binread(primary_path)
      members = Dir.children(fixture.fetch(:bundle_directory)).sort_by do |name|
        Creator::Vocabulary.fetch("bundle_files").index(name)
      end
      assert_equal Creator::Vocabulary.fetch("bundle_files"), members
      assert_equal draft.receipt_bytes,
                   File.binread(File.join(fixture.fetch(:bundle_directory), "execution-receipt.json"))
      assert_equal Creator::ProcessSupervisor::LABELS, receipt.dig("teardown", "receipt_labels")
      assert_equal Creator::ProcessSupervisor::LABELS, receipt.dig("run", "expected_labels")
      assert_equal SLUG, receipt.dig("task_slug_binding", "value")
      assert_equal receipt.dig("gateway", "identity"),
                   JSON.parse(File.binread(File.join(fixture.fetch(:bundle_directory),
                                                     "candidate-installed-manifest.json")))
                     .dig("required_roles", "audit_gateway")
      assert_equal "passed", session.finish!(primary_row: primary).status

      File.binwrite(File.join(fixture.fetch(:bundle_directory), "candidate-installed-manifest.json"), "divergent")
      assert_raises(Execution::Error) { session.finish!(primary_row: primary) }
      assert_equal "failed", session.result.status
    ensure
      session&.close
    end
  end

  def test_invalid_instruction_and_primary_digest_fail_before_publication
    with_fixture do |fixture|
      session, observation = execute_outer(fixture)
      invalid = observation.merge("sha256" => "0" * 64)

      assert_raises(Execution::Error) { session.draft!(executed_instruction: invalid) }
      assert_empty Dir.children(fixture.fetch(:bundle_directory))
      assert_equal "failed", session.result.status
      refute Dir.exist?(fixture.fetch(:workspace_path))
    ensure
      session&.close
    end

    with_fixture do |fixture|
      session, observation = execute_outer(fixture)
      draft = session.draft!(executed_instruction: observation)
      receipt = JSON.parse(draft.receipt_bytes)
      primary = primary_row(fixture, draft, observation, *receipt.fetch("installed_manifests"))
      invalid = JSON.parse(JSON.generate(primary))
      invalid.fetch("evidence_bundle").fetch(2)["sha256"] = "0" * 64

      assert_raises(Execution::Error) { session.finish!(primary_row: invalid) }
      assert_empty Dir.children(fixture.fetch(:bundle_directory))
      assert_equal "failed", session.result.status
      assert_raises(Execution::Error) { session.finish!(primary_row: primary) }
      assert_equal Creator::Vocabulary.fetch("bundle_files").drop(1).sort,
                   Dir.children(fixture.fetch(:bundle_directory)).sort
      publish_primary(fixture, primary)
      assert_equal "passed", session.finish!(primary_row: primary).status
      assert_equal "passed", session.finish!(primary_row: primary).status
    ensure
      session&.close
    end
  end

  def test_owned_paths_must_not_overlap
    with_fixture do |fixture|
      overlapping = fixture.merge(bundle_directory: fixture.dig(:candidate, "root"))

      assert_raises(Execution::Error) { start_session(overlapping) }
      refute Dir.exist?(fixture.fetch(:workspace_path))
    end
  end

  def test_gateway_destination_must_stay_inside_the_candidate_closure
    with_fixture do |fixture|
      escaped = fixture.merge(
        candidate: fixture.fetch(:candidate).merge(
          "audit_gateway" => File.join(fixture.fetch(:bundle_directory), "workflow-creator-gateway")
        )
      )

      assert_raises(Execution::Error) { start_session(escaped) }
      assert_empty Dir.children(fixture.fetch(:bundle_directory))
      refute Dir.exist?(fixture.fetch(:workspace_path))
    end
  end

  def test_outer_prompts_and_installed_closures_are_launch_bound
    with_fixture do |fixture|
      session = start_session(fixture)
      assert_raises(Execution::Error) do
        session.run_outer_workflow_creator(
          argv: [ "creator" ], environment: outer_environment(session, fixture)
        )
      end
      refute File.exist?(fixture.fetch(:outer_pids))
    ensure
      session&.close
    end

    with_fixture do |fixture|
      session, observation = execute_outer(fixture)
      File.binwrite(fixture.dig(:openclaw, "lock"), "drifted-lock\n")

      assert_raises(Execution::Error) { session.draft!(executed_instruction: observation) }
      assert_empty Dir.children(fixture.fetch(:bundle_directory))
    ensure
      session&.close
    end
  end

  def test_rejected_duplicate_outer_launch_cannot_rewrite_evidence
    with_fixture do |fixture|
      session, observation = execute_outer(fixture)

      assert_raises(Execution::Error) do
        session.run_outer_workflow_creator(
          argv: [ "different" ], environment: outer_environment(session, fixture),
          stdin_data: Creator::Vocabulary.fetch("prompt")
        )
      end
      assert_raises(Execution::Error) { session.draft!(executed_instruction: observation) }
      assert_empty Dir.children(fixture.fetch(:bundle_directory))
    ensure
      session&.close
    end
  end

  def test_partial_publication_converges_and_partial_or_failed_outer_runs_cannot_draft
    with_fixture do |fixture|
      session, observation = execute_outer(fixture)
      draft = session.draft!(executed_instruction: observation)
      receipt = JSON.parse(draft.receipt_bytes)
      primary = primary_row(fixture, draft, observation, *receipt.fetch("installed_manifests"))
      publish_primary(fixture, primary)
      blocker = File.join(fixture.fetch(:bundle_directory), "openclaw-installed-manifest.json")
      Dir.mkdir(blocker, 0o700)

      assert_raises(Execution::Error) { session.finish!(primary_row: primary) }
      assert File.file?(File.join(fixture.fetch(:bundle_directory), "candidate-installed-manifest.json"))
      refute File.exist?(File.join(fixture.fetch(:bundle_directory), "execution-receipt.json"))
      Dir.rmdir(blocker)
      assert_equal "passed", session.finish!(primary_row: primary).status
    ensure
      session&.close
    end


    with_fixture do |fixture|
      primary_path = File.join(fixture.fetch(:bundle_directory), "openclaw-workflow-creator.json")
      support = File.join(fixture.fetch(:bundle_directory), "candidate-installed-manifest.json")
      File.binwrite(support, "divergent")
      File.chmod(0o600, support)
      session, observation = execute_outer(fixture)
      draft = session.draft!(executed_instruction: observation)
      receipt = JSON.parse(draft.receipt_bytes)
      primary = primary_row(fixture, draft, observation, *receipt.fetch("installed_manifests"))
      primary_bytes = publish_primary(fixture, primary)

      assert_raises(Execution::Error) { session.finish!(primary_row: primary) }
      assert_equal primary_bytes, File.binread(primary_path)
      refute File.exist?(File.join(fixture.fetch(:bundle_directory), "execution-receipt.json"))
      assert_equal "divergent", File.binread(support)
    ensure
      session&.close
    end

    with_fixture do |fixture|
      session = start_session(fixture)
      session.run_outer_workflow_creator(
        argv: [ "creator" ], environment: outer_environment(session, fixture),
        stdin_data: Creator::Vocabulary.fetch("prompt")
      )
      assert_raises(Execution::Error) { session.draft!(executed_instruction: {}) }
      assert_empty Dir.children(fixture.fetch(:bundle_directory))
      assert_equal "failed", session.result.status
    ensure
      session&.close
    end

    %w[failed signaled].each do |outcome|
      with_fixture do |fixture|
        session, observation = execute_outer(fixture, outcome:)
        assert_raises(Execution::Error, outcome) { session.draft!(executed_instruction: observation) }
        assert_empty Dir.children(fixture.fetch(:bundle_directory)), outcome
        assert_equal "failed", session.result.status
      ensure
        session&.close
      end
    end
  end

  private

  def start_session(fixture)
    Execution.start!(
      candidate_sha: SHA, manifest: fixture.fetch(:manifest), candidate: fixture.fetch(:candidate),
      openclaw: fixture.fetch(:openclaw), archives: fixture.fetch(:archives),
      workspace_path: fixture.fetch(:workspace_path), bundle_directory: fixture.fetch(:bundle_directory),
      correlation_id: "creator-execution", exact_secrets: [],
      supervisor_options: { "timeout" => 2, "term_grace" => 0.05, "kill_grace" => 0.2 }
    )
  end

  def execute_outer(fixture, outcome: "passed")
    session = start_session(fixture)
    session.run_outer_workflow_creator(
      argv: [ "creator" ], environment: outer_environment(session, fixture),
      stdin_data: Creator::Vocabulary.fetch("prompt")
    )
    session.run_outer_authorized_work(
      argv: [ "work" ], environment: outer_environment(session, fixture, outcome:),
      stdin_data: Creator::Vocabulary.fetch("task_prompt")
    )
    observation = file_record(fixture.fetch(:workspace_path), Creator::Vocabulary.fetch("executed_instruction"))
    [ session, observation ]
  end

  def outer_environment(session, fixture, outcome: "passed")
    { "GATEWAY" => session.gateway_path, "FIXTURE_RUBY" => fixture.fetch(:ruby),
      "OUTER_PIDS" => fixture.fetch(:outer_pids), "OUTER_RESULT" => outcome }
  end

  def with_fixture
    with_tmp_dir do |root|
      candidate_root = File.join(root, "candidate")
      openclaw_root = File.join(root, "openclaw")
      bundle_directory = File.join(root, "bundle")
      [ candidate_root, openclaw_root, bundle_directory ].each { |path| Dir.mkdir(path, 0o700) }
      ruby = File.realpath(RbConfig.ruby).encode(Encoding::UTF_8)
      candidate_package = File.join(candidate_root, "packages", "hive-cli.gem")
      openclaw_package = File.join(openclaw_root, "packages", "openclaw.tar.gz")
      candidate_executable = File.join(candidate_root, "bin", "hive")
      openclaw_executable = File.join(openclaw_root, "bin", "openclaw")
      workspace_path = File.join(root, "proof-workspace")
      outer_pids = File.join(workspace_path, "outer-pids")
      write_candidate(candidate_executable, ruby)
      write_outer(openclaw_executable, ruby)
      write_candidate_archive(candidate_package)
      write_archive(openclaw_package)
      candidate = installation_fixture(
        candidate_root, candidate_executable, candidate_package, candidate: true,
        state_path: File.join(workspace_path, "command-count")
      )
      openclaw = installation_fixture(openclaw_root, openclaw_executable, openclaw_package, candidate: false)
      manifest = artifact_manifest(File.binread(candidate_package))
      archives = {
        "candidate-package" => archive_fixture(candidate_package),
        "openclaw-package" => archive_fixture(openclaw_package)
      }
      yield root:, ruby:, candidate:, openclaw:, manifest:, archives:,
            workspace_path:, bundle_directory:, outer_pids:
    end
  end

  def installation_fixture(root, executable, package, candidate:, state_path: nil)
    paths = {
      "executable" => executable, "interpreter_or_launcher" => write_member(root, "runtime/ruby"),
      "lock" => write_member(root, "lock/package.lock"), "package" => package
    }
    paths["audit_gateway"] = File.join(root, "audit", "workflow-creator-gateway") if candidate
    Dir.mkdir(File.join(root, "audit"), 0o700) if candidate
    inventory = paths.values.map { |path| path.delete_prefix("#{root}/") }
    paths.merge(
      "root" => root, "inventory" => inventory.sort,
      "environment" => { "FAKE_STATE" => state_path },
      "version" => "openclaw-2026.8.4"
    ).tap do |fixture|
      fixture.delete("environment") unless candidate
      fixture.delete("version") if candidate
    end
  end

  def write_member(root, relative)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.binwrite(path, "fixture:#{relative}\n")
    path
  end

  def write_candidate(path, ruby)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.binwrite(path, <<~RUBY)
      #!#{ruby}
      require "fileutils"
      require "json"
      count_path = ENV.fetch("FAKE_STATE")
      case ARGV
      when ["version"] then puts "hive 1.0"
      when ["workflow", "list", "--json"] then puts JSON.generate("schema" => "hive-workflow-list")
      when ["workflow", "new", "editorial", "--json"] then puts JSON.generate("ok" => true)
      when ["workflow", "validate", "editorial", "--json"] then puts JSON.generate("ok" => true)
      when ["workflow", "commit", "editorial"]
        #{Creator::Vocabulary.fetch("files").inspect}.each do |relative|
          FileUtils.mkdir_p(File.dirname(relative), mode: 0o700)
          File.binwrite(relative, "authored:\#{relative}\n")
        end
      when #{Creator::Vocabulary.fetch("task_new_argv").inspect}
        count = File.exist?(count_path) ? Integer(File.binread(count_path)) : 0
        File.binwrite(count_path, (count + 1).to_s)
        puts JSON.generate("schema" => "hive-new", "ok" => true,
                           "created" => count.zero?, "slug" => #{SLUG.inspect})
      when ["run", #{SLUG.inspect}] then puts "ran"
      when ["status", "--operational", "--json"] then puts JSON.generate("ok" => true)
      else exit 90
      end
    RUBY
    File.chmod(0o700, path)
  end

  def write_outer(path, ruby)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    commands = Creator::Vocabulary.fetch("commands")
    File.binwrite(path, <<~RUBY)
      #!#{ruby}
      wrapper, ruby = ENV.values_at("GATEWAY", "FIXTURE_RUBY")
      File.open(ENV.fetch("OUTER_PIDS"), "a", 0o600) { |file| file.puts(Process.pid) }
      commands = #{commands.inspect}
      commands[6] = ["run", #{SLUG.inspect}]
      selected = ARGV == ["creator"] ? commands.first(5) : commands.drop(5)
      selected.each { |argv| exit 91 unless system(ruby, wrapper, *argv) }
      exit 7 if ARGV == ["work"] && ENV["OUTER_RESULT"] == "failed"
      Process.kill("TERM", Process.pid) if ARGV == ["work"] && ENV["OUTER_RESULT"] == "signaled"
    RUBY
    File.chmod(0o700, path)
  end

  def write_candidate_archive(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    nested = gzip_tar_bytes do |tar|
      bytes = "candidate\n"
      tar.add_file_simple("lib/candidate.rb", 0o644, bytes.bytesize) { |io| io.write(bytes) }
    end
    File.open(path, "wb") do |file|
      Gem::Package::TarWriter.new(file) do |tar|
        { "metadata.gz" => gzip_bytes("metadata"), "data.tar.gz" => nested,
          "checksums.yaml.gz" => gzip_bytes("checksums") }.each do |name, bytes|
          tar.add_file_simple(name, 0o644, bytes.bytesize) { |entry| entry.write(bytes) }
        end
      end
    end
  end

  def write_archive(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        bytes = "openclaw\n"
        tar.add_file_simple("bin/openclaw", 0o755, bytes.bytesize) { |io| io.write(bytes) }
      end
    end
  end

  def gzip_tar_bytes
    io = StringIO.new("".b)
    gzip = Zlib::GzipWriter.new(io)
    Gem::Package::TarWriter.new(gzip) { |tar| yield tar }
    gzip.finish
    io.string
  end

  def gzip_bytes(bytes)
    io = StringIO.new("".b)
    gzip = Zlib::GzipWriter.new(io)
    gzip.write(bytes)
    gzip.finish
    io.string
  end

  def archive_fixture(path)
    { "path" => path, "available_bytes" => 1_000_000, "available_entries" => 100 }
  end

  def artifact_manifest(candidate_package)
    version = "1.2.3"
    names = [ "hive-agent-skills-#{SHA}.tar.gz", "hive-cli-#{version}.gem", "hive-source-#{SHA}.tar.gz" ]
    files = names.to_h do |name|
      bytes = name.start_with?("hive-cli-") ? candidate_package : "artifact:#{name}"
      [ name, { "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize } ]
    end
    {
      "schema" => "hive-live-agent-candidate-artifacts", "schema_version" => 1,
      "candidate_sha" => SHA, "hive_version" => version, "skill_version" => "2026.8.4",
      "canonical_digest" => Digest::SHA256.hexdigest("canonical"), "files" => files
    }
  end

  def file_record(root, relative)
    path = File.join(root, relative)
    { "path" => relative, "sha256" => Digest::SHA256.file(path).hexdigest, "size" => File.size(path) }
  end

  def publish_primary(fixture, primary)
    bytes = Creator::Values.capture(primary).canonical_bytes
    path = File.join(fixture.fetch(:bundle_directory), "openclaw-workflow-creator.json")
    File.binwrite(path, bytes)
    File.chmod(0o600, path)
    bytes
  end

  def primary_row(fixture, draft, observation, candidate_record, openclaw_record)
    files = Creator::Vocabulary.fetch("files").map { |path| file_record_from_content(path) }
    files[2] = observation
    receipt_record = {
      "kind" => "execution_receipt", "path" => "execution-receipt.json",
      "sha256" => draft.receipt_sha256, "size" => draft.receipt_size
    }
    summary = { "status" => "passed", "receipt_sha256" => draft.receipt_sha256 }
    {
      "schema" => Creator::Vocabulary.fetch("evidence_schema"), "schema_version" => 1,
      "platform" => "openclaw", "candidate_sha" => SHA, "result" => "passed",
      "prompt_sha256" => Digest::SHA256.hexdigest(Creator::Vocabulary.fetch("prompt")),
      "task_prompt_sha256" => Digest::SHA256.hexdigest(Creator::Vocabulary.fetch("task_prompt")),
      "skill" => fixture.fetch(:manifest).slice("skill_version", "canonical_digest"),
      "native_activation" => Creator::Vocabulary.fetch("native_activation"),
      "hive_commands" => Creator.commands_for(task_slug: SLUG).value,
      "created_files" => files, "validation" => Creator::Vocabulary.fetch("graph"),
      "creation_only_task_count" => 0, "task_count" => 1,
      "task" => Creator::Vocabulary.fetch("task").merge("slug" => SLUG), "external_actions" => [],
      "secret_scan" => { "status" => "passed", "scanner" => Creator::Vocabulary.fetch("scanner") },
      "execution_kind" => "authenticated_openclaw", "model_loop" => "executed",
      "executed_instruction" => observation,
      "evidence_bundle" => [ candidate_record, openclaw_record, receipt_record ],
      "containment" => summary, "teardown" => summary, "cleanup" => summary
    }
  end

  def file_record_from_content(path)
    bytes = "authored:#{path}\n"
    { "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
