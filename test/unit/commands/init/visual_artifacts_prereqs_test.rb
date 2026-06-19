require "test_helper"
require "hive/commands/init/visual_artifacts_prereqs"
require "hive/screenote_uploader"

class VisualArtifactsPrereqsTest < Minitest::Test
  include HiveTestHelper

  Response = Struct.new(:code, :body, keyword_init: true)

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

  class FakeScreenoteReadiness
    def initialize(status)
      @status = status
    end

    def screenote_status
      @status
    end
  end

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

  def run_screenote_connector(input:, readiness:, http: ->(*) { Response.new(code: "200", body: "{}") },
                              opener: ->(_url) { false })
    stream = StringIO.new(input)
    output = StringIO.new
    connector = Hive::Commands::Init::VisualArtifactsPrereqs::ScreenoteConnector.new(
      input: stream,
      output: output,
      readiness: readiness,
      http: http,
      opener: opener
    )
    connector.run
    output.string
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

  def test_screenote_already_connected_skips_prompt
    readiness = FakeScreenoteReadiness.new(connected: true, base_url: "https://screenote.test", reason: nil)
    called = false

    output = run_screenote_connector(
      input: "",
      readiness: readiness,
      http: ->(*) {
        called = true
        Response.new(code: "200", body: "{}")
      }
    )

    assert_match(/screenote: connected ✓/, output)
    refute_match(/Connect screenote now/, output)
    assert_equal false, called
  end

  def test_screenote_skip_does_not_write_global_config
    with_tmp_global_config do |home|
      readiness = FakeScreenoteReadiness.new(connected: false, base_url: nil, reason: "missing")

      output = run_screenote_connector(input: "\n", readiness: readiness)

      assert_match(/screenote: skipped/, output)
      cfg = YAML.safe_load(File.read(File.join(home, "config.yml")))
      refute cfg.key?("screenote")
    end
  end

  def test_screenote_accept_valid_token_persists_global_only_and_round_trips
    with_tmp_global_config do |home|
      with_tmp_dir do |project|
        FileUtils.mkdir_p(File.join(project, ".hive-state"))
        project_config = File.join(project, ".hive-state", "config.yml")
        File.write(project_config, { "project_name" => "demo" }.to_yaml)

        seen = {}
        readiness = FakeScreenoteReadiness.new(connected: false, base_url: nil, reason: "missing")
        output = run_screenote_connector(
          input: "y\n\nsecret-token\n",
          readiness: readiness,
          http: ->(uri, request, open_timeout:, read_timeout:) {
            seen[:uri] = uri
            seen[:authorization] = request["Authorization"]
            seen[:open_timeout] = open_timeout
            seen[:read_timeout] = read_timeout
            Response.new(code: "200", body: "{}")
          }
        )

        global = YAML.safe_load(File.read(File.join(home, "config.yml")))
        assert_equal "https://screenote.ai", global.dig("screenote", "base_url")
        assert_equal "secret-token", global.dig("screenote", "api_token")
        assert_nil YAML.safe_load(File.read(project_config))["screenote"]
        assert_equal URI("https://screenote.ai/api/v1/screenshots"), seen[:uri]
        assert_equal "Bearer secret-token", seen[:authorization]
        assert_equal Hive::Commands::Init::VisualArtifactsPrereqs::ScreenoteConnector::OPEN_TIMEOUT,
                     seen[:open_timeout]
        assert_equal Hive::Commands::Init::VisualArtifactsPrereqs::ScreenoteConnector::READ_TIMEOUT,
                     seen[:read_timeout]
        assert_match(/saved credentials to #{Regexp.escape(File.join(home, "config.yml"))}/, output)
        refute_includes output, "secret-token"

        cfg = Hive::Config.load_global_screenote
        assert_equal "https://screenote.ai", cfg["base_url"]
        assert_equal "secret-token", cfg["api_token"]
        assert Hive::ScreenoteUploader.new(base_url: cfg["base_url"], api_token: cfg["api_token"]).configured?
      end
    end
  end

  def test_screenote_invalid_token_reprompts_once_then_skips
    with_tmp_global_config do |home|
      readiness = FakeScreenoteReadiness.new(connected: false, base_url: nil, reason: "missing")
      attempts = 0

      output = run_screenote_connector(
        input: "y\nhttps://screenote.test\nbad-token\nstill-bad\n",
        readiness: readiness,
        http: ->(*) {
          attempts += 1
          Response.new(code: "401", body: "{}")
        }
      )

      assert_equal 2, attempts
      assert_match(/token validation failed \(HTTP 401\).*once more/m, output)
      assert_match(/token validation failed \(HTTP 401\); skipped/, output)
      refute_includes output, "bad-token"
      refute_includes output, "still-bad"
      cfg = YAML.safe_load(File.read(File.join(home, "config.yml")))
      refute cfg.key?("screenote")
    end
  end
end
