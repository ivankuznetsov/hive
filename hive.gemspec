require_relative "lib/hive"

Gem::Specification.new do |spec|
  spec.name        = "hive-cli"
  spec.version     = Hive::VERSION
  spec.authors     = [ "Ivan Kuznetsov" ]
  spec.summary     = "Durable, local-first workflow engine for AI agents"
  spec.description = <<~DESC
    Hive is a durable, local-first workflow engine for AI agents. It runs coding,
    content, benchmark, and owner-authored workflows as folder-as-agent pipelines
    with inspectable artifacts and recoverable stage state. Its flagship coding
    workflow carries a rough idea through planning, implementation, pull request,
    review, and finalization. Humans and agents can operate the same local state
    through the TUI, native web UI, files, or structured CLI output.
  DESC
  spec.homepage    = "https://github.com/ivankuznetsov/hive"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata = {
    "homepage_uri"          => spec.homepage,
    "source_code_uri"       => "https://github.com/ivankuznetsov/hive",
    "changelog_uri"         => "https://github.com/ivankuznetsov/hive/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "https://github.com/ivankuznetsov/hive/issues",
    "documentation_uri"     => "https://github.com/ivankuznetsov/hive/blob/main/README.md",
    "rubygems_mfa_required" => "true"
  }

  # Only the files the runtime actually needs. Excludes tests, brainstorms,
  # plans, dev-only docs, packaging templates, and the e2e harness binary.
  spec.files = Dir[
    "bin/hive",
    "bin/hive-babysitter-skip-log.rb",
    "bin/hive-babysitter-stub-gh.rb",
    "bin/hive-babysitter-stub-git",
    "bin/hv",
    "config/agent-skills.yml",
    "skills/**/*",
    "lib/**/*.rb",
    "lib/hive/scripts/**/*.sh",
    "templates/**/*",
    "templates/builtins/bench/runtime/.dockerignore",
    "schemas/**/*.json",
    "examples/systemd/*",
    "examples/launchd/*",
    "install.md",
    "CHANGELOG.md",
    "LICENSE",
    "README.md",
    "hive.gemspec",
  ]

  spec.bindir      = "bin"
  spec.executables = [ "hive" ]

  # Runtime dependencies. Dev/test dependencies stay in the Gemfile because
  # they have no business being installed for end users.
  spec.add_dependency "base64", ">= 0.2"
  spec.add_dependency "bubbletea", "= 0.1.4"
  # Managed installs isolate GEM_HOME/GEM_PATH from the operator's gems. Keep
  # the exact web-lock Bundler inside that managed gem home so web bootstrap
  # can resolve it without relying on a PATH wrapper or a system default gem.
  spec.add_dependency "bundler", "= 2.7.2"
  # faraday + faraday-multipart are required and used directly by the voice
  # transcriber (Faraday.new, Faraday::Multipart::FilePart). They resolve
  # transitively through telegram-bot-ruby today, but declaring them directly
  # keeps transcription from breaking with a LoadError if an upstream bump
  # drops or re-scopes them.
  # erb is a bundled-but-unbundling gem: Arch already ships it as a separate
  # ruby-erb package, and stages/base.rb requires it at load time — without an
  # explicit dependency, vendored installs (pacman, gem install --install-dir)
  # crash with LoadError before any stage can run.
  spec.add_dependency "erb", ">= 4.0"
  spec.add_dependency "faraday", ">= 2.14.2", "< 3.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  # Architecture-patrol manifests are runtime JSON contracts. The scheduler
  # loads their validator in daemon/web-supervisor processes, so keeping this
  # dependency test-only makes installed gems and hivebox crash on daemon boot.
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "lipgloss", "~> 0.2.2"
  # rexml stopped being a default gem in Ruby 3.4, so it is not guaranteed
  # present. The launchd service-installer drift probe parses plists with
  # REXML::Document; without this declaration `hive daemon install/status`
  # and `hive setup` raise LoadError on a stock 3.4 install.
  spec.add_dependency "rexml", "~> 3.2"
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "telegram-bot-ruby", "~> 2.7"
  spec.add_dependency "thor", "~> 1.3"
  # Local-date windows must remain stable when the host runs in another
  # timezone. Declare tzinfo directly rather than relying on Rails/ActiveSupport
  # to provide this runtime dependency transitively.
  spec.add_dependency "tzinfo", "~> 2.0"
  spec.add_dependency "unicode-display_width", "~> 3.2"
end
