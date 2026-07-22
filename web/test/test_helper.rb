# Every test runs against a throwaway HIVE_HOME so nothing can touch the
# developer's real hive config/state (the gem suite once corrupted a real
# .env file — never again). Set BEFORE the app loads: the hive gem freezes
# some paths at require time.
require "tmpdir"
ENV["RAILS_ENV"] ||= "test"
ENV["HIVE_TEST_HOME_ROOT"] = Dir.mktmpdir("hive-web-test")
ENV["HIVE_HOME"] = File.join(ENV["HIVE_TEST_HOME_ROOT"], "hive-home")
ENV["HOME"] = File.join(ENV["HIVE_TEST_HOME_ROOT"], "home")
ENV["HIVE_SKIP_LLM_WIKI_SCHEDULER"] = "1"
ENV["HIVE_SKIP_LLM_WIKI_SYSTEMCTL"] = "1"
ENV["HIVE_SKIP_LLM_WIKI_POST_COMMIT"] = "1"
FileUtils.mkdir_p(ENV["HIVE_HOME"])
FileUtils.mkdir_p(ENV["HOME"])

require_relative "../config/environment"
require "rails/test_help"

Minitest.after_run do
  root = ENV["HIVE_TEST_HOME_ROOT"]
  FileUtils.rm_rf(root) if root&.include?("hive-web-test")
end

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
        # Repo-level identity: CI runners have no global git user, and
        # Init's bootstrap commits inside .hive-state need an author.
        system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
        system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
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
      inbox = stage_dir(project, "1-inbox")
      attempts = 0

      begin
        before = inbox.children.map { |child| child.basename.to_s }
        capture_io { Hive::Commands::New.new(project, text).call! }
        created = inbox.children.reject { |child| before.include?(child.basename.to_s) }
        return created.max_by(&:mtime).basename.to_s unless created.empty?
      rescue Hive::Commands::New::SlugCollisionError
        attempts += 1
        retry if attempts < 5
        raise
      end

      raise "hive test helper could not identify the task created for #{text.inspect}"
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

    def with_replaced_singleton_method(receiver, name, replacement)
      original = receiver.method(name)
      receiver.define_singleton_method(name, &replacement)
      yield
    ensure
      receiver.define_singleton_method(name, original)
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

  # owner: "" writes a CLAIMABLE instance (the key is omitted — the config
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
