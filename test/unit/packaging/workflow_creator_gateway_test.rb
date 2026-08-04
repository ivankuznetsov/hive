require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../../../packaging/live_agent_skills/workflow_creator_gateway"

class WorkflowCreatorGatewayTest < Minitest::Test
  Creator = HiveLiveAgentProof::WorkflowCreator
  Gateway = HiveLiveAgentProof::WorkflowCreatorGateway
  Supervisor = Creator::ProcessSupervisor
  RUBY = File.realpath(RbConfig.ruby)
  CREATED_SLUG = "server-created-42"

  def setup
    skip "Linux process custody is required" unless RUBY_PLATFORM.include?("linux")
  end

  def test_real_wrapper_binds_the_dynamic_slug_and_retry_to_nine_frozen_receipts
    with_gateway do |gateway, wrapper, log, cwd, root|
      assert_private_gateway(root, wrapper)

      commands = Creator::Vocabulary.fetch("commands")
      commands.first(6).each { |argv| assert_wrapper(wrapper, argv) }
      assert_wrapper(wrapper, [ "run", CREATED_SLUG ])
      assert_wrapper(wrapper, commands.fetch(7))
      assert_wrapper(wrapper, commands.fetch(8))

      receipts = gateway.finish!
      assert_equal 9, receipts.length
      assert receipts.frozen?
      assert receipts.all?(&:frozen?)
      assert_equal [ "run", CREATED_SLUG ], receipts.fetch(6).fetch("argv")
      assert_equal commands.fetch(5), receipts.fetch(7).fetch("argv")
      assert_equal Creator::Vocabulary.fetch("command_labels"), receipts.map { |row| row.fetch("attempt_label") }
      assert receipts.all? { |row| row.fetch("capture").frozen? && !row.fetch("capture").key?("tails") }
      assert receipts.all? { |row| !row.dig("capture", "secret_scan").key?("findings") }

      launches = File.readlines(log, chomp: true).map { |line| JSON.parse(line) }
      assert_equal receipts.map { |row| row.fetch("argv") }, launches.map { |row| row.fetch("argv") }
      assert launches.all? { |row| row.fetch("cwd") == cwd }
      assert launches.all? { |row| row.fetch("environment") == { "FAKE_MODE" => "ok", "FAKE_STATE" => log } }
      refute File.exist?(File.join(root, ".workflow-creator-gateway.sock"))
      assert File.file?(wrapper)
    end
  end

  def test_wrong_order_and_duplicate_each_permanently_poison_the_gateway
    with_gateway do |gateway, wrapper|
      _out, _err, status = invoke(wrapper, Creator::Vocabulary.fetch("commands").fetch(1))
      refute status.success?
      assert_raises(Gateway::Error) { gateway.finish! }
    end

    with_gateway do |gateway, wrapper|
      assert_wrapper(wrapper, [ "version" ])
      _out, _err, status = invoke(wrapper, [ "version" ])
      refute status.success?
      assert_raises(Gateway::Error) { gateway.finish! }
    end
  end

  def test_candidate_failure_and_malformed_creation_each_permanently_poison
    with_gateway(mode: "failure") do |gateway, wrapper|
      Creator::Vocabulary.fetch("commands").first(3).each { |argv| assert_wrapper(wrapper, argv) }
      _out, err, status = invoke(wrapper, Creator::Vocabulary.fetch("commands").fetch(3))
      assert_equal 9, status.exitstatus
      assert_equal "candidate failure\n", err
      assert_raises(Gateway::Error) { gateway.finish! }
    end

    with_gateway(mode: "malformed") do |gateway, wrapper|
      Creator::Vocabulary.fetch("commands").first(5).each { |argv| assert_wrapper(wrapper, argv) }
      _out, _err, status = invoke(wrapper, Creator::Vocabulary.fetch("commands").fetch(5))
      refute status.success?
      assert_raises(Gateway::Error) { gateway.finish! }
    end
  end

  def test_credential_like_inherited_environment_poison_is_reported_without_launch
    with_gateway do |gateway, wrapper, log|
      _out, _err, status = invoke(wrapper, [ "version" ], "API_TOKEN" => "must-not-cross")

      refute status.success?
      refute File.exist?(log)
      assert_raises(Gateway::Error) { gateway.finish! }
    end
  end

  def test_an_extra_command_after_position_nine_poisons_the_completed_sequence
    with_gateway do |gateway, wrapper|
      run_all(wrapper)
      _out, _err, status = invoke(wrapper, [ "version" ])

      refute status.success?
      assert_raises(Gateway::Error) { gateway.finish! }
    end
  end

  def test_candidate_identity_is_fixed_and_preexisting_gateway_members_are_refused
    with_gateway do |gateway, wrapper, _log, _cwd, _root, candidate|
      moved = "#{candidate}.original"
      File.rename(candidate, moved)
      write_candidate(candidate)
      _out, _err, status = invoke(wrapper, [ "version" ])

      refute status.success?
      assert_raises(Gateway::Error) { gateway.finish! }
    end

    Dir.mktmpdir("creator-gateway-exclusive") do |dir|
      root, cwd = File.join(dir, "private"), File.join(dir, "cwd")
      [ root, cwd ].each { |path| Dir.mkdir(path, 0o700) }
      candidate = write_candidate(File.join(cwd, "candidate"))
      File.write(File.join(root, "workflow-creator-gateway"), "keep")
      gateway = build_gateway(root:, cwd:, candidate:, log: File.join(cwd, "log"))

      assert_raises(Gateway::Error) { gateway.start! }
      assert_equal "keep", File.read(File.join(root, "workflow-creator-gateway"))
    ensure
      gateway&.close
    end
  end

  private

  def with_gateway(mode: "ok")
    Dir.mktmpdir("creator-gateway") do |dir|
      root, cwd = File.join(dir, "private"), File.join(dir, "cwd")
      [ root, cwd ].each { |path| Dir.mkdir(path, 0o700) }
      candidate = write_candidate(File.join(cwd, "candidate"))
      log = File.join(cwd, "launches.jsonl")
      gateway = build_gateway(root:, cwd:, candidate:, log:, mode:)
      wrapper = gateway.start!
      yield gateway, wrapper, log, cwd, root, candidate
    ensure
      gateway&.close
    end
  end

  def build_gateway(root:, cwd:, candidate:, log:, mode: "ok")
    stat = File.lstat(candidate)
    identity = {
      "path" => File.basename(candidate), "sha256" => Digest::SHA256.file(candidate).hexdigest,
      "size" => stat.size
    }
    supervisor = Supervisor.new(
      correlation_id: "creator-gateway", output_limit: 8_192, tail_limit: 4_096,
      timeout: 1, term_grace: 0.05, kill_grace: 0.2
    )
    Gateway.new(
      root:, candidate_executable: candidate, candidate_identity: identity,
      environment: { "FAKE_MODE" => mode, "FAKE_STATE" => log }, cwd:, supervisor:
    )
  end

  def assert_private_gateway(root, wrapper)
    assert_equal 0o700, File.lstat(root).mode & 0o777
    assert_equal File.join(root, "workflow-creator-gateway"), wrapper
    assert_equal 0o600, File.lstat(wrapper).mode & 0o777
    socket = File.join(root, ".workflow-creator-gateway.sock")
    assert File.lstat(socket).socket?
    assert_equal 0o600, File.lstat(socket).mode & 0o777
    assert_equal [ ".workflow-creator-gateway.sock", "workflow-creator-gateway" ], Dir.children(root).sort
    assert_match(/\b[0-9a-f]{64}\b/, File.read(wrapper))
  end

  def assert_wrapper(wrapper, argv)
    _out, err, status = invoke(wrapper, argv)
    assert status.success?, "wrapper failed for #{argv.inspect}: #{err}"
  end

  def invoke(wrapper, argv, inherited = {})
    Open3.capture3(inherited, RUBY, wrapper, *argv, unsetenv_others: true)
  end

  def run_all(wrapper)
    commands = Creator::Vocabulary.fetch("commands")
    commands.first(6).each { |argv| assert_wrapper(wrapper, argv) }
    assert_wrapper(wrapper, [ "run", CREATED_SLUG ])
    assert_wrapper(wrapper, commands.fetch(7))
    assert_wrapper(wrapper, commands.fetch(8))
  end

  def write_candidate(path)
    File.write(path, <<~RUBY)
      #!#{RUBY}
      require "json"
      state = ENV.fetch("FAKE_STATE")
      mode = ENV.fetch("FAKE_MODE")
      record = { "argv" => ARGV, "cwd" => Dir.pwd, "environment" => ENV.to_h }
      File.open(state, "a", 0o600) { |file| file.puts(JSON.generate(record)) }
      case ARGV
      when ["version"] then puts "hive 1.0"
      when ["workflow", "list", "--json"] then puts JSON.generate("schema" => "hive-workflow-list")
      when ["workflow", "new", "editorial", "--json"] then puts JSON.generate("ok" => true)
      when ["workflow", "validate", "editorial", "--json"]
        if mode == "failure"
          warn "candidate failure"
          exit 9
        end
        puts JSON.generate("ok" => true)
      when ["workflow", "commit", "editorial"] then nil
      when #{Creator::Vocabulary.fetch("task_new_argv").inspect}
        if mode == "malformed"
          puts "not-json"
        else
          count_path = "\#{state}.count"
          count = File.exist?(count_path) ? Integer(File.read(count_path)) : 0
          File.write(count_path, (count + 1).to_s)
          puts JSON.generate("schema" => "hive-new", "ok" => true,
                             "created" => count.zero?, "slug" => #{CREATED_SLUG.inspect})
        end
      when ["run", #{CREATED_SLUG.inspect}] then puts "ran"
      when ["status", "--operational", "--json"] then puts JSON.generate("ok" => true)
      else
        warn "unexpected command"
        exit 90
      end
    RUBY
    File.chmod(0o700, path)
    path
  end
end
