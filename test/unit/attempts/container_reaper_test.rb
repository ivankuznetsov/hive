require "test_helper"
require "json"
require "timeout"
require "hive/attempts/container_reaper"

class AttemptsContainerReaperTest < Minitest::Test
  include HiveTestHelper

  ATTEMPT_ID = "attempt-1".freeze
  Command = Hive::Attempts::ContainerReaper::Command

  # Answers `podman ps` from a queue of container lists and records every argv.
  class FakePodman
    attr_reader :calls

    def initialize(listings, removal: Command.new(status: :ok, output: ""))
      @listings = listings
      @removal = removal
      @calls = []
    end

    def call(argv, timeout_sec)
      @calls << [ argv, timeout_sec ]
      case argv[1]
      when "ps"
        listing = @listings.shift
        listing.is_a?(Command) ? listing : Command.new(status: :ok, output: JSON.generate(listing))
      when "rm" then @removal
      else raise "unexpected podman verb #{argv[1]}"
      end
    end

    def verbs = @calls.map { |argv, _| argv[1] }
  end

  def container(id, name, image: "docker.io/library/postgres:16", state: "running")
    { "Id" => id, "Names" => [ name ], "Image" => image, "State" => state }
  end

  def reaper(runner, environment: {})
    Hive::Attempts::ContainerReaper.new(
      attempt_id: ATTEMPT_ID, podman: "podman", runner: runner, environment: environment
    )
  end

  def test_conf_appends_attempt_and_project_annotations
    conf = Hive::Attempts::ContainerReaper.conf_contents(attempt_id: ATTEMPT_ID, project: "to\"dero")

    assert_includes conf, "[containers]\n"
    assert_includes conf, 'annotations = ["hive.attempt=attempt-1", "hive.project=to\\"dero", {append=true}]'
  end

  def test_tag_writes_a_private_conf_and_returns_the_override_environment
    with_tmp_dir do |dir|
      tagging = reaper(FakePodman.new([])).tag(directory: dir, project: "todero")

      path = File.join(dir, "containers.conf")
      assert tagging.tagged?
      assert_equal({ "CONTAINERS_CONF_OVERRIDE" => path }, tagging.environment)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_includes File.read(path), '"hive.attempt=attempt-1"'
      assert_includes File.read(path), '"hive.project=todero"'
    end
  end

  def test_an_operator_override_is_kept_and_reported_untagged
    with_tmp_dir do |dir|
      subject = reaper(FakePodman.new([]), environment: { "CONTAINERS_CONF_OVERRIDE" => "/etc/operator.conf" })
      tagging = subject.tag(directory: dir, project: "todero")

      refute tagging.tagged?
      assert_empty tagging.environment
      refute File.exist?(File.join(dir, "containers.conf"))
      result = subject.untagged_result(tagging)
      assert result.notable?
      assert_includes result.journal_line, '"status":"untagged"'
      assert_includes result.journal_line, "operator_containers_conf_override"
    end
  end

  def test_an_unwritable_directory_leaves_the_attempt_untagged
    tagging = reaper(FakePodman.new([])).tag(directory: "/nonexistent/hive-container-reaper", project: "p")

    refute tagging.tagged?
    assert_empty tagging.environment
    assert_match(/\AErrno::/, tagging.error)
  end

  def test_reap_filters_by_this_attempt_and_removes_only_listed_containers
    podman = FakePodman.new([
      [ container("1e4b36e5d6d87a2bdb1e9d4c4cdc3278f66e84e7dc8bf517902f6c5479ced352", "todero-test-pg") ],
      []
    ])
    result = reaper(podman).reap(timeout_sec: 30, stop_timeout_sec: 30)

    assert_equal "reaped", result.status
    assert result.notable?
    ps_argv = podman.calls.first.first
    assert_equal [ "podman", "ps", "--all", "--filter", "annotation=hive.attempt=attempt-1", "--format", "json" ],
                 ps_argv
    rm_argv = podman.calls[1].first
    assert_equal [ "podman", "rm", "--force", "--volumes", "--time", "10",
                   "1e4b36e5d6d87a2bdb1e9d4c4cdc3278f66e84e7dc8bf517902f6c5479ced352" ], rm_argv
    assert_equal [ { "id" => "1e4b36e5d6d8", "name" => "todero-test-pg",
                     "image" => "docker.io/library/postgres:16", "state" => "running" } ], result.reaped
    assert_includes result.journal_line, "hive-attempt: attempt_containers {"
    assert_includes result.journal_line, '"annotation":"hive.attempt=attempt-1"'
  end

  def test_nothing_tagged_is_quiet_and_runs_no_removal
    podman = FakePodman.new([ [] ])
    result = reaper(podman).reap

    assert_equal "clean", result.status
    refute result.notable?
    assert_equal [ "ps" ], podman.verbs
  end

  def test_missing_podman_is_quiet
    podman = FakePodman.new([ Command.new(status: :missing, output: "") ])
    result = reaper(podman).reap

    assert_equal "no_podman", result.status
    refute result.notable?
  end

  def test_podman_failures_and_timeouts_become_results_not_exceptions
    failed = reaper(FakePodman.new([ Command.new(status: :failed, output: "Error: database is locked\n") ])).reap
    assert_equal "failed", failed.status
    assert_includes failed.error, "database is locked"

    timed_out = reaper(FakePodman.new([ Command.new(status: :timeout, output: "") ])).reap
    assert_equal "failed", timed_out.status
    assert_includes timed_out.error, "timeout"

    garbage = reaper(FakePodman.new([ Command.new(status: :ok, output: "{not json") ])).reap
    assert_equal "failed", garbage.status

    raising = ->(*) { raise IOError, "pipe closed" }
    assert_equal "failed", reaper(raising).reap.status
  end

  def test_containers_that_survive_removal_are_reported_incomplete
    stuck = container("a" * 64, "stuck")
    podman = FakePodman.new(
      [ [ container("b" * 64, "gone"), stuck ], [ stuck ] ],
      removal: Command.new(status: :failed, output: "Error: cannot remove infra container\n")
    )
    result = reaper(podman).reap

    assert_equal "incomplete", result.status
    assert_equal [ "gone" ], result.reaped.map { |entry| entry.fetch("name") }
    assert_equal [ "stuck" ], result.survivors.map { |entry| entry.fetch("name") }
    assert_includes result.error, "cannot remove infra container"
  end

  def test_stop_timeout_is_clamped_and_all_calls_share_one_deadline
    clock = [ 100.0 ]
    podman = FakePodman.new([ [ container("c" * 64, "pg") ], [] ])
    runner = lambda do |argv, timeout|
      clock[0] += 4
      podman.call(argv, timeout)
    end
    subject = Hive::Attempts::ContainerReaper.new(
      attempt_id: ATTEMPT_ID, podman: "podman", runner: runner, environment: {}, monotonic: -> { clock[0] }
    )

    assert_equal "reaped", subject.reap(timeout_sec: 10, stop_timeout_sec: 0.4).status
    assert_equal [ 10.0, 6.0, 2.0 ], podman.calls.map(&:last)
    rm_argv = podman.calls[1].first
    assert_equal "0", rm_argv[rm_argv.index("--time") + 1]
  end

  def test_the_real_runner_kills_a_hung_podman_at_the_deadline
    with_tmp_dir do |dir|
      podman = File.join(dir, "podman")
      File.write(podman, "#!/bin/sh\nexec sleep 30\n")
      File.chmod(0o755, podman)
      subject = Hive::Attempts::ContainerReaper.new(attempt_id: ATTEMPT_ID, podman: podman, environment: {})

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Timeout.timeout(10) { subject.reap(timeout_sec: 0.3) }

      assert_equal "failed", result.status
      assert_includes result.error, "timeout"
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end
  end

  def test_a_failed_relisting_reports_every_listed_container_as_a_survivor
    podman = FakePodman.new([
      [ container("e" * 64, "pg") ],
      Command.new(status: :failed, output: "Error: storage locked\n")
    ])
    result = reaper(podman).reap

    assert_equal "incomplete", result.status
    assert_equal [ "pg" ], result.survivors.map { |entry| entry.fetch("name") }
    assert_includes result.error, "storage locked"
  end

  def test_the_real_runner_lists_and_removes_through_a_podman_executable
    with_tmp_dir do |dir|
      removed = File.join(dir, "removed")
      log = File.join(dir, "argv.log")
      listing = JSON.generate([ container("f" * 64, "todero-test-db") ])
      podman = File.join(dir, "podman")
      File.write(podman, <<~SH)
        #!/bin/sh
        echo "$*" >> '#{log}'
        case "$1" in
          ps) if [ -f '#{removed}' ]; then echo '[]'; else echo '#{listing}'; fi ;;
          rm) touch '#{removed}' ;;
        esac
      SH
      File.chmod(0o755, podman)
      subject = Hive::Attempts::ContainerReaper.new(attempt_id: ATTEMPT_ID, podman: podman, environment: {})

      result = Timeout.timeout(10) { subject.reap(timeout_sec: 5, stop_timeout_sec: 1) }

      assert_equal "reaped", result.status
      assert_equal [ "todero-test-db" ], result.reaped.map { |entry| entry.fetch("name") }
      calls = File.readlines(log, chomp: true)
      assert_equal "ps --all --filter annotation=hive.attempt=attempt-1 --format json", calls.first
      assert_equal "rm --force --volumes --time 1 #{"f" * 64}", calls[1]
    end
  end

  def test_the_real_runner_kills_a_podman_that_ignores_term
    with_tmp_dir do |dir|
      podman = File.join(dir, "podman")
      File.write(podman, "#!/bin/sh\ntrap '' TERM\nexec sleep 30\n")
      File.chmod(0o755, podman)
      subject = Hive::Attempts::ContainerReaper.new(attempt_id: ATTEMPT_ID, podman: podman, environment: {})

      result = Timeout.timeout(10) { subject.reap(timeout_sec: 0.2) }

      assert_equal "failed", result.status
      assert_includes result.error, "timeout"
    end
  end

  def test_terminating_an_already_reaped_podman_is_harmless
    pid = Process.spawn("true", pgroup: true)
    Process.wait(pid)
    subject = Hive::Attempts::ContainerReaper.new(attempt_id: ATTEMPT_ID, environment: {})

    assert_nil subject.send(:terminate, pid)
  end

  def test_the_real_runner_reports_a_missing_binary
    subject = Hive::Attempts::ContainerReaper.new(
      attempt_id: ATTEMPT_ID, podman: "/nonexistent/hive-podman", environment: {}
    )

    assert_equal "no_podman", subject.reap(timeout_sec: 5).status
  end
end
