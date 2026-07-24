require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "hive/agent_skills/canonical_skill"

class AgentSkillsCanonicalSkillTest < Minitest::Test
  ROOT = File.expand_path("../../../skills/hive", __dir__)
  OPENCLAW_ROOT = File.expand_path("../../../openclaw/skills/hive", __dir__)

  def test_canonical_metadata_frontmatter_and_references_are_strict
    skill = Hive::AgentSkills::CanonicalSkill.new

    assert_equal "hive", skill.name
    assert_equal "0.1.3", skill.version
    assert_match(/\A[0-9a-f]{64}\z/, skill.canonical_digest)
    assert_equal %w[description name], skill.frontmatter.keys.sort
    assert_operator skill.body.lines.size, :<, 120
    assert_equal 13, skill.reference_paths.size
    assert skill.reference_paths.all? { |path| path.start_with?("references/") }
    refute_includes skill.rendered_canonical_files.values.join("\n"), "{{HIVE_VERSION}}"
    assert_includes skill.rendered_canonical_files.fetch("references/setup-and-platforms.md"),
                    "/v#{Hive::VERSION}/install.sh"
  end

  def test_workflow_creator_contract_gates_mutation_and_reports_every_side_effect
    files = Hive::AgentSkills::CanonicalSkill.new.rendered_canonical_files
    route = files.fetch("SKILL.md")
    creator = files.fetch("references/workflow-creator.md")

    assert_includes route, "hive-workflow-creator"
    assert_includes creator, "minimum Hive version: #{Hive::VERSION}"
    assert_operator creator.index("hive version"), :<, creator.index("hive workflow list --json")
    assert_operator creator.index("hive workflow list --json"), :<, creator.index("hive workflow new")
    assert_operator creator.index("hive workflow validate"), :<, creator.index("hive workflow commit")
    assert_operator creator.index("hive workflow commit"), :<, creator.index("hive new")
    assert_includes creator, "No task by default"
    assert_includes creator, "created files"
    assert_includes creator, "applied defaults"
    assert_includes creator, "validation result"
    assert_includes creator, "hive update"
    assert_includes creator, "idempotency-key"
    assert_includes creator, "workflow-creator:v1:<64 lowercase hex>"
    assert_includes creator, "JSON.generate([project, workflow, request])"
    assert_includes creator, "POSIX `Shellwords.escape` semantics"
    assert_includes creator, %q(replace each embedded `'` with the exact shell sequence `'"'"'`)
    assert_includes creator, "Never publish externally"
    refute_match(/hive init[^\n]*--force/, creator)
  end

  def test_four_platform_projections_share_payload_but_keep_thin_wrappers
    skill = Hive::AgentSkills::CanonicalSkill.new
    projections = %w[openclaw claude codex pi].to_h do |platform|
      [ platform, skill.render(platform) ]
    end

    assert_equal({
      "openclaw" => "/hive", "claude" => "/hive",
      "codex" => "$hive", "pi" => "/skill:hive"
    }, projections.transform_values(&:invocation))
    assert_equal [ skill.version ], projections.values.map(&:skill_version).uniq
    assert_equal [ skill.canonical_digest ], projections.values.map(&:canonical_digest).uniq
    refute_equal projections.fetch("openclaw").files.fetch("SKILL.md"),
                 projections.fetch("claude").files.fetch("SKILL.md")
    refute_equal projections.fetch("claude").files.fetch("SKILL.md"),
                 projections.fetch("pi").files.fetch("SKILL.md")

    skill.reference_paths.each do |path|
      assert_equal 1, projections.values.map { |projection| projection.files.fetch(path) }.uniq.size
    end
    assert projections.fetch("codex").files.key?("agents/openai.yaml")
    refute projections.fetch("claude").files.key?("agents/openai.yaml")

    projections.each do |platform, projection|
      assert_equal platform, projection.to_h.fetch("platform")
      assert_equal projection.files.keys.sort, projection.to_h.fetch("files")
      manifest = JSON.parse(projection.files.fetch(".hive-skill.json"))
      assert_equal platform, manifest.fetch("platform")
      assert_equal projection.invocation, manifest.fetch("invocation")
      assert_equal skill.version, manifest.fetch("skill_version")
      assert_equal skill.canonical_digest, manifest.fetch("canonical_digest")
      manifest.fetch("files").each do |path, digest|
        assert_equal Digest::SHA256.hexdigest(projection.files.fetch(path)), digest
      end
    end
  end

  def test_committed_openclaw_projection_byte_matches_renderer
    expected = Hive::AgentSkills::CanonicalSkill.new.render("openclaw").files
    actual = Dir.glob(File.join(OPENCLAW_ROOT, "**", "*"), File::FNM_DOTMATCH)
                .select { |path| File.file?(path) }
                .to_h do |path|
      [ path.delete_prefix("#{OPENCLAW_ROOT}/"), File.read(path, encoding: Encoding::UTF_8) ]
    end

    assert_equal expected.keys.sort, actual.keys.sort
    expected.each { |path, content| assert_equal content, actual.fetch(path), path }
  end

  def test_policy_uses_native_operational_status_watch_and_closed_actions
    text = Hive::AgentSkills::CanonicalSkill.new.rendered_canonical_files.values.join("\n")

    assert_includes text, "hive status --operational --json"
    assert_includes text, "hive watch"
    assert_includes text, "--json-lines"
    assert_includes text, "risk_class: routine_idempotent"
    assert_includes text, "confirmation_required: false"
    assert_includes text, "hive act ACTION_ID"
    assert_includes text, "Request another operational snapshot after any action"
    assert_includes text, "separate explicit release request"

    %w[HIVE_WATCH_INTERVAL HIVE_WATCH_TIMEOUT mapfile].each do |legacy|
      refute_includes text, legacy
    end
    refute_match(/pgrep\s+-af|kill\s+-0|while\s+:/, text)
  end

  def test_policy_preserves_consent_safe_setup_and_host_boundaries
    text = Hive::AgentSkills::CanonicalSkill.new.rendered_canonical_files.values.join("\n")

    assert_includes text, "hive setup --no-init --yes --json"
    assert_includes text, "hive setup-agents --json"
    assert_includes text, "hive setup-agents --yes --json"
    assert_includes text, "their own real terminal"
    assert_match(/non-TTY `hive init`.*medium patrol.*pull requests/im, text)
    assert_includes text, "openclaw skills install @ivankuznetsov/hive-cli"
    assert_includes text, "Never patch an installed Hive runtime"
    assert_includes text, "workflow install honeycomb/NAME --dry-run --json"
    assert_match(/patrol.*--dry-run.*still launch agents/im, text)

    refute_match(/(?:yay|paru)[^\n]*--noconfirm/, text)
    refute_includes text, "cat > ~/.config/systemd"
    refute_includes text, "systemctl --user edit"
  end

  def test_rejects_escaping_or_missing_canonical_references
    with_canonical_copy do |root|
      metadata = JSON.parse(File.read(File.join(root, "skill.json")))
      metadata.fetch("references") << "../outside.md"
      File.write(File.join(root, "skill.json"), JSON.pretty_generate(metadata))

      error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
        Hive::AgentSkills::CanonicalSkill.new(root: root).reference_paths
      end
      assert_match(/safe reference/, error.message)
    end

    with_canonical_copy do |root|
      FileUtils.rm_f(File.join(root, "references", "recovery.md"))
      error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
        Hive::AgentSkills::CanonicalSkill.new(root: root).canonical_digest
      end
      assert_match(/missing reference/, error.message)
    end
  end

  def test_rejects_invalid_metadata_contracts
    invalid_documents = [
      [ ->(document) { document["unexpected"] = true }, /contain exactly/ ],
      [ ->(document) { document["schema_version"] = 2 }, /identity or schema version/ ],
      [ ->(document) { document["references"] << document.fetch("references").first }, /unique array/ ],
      [ ->(document) { document["version"] = "not a version!" }, /version must be semantic/ ]
    ]

    invalid_documents.each do |mutate, message|
      with_canonical_copy do |root|
        path = File.join(root, "skill.json")
        document = JSON.parse(File.read(path))
        mutate.call(document)
        File.write(path, JSON.pretty_generate(document))

        error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
          Hive::AgentSkills::CanonicalSkill.new(root: root).metadata
        end
        assert_match message, error.message
      end
    end

    with_canonical_copy do |root|
      File.write(File.join(root, "skill.json"), "{")

      error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
        Hive::AgentSkills::CanonicalSkill.new(root: root).metadata
      end
      assert_match(/skill\.json is invalid/, error.message)
    end
  end

  def test_rejects_invalid_frontmatter_contracts
    invalid_skills = [
      [ "---\nname: hive\ndescription: valid\nextra: true\n---\nbody\n", /contain only name and description/ ],
      [ "---\nname: other\ndescription: valid\n---\nbody\n", /name or description is invalid/ ],
      [ "---\nname: [\n---\nbody\n", /frontmatter is invalid/ ]
    ]

    invalid_skills.each do |content, message|
      with_canonical_copy do |root|
        File.write(File.join(root, "SKILL.md"), content)

        error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
          Hive::AgentSkills::CanonicalSkill.new(root: root).frontmatter
        end
        assert_match message, error.message
      end
    end
  end

  def test_rejects_reference_inventory_drift_and_unknown_templates
    with_canonical_copy do |root|
      File.write(File.join(root, "references", "undeclared.md"), "undeclared\n")

      error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
        Hive::AgentSkills::CanonicalSkill.new(root: root).reference_paths
      end
      assert_match(/declared references do not match canonical files/, error.message)
    end

    with_canonical_copy do |root|
      path = File.join(root, "SKILL.md")
      File.write(path, File.read(path).sub(/\n\z/, "\n{{UNKNOWN_TEMPLATE}}\n"))

      error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
        Hive::AgentSkills::CanonicalSkill.new(root: root).body
      end
      assert_match(/unknown template variable/, error.message)
    end
  end

  def test_rejects_missing_or_escaping_top_level_sources
    with_canonical_copy do |root|
      FileUtils.rm_f(File.join(root, "skill.json"))

      error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
        Hive::AgentSkills::CanonicalSkill.new(root: root).metadata
      end
      assert_match(/cannot read skill\.json/, error.message)
    end

    Dir.mktmpdir("hive-canonical-outside") do |dir|
      outside = File.join(dir, "outside.json")
      File.write(outside, "{}")

      with_canonical_copy do |root|
        source = File.join(root, "skill.json")
        FileUtils.rm_f(source)
        File.symlink(outside, source)

        error = assert_raises(Hive::AgentSkills::CanonicalSkill::ValidationError) do
          Hive::AgentSkills::CanonicalSkill.new(root: root).metadata
        end
        assert_match(/source path escapes canonical skill root/, error.message)
      end
    end
  end

  private

  def with_canonical_copy
    Dir.mktmpdir("hive-canonical-skill") do |dir|
      root = File.join(dir, "hive")
      FileUtils.cp_r(ROOT, root)
      yield root
    end
  end
end
