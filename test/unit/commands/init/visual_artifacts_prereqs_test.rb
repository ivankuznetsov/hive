require "test_helper"
require "hive/commands/init/visual_artifacts_prereqs"

class VisualArtifactsPrereqsTest < Minitest::Test
  Status = Struct.new(:satisfied, :missing, keyword_init: true) do
    def to_h
      {
        ffmpeg: { present: !missing.include?("ffmpeg"), path: nil },
        asciinema: { present: !missing.include?("asciinema"), path: nil },
        missing: missing,
        satisfied: satisfied
      }
    end
  end

  class FakeReadiness
    attr_reader :calls

    def initialize(*statuses)
      @statuses = statuses
      @calls = 0
    end

    def capture_tooling_status
      @calls += 1
      (@statuses[@calls - 1] || @statuses.last).to_h
    end
  end

  class FakeInstaller
    attr_reader :installed_missing

    def initialize(package_manager:, result: :installed, command: "sudo pacman -S --needed --noconfirm ffmpeg asciinema")
      @package_manager = package_manager
      @result = result
      @command = command
      @installed_missing = []
    end

    def package_manager
      @package_manager
    end

    def install!(missing:)
      @installed_missing << missing
      @result
    end

    def command_for(missing:)
      "#{@command} #{missing.join(' ')}"
    end
  end

  class FakeScreenote
    attr_reader :runs

    def initialize
      @runs = 0
    end

    def run
      @runs += 1
    end
  end

  PackageManager = Struct.new(:name, keyword_init: true)

  def run_prereqs(input:, readiness:, installer:, screenote: FakeScreenote.new)
    stream = StringIO.new(input)
    output = StringIO.new
    prereqs = Hive::Commands::Init::VisualArtifactsPrereqs.new(
      input: stream,
      output: output,
      readiness: readiness,
      installer: installer,
      screenote: screenote
    )
    prereqs.run
    [ output.string, screenote ]
  end

  def test_tooling_satisfied_prints_ready_and_runs_screenote_without_prompt
    readiness = FakeReadiness.new(Status.new(satisfied: true, missing: []))
    installer = FakeInstaller.new(package_manager: nil)

    output, screenote = run_prereqs(input: "", readiness: readiness, installer: installer)

    assert_match(/visual capture tooling: ffmpeg ✓ asciinema ✓/, output)
    refute_match(/Enable visual capture tooling/, output)
    assert_equal 1, screenote.runs
    assert_empty installer.installed_missing
  end

  def test_missing_tooling_skip_does_not_install_and_does_not_offer_screenote
    readiness = FakeReadiness.new(Status.new(satisfied: false, missing: %w[asciinema]))
    installer = FakeInstaller.new(package_manager: PackageManager.new(name: :pacman))

    output, screenote = run_prereqs(input: "\n", readiness: readiness, installer: installer)

    assert_match(/Visual artifact capture is optional/, output)
    assert_match(/visual capture tooling: skipped/, output)
    assert_empty installer.installed_missing
    assert_equal 0, screenote.runs
  end

  def test_missing_tooling_accepts_package_manager_install_and_rechecks
    readiness = FakeReadiness.new(
      Status.new(satisfied: false, missing: %w[asciinema]),
      Status.new(satisfied: true, missing: [])
    )
    installer = FakeInstaller.new(package_manager: PackageManager.new(name: :pacman), result: :installed)

    output, screenote = run_prereqs(input: "y\n", readiness: readiness, installer: installer)

    assert_equal [ %w[asciinema] ], installer.installed_missing
    assert_equal 2, readiness.calls
    assert_match(/visual capture tooling: ffmpeg ✓ asciinema ✓/, output)
    assert_equal 1, screenote.runs
  end

  def test_missing_tooling_with_no_package_manager_prints_exact_command
    readiness = FakeReadiness.new(Status.new(satisfied: false, missing: %w[ffmpeg asciinema]))
    installer = FakeInstaller.new(package_manager: nil, command: "install-capture")

    output, screenote = run_prereqs(input: "y\n", readiness: readiness, installer: installer)

    assert_empty installer.installed_missing
    assert_match(/visual capture tooling: install manually/, output)
    assert_match(/install-capture ffmpeg asciinema/, output)
    assert_equal 0, screenote.runs
  end

  def test_failed_package_manager_install_prints_command_and_continues
    readiness = FakeReadiness.new(
      Status.new(satisfied: false, missing: %w[ffmpeg]),
      Status.new(satisfied: false, missing: %w[ffmpeg])
    )
    installer = FakeInstaller.new(
      package_manager: PackageManager.new(name: :apt),
      result: :failed,
      command: "sudo apt-get install -y"
    )

    output, screenote = run_prereqs(input: "yes\n", readiness: readiness, installer: installer)

    assert_equal [ %w[ffmpeg] ], installer.installed_missing
    assert_match(/install failed/, output)
    assert_match(/sudo apt-get install -y ffmpeg/, output)
    assert_match(/sudo apt-get update/, output)
    assert_equal 0, screenote.runs
  end
end
