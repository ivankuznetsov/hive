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

  # Sign in through the env-gated dev seam (never drawn in production) and
  # land on the status grid.
  def sign_in!(login: "alice")
    configure_owner!(owner: login)
    visit "/dev_login?as=#{login}"
    assert_selector ".topbar-session", text: login,
                    wait: 5
  end

  # owner: "" writes a CLAIMABLE box (the key is omitted — the config
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
end
