require_relative "lib/hive"

Gem::Specification.new do |spec|
  spec.name        = "hive-cli"
  spec.version     = Hive::VERSION
  spec.authors     = [ "Ivan Kuznetsov" ]
  spec.summary     = "Multi-agent orchestrator that ships software ideas from rough note to merge-ready PR"
  spec.description = <<~DESC
    Hive drives software work from a rough idea to a merged pull request through a
    folder-as-agent pipeline: brainstorm pins down requirements, plan fixes the
    approach, execute writes the code, review hardens it, and finalize ships the
    PR. Every task is a directory of plain markdown artefacts you can edit, and
    the dashboard (`hive tui`) drives stage agents on single keystrokes. The CLI
    surface is `--json`-clean so coding agents (Claude Code, Codex, Grok, Pi)
    can drive it programmatically.
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
    "bin/hive-babysitter-stub-gh",
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
  spec.add_dependency "bubbletea", "= 0.1.4"
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
  spec.add_dependency "unicode-display_width", "~> 3.2"
end
