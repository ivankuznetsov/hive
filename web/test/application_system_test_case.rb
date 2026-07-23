require "test_helper"
require "capybara-playwright-driver"

# The composer labels its controls via aria-label (placeholder-only inputs
# fail screen readers); Capybara must match them the way assistive tech does.
Capybara.enable_aria_label = true

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :playwright, options: {
    browser_type: :chromium,
    headless: true
  }

  setup do
    reset_system_test_projects!
  end

  # Sign in through the env-gated dev seam (never drawn in production) and
  # land on the status grid.
  def sign_in!(login: "alice")
    configure_owner!(owner: login)
    visit "/dev_login?as=#{login}"
    assert_selector ".topbar-session", text: login,
                    wait: 5
  end

  # owner: "" writes a CLAIMABLE instance (the key is omitted — the config
  # validator rejects empty strings; claimable means absent).
  def configure_owner!(owner: "alice")
    path = File.join(ENV["HIVE_HOME"], "config.yml")
    data = File.exist?(path) ? YAML.safe_load_file(path) : {}
    data ||= {}
    github = { "client_id" => "client" }
    github["owner"] = owner unless owner.to_s.strip.empty?
    data["web"] = { "origin" => "http://127.0.0.1", "github" => github }
    File.write(path, data.to_yaml)
  end

  def wait_for_live_status
    assert_selector "#status-stream-source[connected]", visible: :all, wait: 15
    Timeout.timeout(15) do
      sleep 0.01 until StatusBroadcaster.instance_variable_get(:@subscriber_count).to_i == 1
    end
  end

  private

  # System tests share one process, but product state must not leak between
  # examples. Besides making assertions order-dependent, a cumulative fleet
  # made every later status refresh scan dozens of unrelated fixture tasks.
  def reset_system_test_projects!
    StatusBroadcaster.stop!
    StatusBroadcaster.feed = nil

    sandbox = File.expand_path(ENV.fetch("HIVE_TEST_HOME_ROOT"))
    unless File.basename(sandbox).start_with?("hive-web-test")
      raise "refusing to reset a non-test Hive sandbox: #{sandbox}"
    end

    FileUtils.rm_rf(File.join(sandbox, "repos"))
    Hive::Config.update_global_config! do |config|
      config["registered_projects"] = []
    end
    Hive::Workflows::Project.reset!
  end
end
