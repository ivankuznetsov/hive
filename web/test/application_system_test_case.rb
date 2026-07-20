require "test_helper"
require "capybara-playwright-driver"
require "axe/configuration"

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

  def assert_no_serious_accessibility_violations
    page.execute_script(Axe::Configuration.instance.jslib)
    results = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      axe.run(document, { resultTypes: ["violations"] })
        .then(done)
        .catch((error) => done({ error: error.message, violations: [] }))
    JS
    assert_nil results["error"], "axe-core failed: #{results['error']}"

    violations = results.fetch("violations").select { |violation| %w[serious critical].include?(violation["impact"]) }
    message = violations.flat_map do |violation|
      violation.fetch("nodes").map do |node|
        "#{violation['id']} (#{violation['impact']}) at #{Array(node['target']).join(', ')}: #{violation['help']}"
      end
    end.join("\n")
    assert_empty violations, "serious accessibility violations:\n#{message}"
  end

  def emulate_reduced_motion!(reduced)
    capybara_browser = page.driver.send(:browser)
    playwright_page = capybara_browser.instance_variable_get(:@playwright_page)
    playwright_page.emulate_media(reducedMotion: reduced ? "reduce" : "no-preference")
  end
end
