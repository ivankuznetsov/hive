# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require_relative "../support/release_documentation"

class ReleaseDocumentationTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)
  URL = "https://raw.githubusercontent.com/ivankuznetsov/hive/v9.9.9/install.sh"
  VERIFY = "packaging/verify-release.sh"
  INSTALL = %(curl -fsSL #{URL} -o "$tmpdir/hive-install.sh")
  RUN_INSTALL = 'bash "$tmpdir/hive-install.sh"'
  PLAIN = "#{VERIFY} --version=v9.9.9"
  JSON_REPORT = "#{PLAIN} --report=json | jq .ok"
  CLAIM = "Current release: `v9.9.9`"
  README = <<~MD
    ## Install

    | Platform | Channel |
    |----------|---------|
    | Linux | <code>#{INSTALL} && #{RUN_INSTALL}</code> |
  MD
  OPERATING = <<~MD
    ## Install

    Channels:

    ```bash
    #{INSTALL}
    #{RUN_INSTALL}
    ```

    ## Release verification

    [`packaging/verify-release.sh`](../packaging/verify-release.sh)
    Every `install.sh` / `verify-release.sh` GitHub download uses curl.

    ```bash
    #{PLAIN}
    #{JSON_REPORT}
    ```
  MD
  TESTING = <<~'MD'
    The install-smoke workflow's `verify-release.sh (end-to-end behavior)` job
    runs `packaging/verify-release.sh --version=v0.1.0` against its pinned historical baseline.
  MD
  INVENTORY = <<~MD
    | `64b11b41` | Release | Prepares v0.3.0. |

    ## What exists

    | Area | Files | Status |
    |------|-------|--------|
    | Release/install | `install.sh` | #{CLAIM}. |
    | Agent runtime | agent-cli-runtime | v0.2.5 |
  MD
  DOCUMENTS = {
    "README.md" => README,
    "wiki/operating.md" => OPERATING,
    "wiki/testing.md" => TESTING,
    "wiki/active-areas.md" => INVENTORY
  }.freeze

  def test_committed_documentation_matches_runtime_version_and_is_read_only
    contents = -> { DOCUMENTS.keys.map { |path| File.binread(File.join(ROOT, path)) } }
    before = contents.call
    errors = HiveReleaseDocumentation.check(ROOT)
    assert errors.empty?, errors.join("\n")
    assert_equal before, contents.call
  end

  def test_synthetic_release_examples_and_historical_records
    assert_empty check
    historical = INVENTORY.sub("Prepares v0.3.0.", "Verified with `#{VERIFY} --version=v0.3.0`.")
    assert_empty check("wiki/active-areas.md" => historical)
    # Link labels and shell arguments that name the verifier are mentions.
    assert_empty in_testing("[run `#{VERIFY} --help` here](../packaging/verify-release.sh)\n" \
                            "```sh\nprintf '%s' #{VERIFY} --help\n```")
  end

  def test_complete_installer_tokens_including_siblings_in_either_order
    [ URL.sub("raw.", "evilraw."), "#{URL}.bak" ].each do |bad|
      [ [ bad, URL ], [ URL, bad ] ].each do |pair|
        errors = in_testing("`curl -fsSL #{pair.join(' ')}`")
        assert_one_error errors, "installer", bad, URL
      end
    end
  end

  def test_installer_url_must_match_every_literal_segment
    [ URL.sub("https:", "http:"), URL.sub("/hive/", "/other/"),
      URL.sub("v9.9.9", "main"), URL.sub("v9.9.9", "v0.7.0"),
      URL.sub("v9.9.9", "v9.9.9-rc.1"), "#{URL}?download", "#{URL}#latest",
      "#{URL}/extra", URL.sub("v9.9.9", "$TAG"), "$INSTALL_URL" ].each do |bad|
      assert_one_error in_testing("`curl -fsSL \"#{bad}\" | sh`"), "installer", bad, URL
    end
    assert_empty in_testing("`curl -fsSL '#{URL}' | bash`")
    assert_one_error in_testing("`curl -fsSL \"#{URL}\".bak | bash`"), "installer", "#{URL}.bak"
    assert_one_error in_testing("[installer](#{URL}.old)"), "installer", "#{URL}.old"
  end

  def test_executed_curl_destination_identifies_installer_with_wrong_source_name
    bad = URL.sub("install.sh", "setup.sh")
    extra = <<~MD

      ```sh
      curl -fsSL #{bad} -o "$tmpdir/install.sh"
      sh "$tmpdir/install.sh"
      ```
      ```sh
      curl -s "https://api.telegram.org/bot${HIVE_TELEGRAM_BOT_TOKEN}/getUpdates" |
        jq .
      ```
    MD
    line = README.lines.size + 3
    assert_one_error check("README.md" => README + extra), "README.md:#{line}:", "installer", bad, URL
  end

  def test_quoted_verifier_versions_and_whole_argument_suffixes
    assert_empty in_testing("`#{VERIFY} --version=\"v9.9.9\"`")
    assert_empty in_testing("<code>#{VERIFY} --version='v9.'9.9</code>")
    assert_one_error in_testing("`#{PLAIN}; #{VERIFY} --version=v1.0.0`"), "verifier", "--version=v1.0.0"
    [ "--version=v9.9.9.bak", '--version="v9.9.9".bak' ].each do |option|
      assert_one_error in_testing("```sh\n#{PLAIN} && #{VERIFY} #{option} --report=json | jq .ok\n```"),
                       "verifier", "v9.9.9.bak", "v9.9.9"
    end
  end

  def test_every_verifier_option_in_the_same_command
    bad = "--version=v0.7.0"
    [ "#{bad} --version=v9.9.9", "--version=v9.9.9 #{bad}" ].each do |options|
      assert_one_error in_testing("`#{VERIFY} #{options}`"), "verifier", bad, "v9.9.9"
    end
  end

  def test_direct_shell_and_operator_command_positions_require_a_version
    [ VERIFY, "bash #{VERIFY}", "sh ./#{VERIFY}", "true && #{VERIFY}", "echo ok;#{VERIFY}",
      "true | bash #{VERIFY} --report=json" ].each do |command|
      assert_one_error in_testing("```sh\n#{command}\n```"), "verifier", "missing", "--version=v9.9.9"
    end
    assert_one_error in_testing("<code>#{VERIFY} --help</code>"), "verifier", "missing"
  end

  def test_inline_commands_and_unsupported_versions
    [ "`#{VERIFY} --version=v0.7.0`", "<code>#{VERIFY} --version=v0.7.0</code>" ].each do |example|
      assert_one_error in_testing(example), "verifier", "--version=v0.7.0", "v9.9.9"
    end
    [ "--version=", "--version=$TAG", "--version=v9.9.9-rc.1",
      "--version v9.9.9" ].each do |option|
      assert_one_error in_testing("`#{VERIFY} #{option}`"), "verifier", option, "--version=v9.9.9"
    end
  end

  def test_the_pinned_exception_covers_only_its_exact_historical_invocation
    old = "#{VERIFY} --version=v0.1.0"
    assert_one_error in_testing("`#{old}`"), "verifier", "--version=v0.1.0"
    with_sibling = TESTING.sub(" against", " and `#{old}` against")
    assert_one_error check("wiki/testing.md" => with_sibling), "wiki/testing.md:2:", "--version=v0.1.0"
    assert_one_error check("wiki/testing.md" => TESTING.sub("v0.1.0", "v0.1.0.bak")),
                     "wiki/testing.md:2:", "--version=v0.1.0.bak"
  end

  def test_required_commands_cannot_be_supplied_outside_their_slots
    outside = "\n## Elsewhere\n\n```bash\n#{INSTALL}\n#{RUN_INSTALL}\n#{PLAIN}\n#{JSON_REPORT}\n```\n"
    [
      [ "README.md", README.sub(INSTALL, URL), "installation table", URL ],
      [ "wiki/operating.md", OPERATING.sub(INSTALL, URL), "Channels", URL ],
      [ "wiki/operating.md", OPERATING.sub("#{PLAIN}\n", ""), "plain verifier", "--version=v9.9.9" ],
      [ "wiki/operating.md", OPERATING.sub(JSON_REPORT, ""), "JSON verifier", "--report=json" ],
      [ "wiki/active-areas.md", INVENTORY.lines.reject { |line| line.include?(CLAIM) }.join, "Release/install", CLAIM ]
    ].each do |path, body, slot, expected|
      assert_one_error check(path => body + outside), path, slot, "missing", expected
    end
  end

  def test_missing_sections_file_and_invalid_encoding_have_a_location
    errors = check("wiki/operating.md" => "")
    assert_equal 3, errors.size, errors.inspect
    errors.each { |error| assert_includes error, "wiki/operating.md:1: " }
    assert_one_error check("wiki/active-areas.md" => "other"), "wiki/active-areas.md:1:", "What exists"
    assert_one_error check("README.md" => nil), "README.md:1:", "missing"
    assert_one_error check("wiki/testing.md" => "intro\n\xFF".b), "wiki/testing.md:2:", "UTF-8"
  end

  def test_inventory_marker_and_other_tags_are_checked_independently
    { "Hive `v9.9.9`" => "missing", "#{CLAIM}. #{CLAIM}" => "duplicate",
      "Current release: v9.9.9" => "backtick", "Current release: `v9.9.9.bak`" => "v9.9.9.bak",
      "#{CLAIM}. Hive v0.5.3 release prep." => "v0.5.3" }.each do |claim, reason|
      assert_one_error check("wiki/active-areas.md" => INVENTORY.sub(CLAIM, claim)),
                       "wiki/active-areas.md:7:", reason, CLAIM
    end
    assert_one_error check("wiki/active-areas.md" => INVENTORY.sub(CLAIM, "#{CLAIM} (v9.9.9)")),
                     "additional release tag", CLAIM
    row = INVENTORY.lines.fetch(6)
    assert_one_error check("wiki/active-areas.md" => INVENTORY + row), "duplicate", "Release/install"
  end

  def test_aggregates_failures_in_path_and_line_order
    bad = URL.sub("v9.9.9", "main")
    errors = check("README.md" => README + "\n`#{bad}`\n",
                   "wiki/testing.md" => TESTING + "\n`#{VERIFY} --version=old`\n`#{VERIFY} --help`\n")
    assert_equal 3, errors.size, errors.inspect
    assert_match(/README\.md:7: .*installer.*main/, errors[0])
    assert_match(/wiki\/testing\.md:4: .*verifier.*--version=old/, errors[1])
    assert_match(/wiki\/testing\.md:5: .*verifier.*missing/, errors[2])
  end

  def test_changing_the_authority_requires_updating_all_current_references
    with_documents(DOCUMENTS) do |root|
      errors = HiveReleaseDocumentation.check(root, version: "10.0.0")
      assert_equal 5, errors.count { |error| error.include?("v9.9.9") }, errors.inspect
    end
    updated = DOCUMENTS.transform_values { |body| body.gsub("v9.9.9", "v10.0.0") }
    with_documents(updated) { |root| assert_empty HiveReleaseDocumentation.check(root, version: "10.0.0") }
  end

  def test_c_locale_subprocess_reads_utf8
    documents = DOCUMENTS.transform_values { |body| "Résumé — 日本語\n\n" + body }
    with_documents(documents) do |root|
      script = 'errors = HiveReleaseDocumentation.check(ARGV.fetch(0), version: "9.9.9"); abort errors.join("\n") unless errors.empty?'
      output, status = Open3.capture2e({ "LC_ALL" => "C" }, RbConfig.ruby,
                                      "-r#{ROOT}/test/support/release_documentation", "-e", script, root)
      assert_predicate status, :success?, output
    end
  end

  private

  def check(overrides = {})
    with_documents(DOCUMENTS.merge(overrides)) { |root| HiveReleaseDocumentation.check(root, version: "9.9.9") }
  end

  def in_testing(example)
    check("wiki/testing.md" => "#{TESTING}\n#{example}\n")
  end

  def with_documents(documents)
    with_tmp_dir do |root|
      FileUtils.mkdir_p(File.join(root, "wiki"))
      documents.each { |path, body| File.binwrite(File.join(root, path), body) if body }
      yield root
    end
  end

  def assert_one_error(errors, *parts)
    assert_equal 1, errors.size, errors.inspect
    parts.each { |part| assert_includes errors.first, part }
  end
end
