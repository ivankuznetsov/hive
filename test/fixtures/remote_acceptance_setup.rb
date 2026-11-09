# frozen_string_literal: true

# Test-only data for the two-installation native CLI acceptance proof.
module RemoteAcceptanceSetup
  def self.prepare(root:, fixture:)
    primary = Hive::Config.find_project(fixture.fetch("project"))
    unless fixture["tokens"]
      repo = File.join(root, "private-project")
      FileUtils.mkdir_p(repo)
      system("git", "init", "-q", repo, exception: true)
      system("git", "-C", repo, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", repo, "config", "user.name", "Remote Test", exception: true)
      File.write(File.join(repo, "README.md"), "# Private fixture\n")
      system("git", "-C", repo, "add", ".", exception: true)
      system("git", "-C", repo, "commit", "-qm", "initial", exception: true)
      original_stdout = $stdout
      begin
        $stdout = StringIO.new
        Hive::Commands::Init.new(repo).call
      ensure
        $stdout = original_stdout
      end
      private_project = Hive::Config.registered_projects.find { |entry| entry.fetch("path") == repo }
      fixture["private_project"] = private_project.fetch("name")
      fixture["tokens"] = %w[read create act answer].to_h do |scope|
        [ scope, Hive::Remote::TokenStore.new.create(name: scope, scopes: [ scope ], projects: [ fixture.fetch("project") ]) ]
      end
      fixture.fetch("tokens")["other"] = Hive::Remote::TokenStore.new.create(
        name: "other creator", scopes: [ "create" ], projects: [ fixture.fetch("project") ])
      fixture.fetch("tokens")["all"] = Hive::Remote::TokenStore.new.create(
        name: "explicit all", scopes: [ "read" ], all_projects: true)
      fixture.fetch("tokens")["expired"] = Hive::Remote::TokenStore.new(clock: -> { Time.now.utc - 3600 }).create(
        name: "expired", scopes: [ "read" ], projects: [ fixture.fetch("project") ], expires_at: (Time.now.utc - 1800).iso8601)
      fixture["task"] = seed(primary, 42, "2-brainstorm", "slow-worker-260923-abcd", "brainstorm.md", "# Brainstorm\n<!-- COMPLETE -->\n")
      fixture["approval_task"] = seed(primary, 43, "1-inbox", "approve-worker-260923-abcd", "idea.md", "# Idea\n<!-- COMPLETE -->\n")
      fixture["question_task"] = seed(primary, 44, "2-brainstorm", "question-worker-260923-abcd", "brainstorm.md",
        "# Brainstorm\n### Q1. Which version?\n### A1.\n<!-- WAITING -->\n")
      fixture["release_task"] = seed(primary, 45, "8-finalize", "release-worker-260923-abcd", "pr.md",
        "# Finalize\n<!-- ERROR reason=timeout marker_id=release-error -->\n")
      release = Hive::Task.new(File.join(primary.fetch("hive_state_path"), "stages", "8-finalize", fixture.fetch("release_task")))
      fixture["release_action"] = Hive::OperationalAction.descriptor_for_task(release, project: primary.fetch("name"))
      seed(private_project, 46, "2-brainstorm", fixture.fetch("task"), "brainstorm.md", "# private-only-secret\n<!-- WAITING -->\n")
      File.write(File.join(root, "fixture.json"), JSON.generate(fixture), mode: "w", perm: 0o600)
    end
    config_path = File.join(primary.fetch("hive_state_path"), "config.yml")
    config = YAML.safe_load_file(config_path)
    config["daemon"] = (config["daemon"] || {}).merge("enabled" => true)
    File.write(config_path, config.to_yaml)
    global_path = File.join(ENV.fetch("HIVE_HOME"), "config.yml")
    global = YAML.safe_load_file(global_path)
    global["web"]["github"]["owner"] = ENV["HIVE_REMOTE_OWNERLESS"] == "1" ? " " : "operator"
    File.write(global_path, global.to_yaml)
    # Complete the serving installation's receipt enrollment before snapshots;
    # a rejected stale operation must not be mistaken for first-use setup.
    Hive::Config.registered_projects.each do |project|
      Hive::ProjectIdentity.resolve(project_root: project.fetch("path"),
        database: Hive::RuntimeControlPlane.database, create: true)
    end
    if ENV["HIVE_REMOTE_SERVER_CONTEXT"] == "1"
      require "hive/connection_contexts"
      contexts = Hive::ConnectionContexts.new(verifier: ->(*) {
        { "instance_id" => "another-installation", "api_version" => "v1",
          "token" => { "id" => "fixture-only", "scopes" => %w[read create act answer],
            "projects" => [ primary.fetch("name") ], "all_projects" => false, "expires_at" => nil } }
      })
      contexts.add("elsewhere", url: "https://127.0.0.1:1", token: "fixture-only")
      contexts.use("elsewhere")
      fixture["selected_client_context"] = contexts.resolve.fetch("name")
    end
    fixture
  end

  def self.seed(project, id, stage, slug, file, content)
    folder = File.join(project.fetch("hive_state_path"), "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(folder, id: id, slug: slug, display_name: slug, workflow: "coding")
    File.write(File.join(folder, file), content)
    slug
  end
end
