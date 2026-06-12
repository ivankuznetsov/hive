# Every test runs against a throwaway HIVE_HOME so nothing can touch the
# developer's real hive config/state (the gem suite once corrupted a real
# .env file — never again). Set BEFORE the app loads: the hive gem freezes
# some paths at require time.
require "tmpdir"
ENV["RAILS_ENV"] ||= "test"
ENV["HIVE_TEST_HOME_ROOT"] = Dir.mktmpdir("hive-web-test")
ENV["HIVE_HOME"] = File.join(ENV["HIVE_TEST_HOME_ROOT"], "hive-home")
FileUtils.mkdir_p(ENV["HIVE_HOME"])

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # No parallel workers: tests share the process-global HIVE_HOME sandbox
    # and the hive gem's path caches; forked workers would race the same
    # filesystem fixture.
    parallelize(workers: 1)

    # Build a registered hive project (real git repo + real `hive init`)
    # inside the sandbox and return its name. The full pipeline state
    # machine — not a fake — backs every controller test.
    def create_hive_project!(name = "demo-app")
      dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
      FileUtils.mkdir_p(dir)
      unless File.directory?(File.join(dir, ".git"))
        system("git", "init", "-q", dir, exception: true)
        File.write(File.join(dir, "README.md"), "# #{name}\n")
        system("git", "-C", dir, "add", ".", exception: true)
        system("git", "-C", dir, "-c", "user.email=test@example.com", "-c", "user.name=Test",
               "commit", "-qm", "init", exception: true)
      end
      begin
        capture_io { Hive::Commands::Init.new(dir, force: true, json: false).call }
      rescue Hive::AlreadyInitialized
        # The sandbox HIVE_HOME persists for the process; a later test
        # re-using the same project name just reuses the registration.
      end
      name
    end

    def create_task!(project, text)
      capture_io { Hive::Commands::New.new(project, text).call! }
      stage_dir(project, "1-inbox").children.max_by(&:mtime).basename.to_s
    end

    def stage_dir(project, stage)
      Pathname(File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", project, ".hive-state", "stages", stage))
    end

    def capture_io(&)
      require "stringio"
      out, err = StringIO.new, StringIO.new
      orig_out, orig_err = $stdout, $stderr
      $stdout, $stderr = out, err
      yield
      [ out.string, err.string ]
    ensure
      $stdout, $stderr = orig_out, orig_err
    end
  end
end

module AuthTestHelper
  # Sign in through the dev seam — the same env-gated route Capybara uses.
  def sign_in!(login: "alice", token: nil)
    configure_owner!(owner: login)
    get "/dev_login", params: { as: login, token: token }
    follow_redirect! if response.redirect?
  end

  # owner: "" writes a CLAIMABLE box (the key is omitted — the config
  # validator rejects empty strings; claimable means absent).
  def configure_owner!(owner: "alice")
    path = File.join(ENV["HIVE_HOME"], "config.yml")
    data = File.exist?(path) ? YAML.safe_load_file(path) : {}
    data ||= {}
    github = { "client_id" => "client" }
    github["owner"] = owner unless owner.to_s.strip.empty?
    data["web"] = { "origin" => "http://www.example.com", "github" => github }
    File.write(path, data.to_yaml)
  end
end

class ActionDispatch::IntegrationTest
  include AuthTestHelper
end
