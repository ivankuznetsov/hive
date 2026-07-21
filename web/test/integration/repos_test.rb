require "test_helper"
require "open3"

class ReposTest < ActionDispatch::IntegrationTest
  setup do
    @project = create_hive_project!
  end

  test "repos page lists registered projects without a github token" do
    sign_in!
    get "/repos"
    assert_response :success
    assert_match @project, response.body
    assert_match "Reconnect GitHub to browse your repositories", response.body
    assert_select "a[href='/login']", text: "Reconnect GitHub"
  end

  test "github listing degrades to an inline error on a bad token" do
    # A real HTTPS round-trip to api.github.com with a junk token → 401 →
    # the page must still render the registered list with a notice, never
    # a blank 500. (Skipped automatically is NOT allowed by the house
    # rules; if GitHub is unreachable the network-error branch renders the
    # same inline notice, so the assertion holds either way.)
    sign_in!(token: "gho_definitely_invalid")
    get "/repos"
    assert_response :success
    assert_match @project, response.body, "the registered list must survive a GitHub failure"
    assert_select ".flash-alert", { minimum: 1 }, "the GitHub failure must surface inline"
  end

  test "clone rejects non-github and dash-leading urls" do
    sign_in!
    post "/repos", params: { url: "https://evil.example/x/y" }
    assert_response :unprocessable_entity

    post "/repos", params: { url: "--upload-pack=/bin/sh" }
    assert_response :unprocessable_entity
    assert_match "invalid repo URL", response.body
  end

  test "the setup form renders the init questionnaire" do
    sign_in!
    get "/repos/new", params: { url: "ivankuznetsov/some-repo" }

    assert_response :success
    assert_select "select[name='settings[planning_agent]']", 1
    assert_select "select[name='settings[workflow]']", 1
    # Assert the built-ins without pinning an exact option count, so future
    # built-ins do not break this test with no behavior regression.
    workflow_options = css_select("select[name='settings[workflow]'] option").map { |o| o["value"] }
    assert_equal "coding", workflow_options.first, "fresh setup must list the coding workflow first"
    assert_includes workflow_options, "content", "fresh setup must offer built-in content workflow"
    assert_includes workflow_options, "bench", "fresh setup must offer built-in benchmark workflow"
    assert_select "select[name='settings[workflow]'] option[value='coding'][selected]",
                  "coding", "fresh setup must preselect the coding workflow"
    assert_select "input[name='settings[enabled_reviewers][]']", { minimum: 2 },
                  "the reviewer multi-select must offer the same set the TTY prompt does"
    assert_select "input[name='settings[adhoc_auto_fix]'][type='checkbox']", 1,
                  "the web setup must expose the same ad-hoc auto-fix choice as hive init"
    assert_select "input[name='settings[refactor_patrol_enabled]'][type='checkbox'][checked]", 1,
                  "fresh web setup must recommend architecture patrol"
    assert_match(/Architecture patrol \(recommended\)/, response.body)
    assert_select "input[name='settings[refactor_patrol_auto_fix]']", 0,
                  "the architecture patrol choice must govern its auto-fix policy"
    assert_select "input[name='settings[refactor_patrol_issue_filing]']", 0,
                  "the architecture patrol choice must govern its issue fallback"
    assert_match(/Accepted findings attempt confined fixes and pull requests/, response.body)
    assert_select "input[name='settings[budgets][brainstorm]']", 1
  end

  test "chosen settings reach hive init through the prompts seam" do
    sign_in!
    dir = create_uninitialized_repo!("repos-root2", "configured-app")

    # Spy on Init.new to prove the web path hands the workflow over as a FLAG —
    # the interactive workflow prompt is bypassed entirely. The on-disk
    # default_workflow assertion below can't by itself tell a flag bind from a
    # prompt bind; the system test covers the prompt-skip only implicitly.
    captured_workflow = :unset
    captured_provisioning_input = nil
    captured_provisioning_error = nil
    original_init_new = Hive::Commands::Init.method(:new)
    Hive::Commands::Init.define_singleton_method(:new) do |*args, **kwargs|
      captured_workflow = kwargs[:workflow]
      captured_provisioning_input = kwargs[:provisioning_input]
      captured_provisioning_error = kwargs[:provisioning_error]
      original_init_new.call(*args, **kwargs)
    end

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: {
        url: "ivankuznetsov/configured-app", name: "configured-app",
        settings: {
          workflow: "content",
          claude_mode: "headless", triage_bias: "safetyist", patrol_mode: "off",
          adhoc_auto_fix: "1",
          refactor_patrol_enabled: "1",
          enabled_reviewers_submitted: "1", enabled_reviewers: [ "claude-ce-code-review" ],
          daemon_enabled: "0", babysitter_enabled: "0",
          budgets: { brainstorm: "3" }
        }
      }
    end

    assert_redirected_to "/repos"
    assert_equal "content", captured_workflow,
                 "the web path must supply the workflow as an Init flag, bypassing the interactive prompt"
    refute_nil captured_provisioning_input,
               "web init must supply its own non-interactive provisioning input instead of inheriting Puma's stdin"
    assert_equal false, captured_provisioning_input.tty?,
                 "a foreground `hive web` TTY must never leak an invisible setup-agents prompt into an HTTP request"
    assert_instance_of StringIO, captured_provisioning_error,
                       "web init must capture preflight findings instead of writing them only to Puma stderr"
    config = File.read(File.join(dir, ".hive-state", "config.yml"))
    assert_match(/headless/, config, "the chosen claude mode must land in the project config")
    assert_match(/safetyist/, config, "the chosen triage bias must land in the project config")
    parsed_config = YAML.safe_load(config)
    assert_equal "content", parsed_config.fetch("default_workflow"),
                 "the chosen workflow must land in the project config through Init.new(workflow:)"
    assert_equal true, parsed_config.dig("review", "adhoc", "fix"),
                 "the web path must pass ad-hoc auto-fix through the prompts seam"
    assert_equal true, parsed_config.dig("review", "github_publish", "enabled"),
                 "GitHub publishing must stay enabled by default for PR review comments"
    assert_equal true, parsed_config.dig("refactor_patrol", "enabled"),
                 "an omitted web checkbox value must use the fresh-init discovery recommendation"
    assert_equal true, parsed_config.dig("refactor_patrol", "auto_fix", "enabled"),
                 "recommended architecture patrol must attempt confined fixes"
    assert_equal true, parsed_config.dig("refactor_patrol", "issue_filing", "enabled"),
                 "recommended discovery must produce reviewable GitHub issues"
  ensure
    Hive::Commands::Init.define_singleton_method(:new, original_init_new) if original_init_new
  end

  test "web init surfaces noninteractive provisioning findings after success" do
    project = create_hive_project!("repos-preflight-warning-app")
    sign_in!
    original_init_new = Hive::Commands::Init.method(:new)
    Hive::Commands::Init.define_singleton_method(:new) do |*_args, **kwargs|
      Object.new.tap do |command|
        command.define_singleton_method(:call) do
          kwargs.fetch(:provisioning_error).puts(
            "hive: doctor pre-flight — found 1 issue: registry package is unavailable"
          )
        end
      end
    end

    post repos_path,
         params: { project: project, settings: { workflow: "coding" } }

    assert_redirected_to repos_path
    assert_match(/settings applied/, flash[:notice])
    assert_match(/setup completed.*registry package is unavailable/, flash[:alert])
  ensure
    Hive::Commands::Init.define_singleton_method(:new, original_init_new) if original_init_new
  end

  test "web and terminal setup expose the same answer keys" do
    input = StringIO.new
    input.define_singleton_method(:tty?) { false }
    terminal_answers = Hive::Commands::Init::Prompts.new(
      input: input, output: StringIO.new, summary_io: StringIO.new
    ).collect

    web_answers = InitSetup.new({}).collect

    assert_equal terminal_answers.keys.sort, web_answers.keys.sort
    assert_equal true, web_answers.fetch("refactor_patrol_enabled"),
                 "missing web input must use the same fresh-init recommendation as terminal setup"
  end

  test "fresh setup persists an explicitly unchecked architecture patrol choice" do
    sign_in!
    dir = create_uninitialized_repo!("repos-root-architecture-off", "architecture-off-app")

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: {
        url: "ivankuznetsov/architecture-off-app",
        name: "architecture-off-app",
        settings: { workflow: "coding", refactor_patrol_enabled: "0" }
      }
    end

    assert_redirected_to "/repos"
    config = YAML.safe_load_file(File.join(dir, ".hive-state", "config.yml"))
    assert_equal false, config.dig("refactor_patrol", "enabled")
    assert_equal false, config.dig("refactor_patrol", "auto_fix", "enabled")
    assert_equal false, config.dig("refactor_patrol", "issue_filing", "enabled")
  end

  test "tampered architecture patrol input is rejected" do
    sign_in!

    post "/repos", params: {
      project: @project,
      settings: { workflow: "coding", refactor_patrol_enabled: "enable-everything" }
    }

    assert_response :unprocessable_entity
    assert_match "refactor_patrol_enabled must be a boolean", response.body
  end

  test "rerun setup preserves the existing architecture patrol policy" do
    name = create_hive_project!("rerun-architecture-policy-app")
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
    state_dir = File.join(dir, ".hive-state")
    config_path = File.join(state_dir, "config.yml")
    config = YAML.safe_load_file(config_path)
    refactor_patrol = config.fetch("refactor_patrol")
    refactor_patrol["enabled"] = false
    refactor_patrol.fetch("auto_fix")["enabled"] = false
    refactor_patrol.fetch("issue_filing")["enabled"] = false
    File.write(config_path, config.to_yaml)
    system("git", "-C", state_dir, "add", "config.yml", exception: true)
    system("git", "-C", state_dir, "commit", "-qm", "disable architecture patrol", exception: true)

    get "/repos/new", params: { project: name }
    assert_response :success
    assert_select "input[name='settings[refactor_patrol_enabled]']", 0,
                  "rerun setup must not present an ignored policy control"
    assert_match "Existing architecture patrol policy is preserved", response.body

    post "/repos", params: {
      project: name,
      settings: { workflow: "coding", refactor_patrol_enabled: "1" }
    }

    assert_redirected_to "/repos"
    persisted = YAML.safe_load_file(config_path)
    assert_equal false, persisted.dig("refactor_patrol", "enabled"),
                 "rerunning setup must not replace an existing discovery policy"
    assert_equal false, persisted.dig("refactor_patrol", "auto_fix", "enabled")
    assert_equal false, persisted.dig("refactor_patrol", "issue_filing", "enabled")
  end

  test "rerun setup rebinds the project default workflow on disk" do
    # The re-run branch (params[:project] present) routes through
    # handle_existing_project — a different bind path than a fresh clone init.
    # Assert the rebound default_workflow actually reaches config.yml on disk so
    # dropping `workflow:` from the re-run reinit! call can't stay green.
    name = create_hive_project!("rerun-rebind-app")
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)

    post "/repos", params: { project: name, settings: { workflow: "content" } }

    assert_redirected_to "/repos"
    config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
    assert_equal "content", config.fetch("default_workflow"),
                 "the re-run rebind must persist default_workflow through handle_existing_project"
  end

  test "rerun setup rebinds the workflow but discards non-workflow answers" do
    # handle_existing_project rebinds ONLY default_workflow — it never consumes
    # the prompts: answers — so a re-run drops changed agent/mode/reviewer/budget
    # settings. Pin that real on-disk outcome (the workflow lands, the rest do
    # not) so the discard is explicit, not an accidental impression the form
    # re-applies everything. Whether re-run SHOULD re-apply is the open re-run-
    # semantics escalation, deliberately out of this PR's scope.
    name = create_hive_project!("rerun-nonworkflow-app")
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
    # The fresh init used CLI defaults: claude.mode=tmux, review.triage.bias=courageous.

    post "/repos", params: {
      project: name,
      settings: { workflow: "content", claude_mode: "headless", triage_bias: "safetyist" }
    }

    assert_redirected_to "/repos"
    config = YAML.safe_load(File.read(File.join(dir, ".hive-state", "config.yml")))
    assert_equal "content", config.fetch("default_workflow"),
                 "the re-run must rebind default_workflow on disk"
    assert_equal "tmux", config.dig("claude", "mode"),
                 "re-init does not consume prompts: answers — claude.mode must stay the original default"
    assert_equal "courageous", config.dig("review", "triage", "bias"),
                 "re-init does not consume prompts: answers — triage bias must stay the original default"
  end

  test "a path-traversal workflow id is rejected before it reaches path resolution" do
    # The web workflow value flows into File.join(workflow_dir, "#{id}.yml"); a
    # crafted `../…` must be refused by InitSetup (SAFE_SLUG) rather than
    # walking that join in WorkflowSelection.
    name = create_hive_project!("rerun-traversal-app")
    sign_in!

    post "/repos", params: { project: name, settings: { workflow: "../../etc/passwd" } }

    assert_response :unprocessable_entity
    assert_match "invalid workflow id", response.body
  end

  test "rerun setup omitting the workflow param is a 422, not a silent coding rebind" do
    # The browser always submits settings[workflow], but a scripted/curl caller
    # might omit it. With no workflow the re-run resolves :implicit on an
    # already-initialized project → AlreadyInitialized → 422; pin that contract.
    name = create_hive_project!("rerun-bare-app")
    sign_in!

    post "/repos", params: { project: name }

    assert_response :unprocessable_entity
  end

  test "rerun form survives a corrupt project config instead of 500ing" do
    # persisted_default_workflow degrades a corrupt/unreadable config.yml to nil
    # (falling back to coding) so the very form an operator opens to REPAIR a
    # broken project still renders the workflow select rather than 500ing.
    name = create_hive_project!("rerun-corrupt-config-app")
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
    config_path = File.join(dir, ".hive-state", "config.yml")
    valid_config = File.read(config_path)
    File.write(config_path, "default_workflow: [unterminated\n")
    # The per-root workflow overlay is process-memoized; force a fresh disk read.
    Hive::Workflows::Project.reset!

    get "/repos/new", params: { project: name }

    assert_response :success
    assert_select "select[name='settings[workflow]']", 1,
                  "the repair form must still render the workflow select over a corrupt config"
  ensure
    # Restore the readable config so this project doesn't flood the shared
    # process-wide sandbox with status warnings in later tests.
    File.write(config_path, valid_config) if config_path && valid_config
    Hive::Workflows::Project.reset!
  end

  test "rerun setup keeps an unloadable persisted default selected instead of downgrading to coding" do
    name = create_hive_project!("rerun-orphan-app")
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos", name)
    capture_io { Hive::Commands::Init.new(dir, new_workflow: "writing", force: true).call }
    # Drop the descriptor so valid_names no longer lists `writing`, leaving
    # config.yml's `default_workflow: writing` pointing at a now-gone workflow —
    # the exact state where the old select silently rebound a bare Apply to coding.
    FileUtils.rm_rf(File.join(dir, ".hive-state", "workflows", "writing.yml"))
    FileUtils.rm_rf(File.join(dir, ".hive-state", "workflows", "writing"))
    # The per-root workflow overlay is process-memoized; force a fresh disk read
    # so the controller's valid_names reflects the deleted descriptor.
    Hive::Workflows::Project.reset!

    get "/repos/new", params: { project: name }

    assert_response :success
    assert_select "select[name='settings[workflow]'] option[value='writing'][selected]",
                  "writing", "the unloadable persisted default must stay selected, not silently fall back to coding"
    assert_select "select[name='settings[workflow]'] option[value='coding'][selected]", false,
                  "coding must not be auto-selected when a non-coding default is still persisted"
  end

  test "an out-of-range setting is a readable 422, not a silent default" do
    sign_in!
    post "/repos", params: { url: "ivankuznetsov/x", settings: { claude_mode: "yolo" } }

    assert_response :unprocessable_entity
    assert_match "claude_mode must be one of", response.body
  end

  test "an existing directory is re-inited without cloning" do
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root", "already-here")
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
    File.write(File.join(dir, "README.md"), "x")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-qm", "i", exception: true)

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: { url: "ivankuznetsov/already-here", name: "already-here" }
    end

    assert_redirected_to "/repos"
    names = Hive::Config.registered_projects.map { |p| p["name"] }
    assert_includes names, "already-here", "the existing checkout must be registered via hive init"
  end

  test "a stray file at the clone target is a 422 and survives untouched" do
    sign_in!
    root = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root4")
    FileUtils.mkdir_p(root)
    stray = File.join(root, "stray-name")
    File.write(stray, "operator data, not ours to delete")

    with_repos_root(root) do
      post "/repos", params: { url: "ivankuznetsov/stray-name", name: "stray-name" }
    end

    assert_response :unprocessable_entity
    assert_match "not a directory", response.body
    assert_equal "operator data, not ours to delete", File.read(stray),
                 "the pre-existing file must survive the rejected clone"
  end

  test "registration rewrites a github ssh origin to https" do
    # gh clones over ssh when the operator's git_protocol prefers it, but the
    # box can only push https (no SSH keys in the container, no agent for a
    # headless daemon) — an ssh origin means every 5-open-pr push fails.
    sign_in!
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], "repos-root3", "ssh-origin")
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
    File.write(File.join(dir, "README.md"), "x")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "-c", "user.email=t@e.c", "-c", "user.name=T", "commit", "-qm", "i", exception: true)
    system("git", "-C", dir, "remote", "add", "origin",
           "git@github.com:ivankuznetsov/ssh-origin.git", exception: true)

    with_repos_root(File.dirname(dir)) do
      post "/repos", params: { url: "ivankuznetsov/ssh-origin", name: "ssh-origin" }
    end

    assert_redirected_to "/repos"
    origin, = Open3.capture2("git", "-C", dir, "remote", "get-url", "origin")
    assert_equal "https://github.com/ivankuznetsov/ssh-origin.git", origin.strip,
                 "the ssh origin must be rewritten to https so the daemon can push"
  end

  private

  def create_uninitialized_repo!(root_name, name)
    dir = File.join(ENV["HIVE_TEST_HOME_ROOT"], root_name, name)
    FileUtils.mkdir_p(dir)
    system("git", "init", "-q", dir, exception: true)
    system("git", "-C", dir, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", dir, "config", "user.name", "Hive Test", exception: true)
    File.write(File.join(dir, "README.md"), "x")
    system("git", "-C", dir, "add", ".", exception: true)
    system("git", "-C", dir, "commit", "-qm", "initial commit", exception: true)
    dir
  end

  def with_repos_root(root)
    old = ENV["HIVEBOX_REPOS_DIR"]
    ENV["HIVEBOX_REPOS_DIR"] = root
    yield
  ensure
    old.nil? ? ENV.delete("HIVEBOX_REPOS_DIR") : ENV["HIVEBOX_REPOS_DIR"] = old
  end
end
