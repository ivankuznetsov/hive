require "test_helper"
require_relative "../../support/web_session_helper"
require "hive/config"
require "hive/commands/init"

# U7 add-a-repo coverage: the repos list renders, an operator-supplied name
# cannot escape the repos root (path traversal), and a clone is performed via
# `gh` (box auth) into the repos dir before `hive init` registers it.
class WebReposRoutesTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  # Fake `gh repo clone <url> <target>` that materializes a committed git
  # repo at the target so the subsequent `hive init` succeeds. Records the
  # resolved target path so the test can assert it stayed inside the root.
  def install_fake_gh(bin_dir, target_log)
    path = File.join(bin_dir, "gh")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      set -e
      target="$4"
      echo "$target" >> "#{target_log}"
      git init -q -b master "$target"
      git -C "$target" config user.email t@e.com
      git -C "$target" config user.name T
      git -C "$target" config commit.gpgsign false
      echo readme > "$target/README.md"
      git -C "$target" add .
      git -C "$target" commit -q -m init
    SH
    FileUtils.chmod(0o755, path)
  end

  def with_box
    with_tmp_global_config do |home|
      repos_root = File.join(home, "repos")
      bin_dir = File.join(home, "bin")
      FileUtils.mkdir_p([ repos_root, bin_dir ])
      target_log = File.join(home, "clone-targets.log")
      install_fake_gh(bin_dir, target_log)
      with_env(
        "HIVEBOX_REPOS_DIR" => repos_root,
        "PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      ) do
        boot_web_app
        login!
        yield(repos_root, target_log)
      end
    end
  end

  def test_repos_list_renders
    with_box do |_root, _log|
      get "/repos", {}, "HTTP_HOST" => "127.0.0.1"

      assert last_response.ok?
      assert_includes last_response.body, "repos"
    end
  end

  def test_dot_dot_name_is_rejected
    with_box do |root, log|
      token = csrf_token_from("/repos")

      post "/repos",
           { "url" => "https://github.com/octo/x.git", "name" => "..", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status, "a `..` name must be rejected outright"
      assert_equal "", File.exist?(log) ? File.read(log).strip : "", "no clone should run for an invalid name"
    end
  end

  def test_traversal_name_is_sanitized_into_root
    with_box do |root, log|
      token = csrf_token_from("/repos")

      post "/repos",
           { "url" => "https://github.com/octo/x.git", "name" => "../../escape", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?, "a sanitizable name should clone and register"
      cloned = File.read(log).strip
      assert_equal File.join(root, "escape"), cloned,
                   "File.basename must collapse `../../escape` to a path inside the repos root"
      assert File.directory?(File.join(root, "escape")), "repo must land inside the root"
    end
  end

  def test_non_github_url_is_rejected
    with_box do |_root, log|
      token = csrf_token_from("/repos")

      post "/repos",
           { "url" => "https://evil.test/x.git", "name" => "x", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status, "a non-github.com host must be rejected"
      assert_equal "", File.exist?(log) ? File.read(log).strip : "", "no clone should run for a rejected URL"
    end
  end

  def test_leading_dash_url_is_rejected
    with_box do |_root, log|
      token = csrf_token_from("/repos")

      post "/repos",
           { "url" => "--upload-pack=evil", "name" => "x", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert_equal 422, last_response.status, "a leading-dash URL (argument injection) must be rejected"
      assert_equal "", File.exist?(log) ? File.read(log).strip : "", "no clone should run for a rejected URL"
    end
  end

  def test_owner_repo_shorthand_is_accepted
    with_box do |root, log|
      token = csrf_token_from("/repos")

      post "/repos",
           { "url" => "octo/widgets", "name" => "widgets", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?, "owner/repo gh shorthand should be accepted"
      assert_equal File.join(root, "widgets"), File.read(log).strip
    end
  end

  # When the target already exists under the repos root the route must NOT
  # re-clone over it — it re-inits the existing checkout in place (the
  # File.directory? branch). Pre-create a git repo at the target and assert
  # no clone runs.
  def test_existing_target_is_reinitialized_without_cloning
    with_box do |root, log|
      target = File.join(root, "widgets")
      FileUtils.mkdir_p(target)
      system("git", "init", "-q", "-b", "master", target, out: File::NULL, err: File::NULL)
      system("git", "-C", target, "config", "user.email", "t@e.com")
      system("git", "-C", target, "config", "user.name", "T")
      system("git", "-C", target, "config", "commit.gpgsign", "false")
      File.write(File.join(target, "README.md"), "hi")
      system("git", "-C", target, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", target, "commit", "-q", "-m", "init", out: File::NULL, err: File::NULL)

      token = csrf_token_from("/repos")
      post "/repos",
           { "url" => "https://github.com/octo/widgets.git", "name" => "widgets", "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?, "re-adding an existing repo must re-init and redirect"
      assert_equal "", File.exist?(log) ? File.read(log).strip : "",
                   "an existing target must be re-inited in place, never re-cloned"
      assert Hive::Config.registered_projects.any? { |p| p["name"] == "widgets" },
             "the re-inited repo must be registered"
    end
  end

  def test_delete_forgets_named_project_with_csrf
    with_box do |_root, _log|
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        assert Hive::Config.registered_projects.any? { |p| p["name"] == project }

        token = csrf_token_from("/repos")
        post "/repos/#{project}/delete",
             { "authenticity_token" => token },
             "HTTP_HOST" => "127.0.0.1"

        assert last_response.redirect?, "a CSRF-valid delete should redirect"
        refute Hive::Config.registered_projects.any? { |p| p["name"] == project },
               "delete must forget exactly the named project"
      end
    end
  end

  def test_delete_without_csrf_is_rejected
    with_box do |_root, _log|
      post "/repos/anything/delete", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 403, last_response.status, "a delete without a CSRF token must be rejected"
    end
  end
end
