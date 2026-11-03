require "hive/workflow_package/registry_manifest_builder"
require "hive/workflow_package/source_snapshot"
require "hive/workflow_package/publisher"

module CanonicalManifestHelpers
  FIXTURES = File.expand_path("../fixtures/workflow_package", __dir__)

  def manifest_fixture(name)
    filename = name == "canonical_with_recommendations" ? "canonical_honeycomb_manifest_with_recommendations_v1.yml" : "#{name}_honeycomb_manifest_v1.yml"
    File.binread(File.join(FIXTURES, filename))
  end

  def canonical_builder(destination, reverse: false)
    metadata = Data.define(:description, :author, :license, :hive_min_version, :source).new(
      description: "Demo", author: { "name" => "Test", "url" => "https://example.test/test" },
      license: "MIT", hive_min_version: "0.4.3",
      source: { "url" => "https://example.test/source", "revision" => "c" * 40 }
    )
    files = canonical_payloads.to_h do |path, bytes|
      [ path, Hive::WorkflowPackage::SourceSnapshot::FileRecord.new(
        path: path, bytes: bytes, mode: path.start_with?("tools/") ? 0o755 : 0o644, source: path
      ) ]
    end
    if reverse
      metadata = metadata.with(author: metadata.author.to_a.reverse.to_h, source: metadata.source.to_a.reverse.to_h)
      files = files.to_a.reverse.to_h
    end
    input = { "name" => "CONTEXT", "authorized_slots" => [ "stages.work" ] }
    input = input.to_a.reverse.to_h if reverse
    snapshot = Hive::WorkflowPackage::SourceSnapshot::Snapshot.new(
      name: "demo", descriptor: YAML.safe_load(canonical_payloads.fetch("workflow.yml")), files: files,
      tools: [ "tools/check.sh" ], prompt_assets: [ "prompts/context.md" ],
      optional_inputs: [ input ],
      external_skills: [ "external/reviewer" ]
    )
    Hive::WorkflowPackage::RegistryManifestBuilder.build!(
      destination: destination, name: "demo", version: "1.0.0", metadata: metadata, snapshot: snapshot
    )
  end

  def canonical_payloads
    {
      "README.md" => "# Demo\n",
      "instructions/work.md" => "Read files only.\n",
      "prompts/context.md" => "Context\n",
      "tools/check.sh" => "#!/bin/sh\n",
      "workflow.yml" => <<~YAML
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            advance_verb: work
            instruction: instructions/work.md
            permissions: read-only
            mapping_role: development
            mapping_contract: demo-work-v1
          - name: review
            kind: agent
            state_file: review.md
            advance_verb: review
            skill: external/reviewer
            permissions: read-only
            mapping_role: development
            mapping_contract: demo-review-v1
          - name: done
            kind: terminal
            state_file: done.md
            advance_verb: done
      YAML
    }
  end
  def fixture_package(destination, name, canonicalize: false)
    canonical_payloads.each do |path, bytes|
      target = File.join(destination, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, bytes)
      File.chmod(0o755, target) if path.start_with?("tools/")
    end
    bytes = manifest_fixture(name)
    if canonicalize
      data = YAML.safe_load(bytes)
      data["release_sha256"] = Digest::SHA256.hexdigest(
        Hive::WorkflowPackage::CanonicalYAML.dump_manifest(data, include_release: false)
      )
      bytes = Hive::WorkflowPackage::CanonicalYAML.dump_manifest(data)
    end
    File.binwrite(File.join(destination, "manifest.yml"), bytes)
    manifest = Hive::WorkflowPackage::RegistryManifest.load_bytes(bytes)
    Hive::WorkflowPackage::Publisher::Package.new(
      name: "demo", version: "1.0.0", root: destination,
      package_digest: Digest::SHA256.hexdigest(bytes), release_digest: manifest.digest,
      lint_contract: {
        "version" => "v1", "upstream_commit" => "a" * 40,
        "upstream_policy_sha256" => "c" * 64, "fixture_corpus_sha256" => "d" * 64,
        "expected_output_sha256" => "e" * 64, "contract_sha256" => "b" * 64
      }
    )
  end
end
