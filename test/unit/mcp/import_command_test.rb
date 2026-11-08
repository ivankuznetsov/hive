require "test_helper"
require "json"
require "json_schemer"
require "stringio"
require "hive/commands/mcp"
require "hive/mcp/import_offer"
require "hive/mcp/importer"

class McpImportCommandTest < Minitest::Test
  include HiveTestHelper

  Candidate = Hive::Mcp::Discovery::Candidate
  Result = Hive::Mcp::Discovery::Result

  class Tty < StringIO
    def tty? = true
  end

  def candidate(name, agent, spec, oauth: false, logged_in: false, exports: [], refusal: nil)
    Candidate.new(name: name, agent: agent, spec: spec, oauth: oauth, logged_in: logged_in,
                  exports: exports, refusal: refusal)
  end

  LINEAR = { "url" => "https://mcp.linear.app/mcp" }.freeze
  DOCS = { "url" => "https://docs.example.com/mcp", "bearer_token_env" => "DOCS_TOKEN" }.freeze

  def discovered
    Result.new(
      candidates: [
        candidate("linear", "codex", LINEAR, oauth: true, logged_in: true),
        candidate("linear", "claude", LINEAR, oauth: true),
        candidate("docs", "codex", DOCS, exports: [ { "var" => "DOCS_TOKEN", "for" => "docs Authorization header (codex)" } ]),
        candidate("split", "codex", { "url" => "https://a.example/mcp" }),
        candidate("split", "claude", { "url" => "https://b.example/mcp" }),
        candidate("legacy", "claude", nil, refusal: "transport \"sse\" is not supported"),
        candidate("moved", "codex", { "url" => "https://new.example/mcp" }),
        candidate("same", "codex", { "command" => "tool", "args" => [] }),
        candidate("relog", "codex", LINEAR, oauth: true, logged_in: true)
      ],
      notices: [ "grok skipped: unreadable" ]
    )
  end

  CATALOG = {
    "moved" => { "url" => "https://old.example/mcp", "imported_from" => "codex" },
    "same" => { "command" => "tool", "args" => [], "imported_from" => "codex" },
    "relog" => { "url" => "https://mcp.linear.app/mcp", "imported_from" => "codex", "oauth_logins" => [] },
    "gone" => { "url" => "https://gone.example/mcp", "imported_from" => "pi" },
    "manual" => { "command" => "hand-written" }
  }.freeze

  def with_catalog(catalog = CATALOG)
    with_tmp_global_config(runtime: false) do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [], "daily_digest" => { "enabled" => false },
        "mcp" => { "inherit_user" => false, "servers" => catalog }
      }.to_yaml)
      yield home
    end
  end

  def command(subcommand = "import", server = nil, input: StringIO.new, **options)
    output = StringIO.new
    error = StringIO.new
    runner_calls = []
    runner = options.delete(:runner) || ->(argv) { runner_calls << argv; true }
    cmd = Hive::Commands::Mcp.new(subcommand, server, input: input, output: output, error: error,
                                                       discover: ->(_cwd) { discovered }, runner: runner, **options)
    [ cmd, output, error, runner_calls ]
  end

  def run_command(*args, **options)
    cmd, output, error, calls = command(*args, **options)
    code = cmd.call
    [ code, output.string, error.string, calls ]
  end

  def schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-mcp-import"))))

  def rows(catalog = CATALOG) = Hive::Mcp::Importer.plan(discovered, catalog).to_h { |row| [ row.id, row ] }

  def global_config(home) = YAML.safe_load_file(File.join(home, "config.yml"))

  # --- planning -------------------------------------------------------------

  def test_plan_merges_identical_servers_and_reports_every_status
    planned = rows

    assert_equal "new", planned.fetch("linear").status
    assert_equal %w[codex claude], planned.fetch("linear").sources
    assert_equal %w[codex], planned.fetch("linear").logins
    assert_equal "oauth", planned.fetch("linear").auth
    assert_equal "env:DOCS_TOKEN", planned.fetch("docs").auth
    assert_equal %w[conflict conflict], [ planned.fetch("split@codex").status, planned.fetch("split@claude").status ]
    assert_equal "refused", planned.fetch("legacy@claude").status
    assert_equal "drift", planned.fetch("moved").status
    assert_equal "imported", planned.fetch("same").status
    assert_equal "none", planned.fetch("same").auth
    assert planned.fetch("relog").logins_changed
    assert_equal "catalog-only", planned.fetch("gone").status
    refute planned.key?("manual")
    assert_nil planned.fetch("gone").auth
    assert_nil planned.fetch("gone").transport
    assert_equal "env:X_ORG", Hive::Mcp::Importer::Row.new(
      id: "h", name: "h", status: "new", sources: [], spec: { "url" => "https://h", "headers_env" => { "X-Org" => "X_ORG" } },
      logins: [], exports: [], refusal: nil, logins_changed: false
    ).auth
  end

  def test_selection_rules
    planned = Hive::Mcp::Importer.plan(discovered, CATALOG)
    select = ->(**options) { Hive::Mcp::Importer.select(planned, **options).map(&:id) }

    assert_equal %w[docs linear relog], select.call(all: true)
    assert_equal %w[docs linear moved relog], select.call(all: true, update: true)
    assert_equal %w[split@claude], select.call(only: %w[split@claude])
    assert_equal %w[moved], select.call(only: %w[moved], update: true)
    {
      %w[nope] => "no discovered server named nope",
      %w[legacy@claude] => "cannot be imported: transport",
      %w[gone] => "no longer exists at its source",
      %w[moved] => "pass --update"
    }.each do |only, message|
      error = assert_raises(Hive::UsageError) { select.call(only: only) }
      assert_includes error.message, message
    end
  end

  # --- import command -------------------------------------------------------

  def test_dry_run_json_validates_and_writes_nothing
    with_catalog do |home|
      before = File.read(File.join(home, "config.yml"))
      code, stdout, = run_command(json: true, dry_run: true, all: true)
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_empty schemer.validate(payload).to_a
      assert_equal %w[docs linear relog], payload.fetch("rows").select { |row| row["selected"] }.map { |row| row["id"] }
      assert_equal [], payload.fetch("written")
      assert_equal [ "DOCS_TOKEN" ], payload.fetch("rows").find { |row| row["id"] == "docs" }.fetch("exports")
      assert_equal before, File.read(File.join(home, "config.yml"))

      _code, plain, = run_command(json: true, dry_run: true)
      assert_empty JSON.parse(plain).fetch("rows").select { |row| row["selected"] }
    end
  end

  def test_json_write_without_yes_is_refused_with_a_valid_envelope
    with_catalog do
      cmd, output, = command(json: true, all: true)
      error = assert_raises(Hive::Commands::Mcp::ConsentRequired) { cmd.call }
      payload = JSON.parse(output.string)

      assert_equal 64, error.exit_code
      assert_equal "consent_required", payload.fetch("error_kind")
      assert_equal "import", payload.fetch("action")
      assert_empty schemer.validate(payload).to_a

      cmd, output, = command(json: true)
      assert_raises(Hive::Commands::Mcp::ConsentRequired) { cmd.call }
      assert_includes JSON.parse(output.string).fetch("message"), "--all or --only"
    end
  end

  def test_all_yes_writes_new_servers_and_keeps_other_keys
    with_catalog do |home|
      code, stdout, stderr = run_command(all: true, yes: true)
      config = global_config(home)
      servers = config.dig("mcp", "servers")

      assert_equal 0, code
      assert_equal({ "url" => "https://mcp.linear.app/mcp", "imported_from" => "codex", "oauth_logins" => [ "codex" ] },
                   servers.fetch("linear"))
      assert_equal DOCS.merge("imported_from" => "codex"), servers.fetch("docs")
      assert_equal [ "codex" ], servers.dig("relog", "oauth_logins")
      assert_equal "https://old.example/mcp", servers.dig("moved", "url")
      assert_equal({ "enabled" => false }, config.fetch("daily_digest"))
      assert_equal [], config.fetch("registered_projects")
      assert_includes stdout, "Imported docs, linear, relog"
      assert_includes stdout, "export DOCS_TOKEN=...   # docs Authorization header (codex)"
      assert_includes stderr, "note: grok skipped: unreadable"
      assert_includes stderr, "conflict"
    end
  end

  def test_only_update_and_variant_pick
    with_catalog do |home|
      run_command(only: "moved,split@claude", update: true, yes: true)
      servers = global_config(home).dig("mcp", "servers")

      assert_equal "https://new.example/mcp", servers.dig("moved", "url")
      assert_equal "https://b.example/mcp", servers.dig("split", "url")
      assert_equal "claude", servers.dig("split", "imported_from")

      error = assert_raises(Hive::UsageError) { run_command(only: "split", yes: true) }
      assert_includes error.message, "pick one variant of split"
    end
  end

  def test_interactive_selection_by_number_name_or_all
    with_catalog do |home|
      planned = Hive::Mcp::Importer.plan(discovered, CATALOG)
      number = planned.index { |row| row.id == "docs" } + 1
      code, stdout, stderr = run_command(input: Tty.new("#{number}, linear\n"))
      assert_equal 0, code
      assert_includes stderr, "Import which servers?"
      assert_includes stderr, "(signed in: codex)"
      assert_includes stdout, "Imported docs, linear"
      assert_equal %w[docs gone linear manual moved relog same], global_config(home).dig("mcp", "servers").keys.sort
    end

    with_catalog do |home|
      run_command(input: Tty.new("all\n"))
      assert global_config(home).dig("mcp", "servers").key?("docs")
    end

    with_catalog do
      _code, stdout, = run_command(input: Tty.new("\n"))
      assert_includes stdout, "No servers imported."
    end

    with_catalog do |home|
      _code, stdout, = run_command(input: Tty.new("y\n"), only: "docs")
      assert_includes stdout, "Imported docs"
      _code, stdout, = run_command(input: Tty.new("n\n"), only: "linear") rescue nil
      refute global_config(home).dig("mcp", "servers").key?("linear")
    end
  end

  def test_empty_discovery_and_nothing_to_choose
    with_catalog({}) do
      cmd = Hive::Commands::Mcp.new("import", input: Tty.new("\n"), output: StringIO.new, error: (err = StringIO.new),
                                              discover: ->(_cwd) { Result.new(candidates: [], notices: []) })
      assert_equal 0, cmd.call
      assert_includes err.string, "No personal MCP servers found."
      assert_includes err.string, "Nothing to import."

      out = StringIO.new
      Hive::Commands::Mcp.new("import", dry_run: true, output: out, error: StringIO.new,
                                        discover: ->(_cwd) { Result.new(candidates: [], notices: []) }).call
      assert_includes out.string, "dry run: would import nothing"
    end
  end

  def test_usage_errors
    with_catalog do
      { [ "import", "linear" ] => "takes no SERVER", [ "bogus" ] => "expected a subcommand" }.each do |args, message|
        error = assert_raises(Hive::UsageError) { run_command(*args) }
        assert_includes error.message, message
      end
      error = assert_raises(Hive::UsageError) { run_command(all: true, only: "docs") }
      assert_includes error.message, "mutually exclusive"
      cmd, = command(json: true)
      assert_equal "internal", cmd.envelope_error_kind(RuntimeError.new)
      assert_equal "config", cmd.envelope_error_kind(Hive::ConfigError.new)
      assert_equal "agent", cmd.envelope_error_kind(Hive::AgentError.new)
    end
  end

  def test_closed_input_is_not_interactive
    input = Object.new
    def input.tty? = raise(IOError, "closed stream")
    with_catalog do
      assert_raises(Hive::Commands::Mcp::ConsentRequired) { run_command(input: input) }
    end
  end

  # --- login ----------------------------------------------------------------

  def test_login_runs_the_agent_flow_and_records_the_login
    with_catalog(CATALOG.merge("writero" => { "url" => "https://writero.app/mcp", "oauth_resource" => "https://writero.app/mcp",
                                              "oauth_scopes" => %w[read write], "oauth_logins" => [] })) do |home|
      code, stdout, _err, calls = run_command("login", "writero", agent: "codex", input: Tty.new)
      assert_equal 0, code
      assert_equal [
        Hive::AgentProfiles.lookup(:codex).bin, "mcp", "login", "writero",
        "-c", 'mcp_servers.writero.url="https://writero.app/mcp"',
        "-c", 'mcp_servers.writero.oauth_resource="https://writero.app/mcp"',
        "--scopes", "read,write"
      ], calls.first
      assert_includes stdout, "codex is signed in to writero"
      assert_equal [ "codex" ], global_config(home).dig("mcp", "servers", "writero", "oauth_logins")

      _code, _out, _err, calls = run_command("login", "relog", agent: "claude", input: Tty.new)
      assert_equal [ Hive::AgentProfiles.lookup(:claude).bin, "mcp", "login", "relog" ], calls.first
      assert_equal [ "claude" ], global_config(home).dig("mcp", "servers", "relog", "oauth_logins")
    end
  end

  def test_login_refusals
    with_catalog do
      {
        [ { json: true }, nil ] => "no JSON mode",
        [ { agent: "codex", input: Tty.new }, nil ] => "name the catalog SERVER",
        [ { agent: "pi", input: Tty.new }, "relog" ] => "--agent must be one of codex, claude",
        [ { agent: "codex" }, "relog" ] => "needs a terminal",
        [ { agent: "codex", input: Tty.new }, "absent" ] => "not in the global MCP catalog",
        [ { agent: "codex", input: Tty.new }, "same" ] => "is a stdio server"
      }.each do |(options, server), message|
        error = assert_raises(Hive::UsageError) { run_command("login", server, **options) }
        assert_includes error.message, message
      end
      error = assert_raises(Hive::AgentError) do
        run_command("login", "relog", agent: "codex", input: Tty.new, runner: ->(_argv) { false })
      end
      assert_includes error.message, "did not complete"
    end
  end

  def test_record_login_requires_a_catalog_entry
    with_catalog do
      assert_raises(Hive::ConfigError) { Hive::Mcp::Importer.record_login!("absent", "codex") }
    end
  end

  # --- setup/init offer -----------------------------------------------------

  def test_offer_is_asked_once_and_runs_the_import_when_accepted
    with_catalog do |home|
      error = StringIO.new
      ran = []
      import = ->(*) { ran << true; Struct.new(:call).new(0) }
      with_replaced_singleton_method(Hive::Commands::Mcp, :new, import) do
        assert Hive::Mcp::ImportOffer.run(cwd: Dir.pwd, input: StringIO.new("y\n"), output: StringIO.new,
                                          error: error, discover: ->(_dir) { discovered })
      end
      assert_equal [ true ], ran
      assert_includes error.string, "Found 2 personal MCP server(s)"
      assert_equal true, global_config(home).dig("mcp", "import_offered")

      refute Hive::Mcp::ImportOffer.run(cwd: Dir.pwd, input: StringIO.new("y\n"), output: StringIO.new,
                                        error: StringIO.new, discover: ->(_dir) { raise "not asked again" })
    end
  end

  def test_offer_declined_or_empty_or_broken
    with_catalog do |home|
      error = StringIO.new
      refute Hive::Mcp::ImportOffer.run(cwd: Dir.pwd, input: StringIO.new("n\n"), output: StringIO.new,
                                        error: error, discover: ->(_dir) { discovered })
      assert_includes error.string, "Run `hive mcp import` any time"
      assert_equal true, global_config(home).dig("mcp", "import_offered")
    end

    with_catalog do |home|
      refute Hive::Mcp::ImportOffer.run(cwd: Dir.pwd, input: StringIO.new, output: StringIO.new, error: StringIO.new,
                                        discover: ->(_dir) { Result.new(candidates: [], notices: []) })
      assert_nil global_config(home).dig("mcp", "import_offered")
    end

    with_catalog do
      error = StringIO.new
      refute Hive::Mcp::ImportOffer.run(cwd: Dir.pwd, input: StringIO.new, output: StringIO.new, error: error,
                                        discover: ->(_dir) { raise Hive::ConfigError, "bad catalog" })
      assert_includes error.string, "skipped the MCP import offer (bad catalog)"
    end
  end

  def test_setup_and_init_offer_only_in_a_terminal
    require "hive/commands/setup"
    require "hive/commands/init"
    calls = []
    offer = ->(**kwargs) { calls << kwargs; false }
    with_replaced_singleton_method(Hive::Mcp::ImportOffer, :run, offer) do
      Hive::Commands::Setup.new(mcp_import_offer: true, input: Tty.new).send(:offer_mcp_import)
      Hive::Commands::Setup.new(mcp_import_offer: true, input: Tty.new, yes: true).send(:offer_mcp_import)
      Hive::Commands::Setup.new(mcp_import_offer: true, input: StringIO.new).send(:offer_mcp_import)
      Hive::Commands::Setup.new(input: Tty.new).send(:offer_mcp_import)
      Hive::Commands::Init.new(Dir.pwd, mcp_import_offer: true, provisioning_input: Tty.new).send(:offer_mcp_import!)
      Hive::Commands::Init.new(Dir.pwd, mcp_import_offer: true, provisioning_input: StringIO.new).send(:offer_mcp_import!)
    end
    assert_equal 2, calls.size
    assert_equal File.expand_path(Dir.pwd), calls.last.fetch(:cwd)
  end

  def test_mark_offered_and_global_import_offered_validation
    with_catalog do |home|
      Hive::Mcp::Importer.mark_offered!
      assert_equal true, Hive::Config.load_global_mcp.fetch("import_offered")
      File.write(File.join(home, "config.yml"), { "mcp" => { "import_offered" => "yes" } }.to_yaml)
      error = assert_raises(Hive::ConfigError) { Hive::Config.load_global_mcp }
      assert_includes error.message, "mcp.import_offered"
    end
  end

  def test_apply_rejects_a_non_hash_mcp_block
    with_catalog do |home|
      File.write(File.join(home, "config.yml"), { "mcp" => "none" }.to_yaml)
      row = Hive::Mcp::Importer.plan(discovered, {}).find { |item| item.id == "docs" }
      assert_raises(Hive::ConfigError) { Hive::Mcp::Importer.apply!([ row ]) }
    end
  end

  def test_usage_contract_is_declared
    contract = Hive::CliUsageContracts.contract(%w[mcp import --bogus])
    assert_equal({ schema: "hive-mcp-import", error_kind: "usage" }, contract)
  end
end
