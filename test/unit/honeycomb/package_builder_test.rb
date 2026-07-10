require "test_helper"
require "hive/honeycomb/package_builder"
require "hive/workflows/descriptor_parser"

class HoneycombPackageBuilderTest < Minitest::Test
  include HiveTestHelper

  def test_builds_rebased_tree_with_shared_instruction_assets_readme_and_manifest
    with_publishable_fixture do |source, descriptor_path, workflow|
      with_tmp_dir do |out|
        package = Hive::Honeycomb::PackageBuilder.build(
          workflow: workflow,
          descriptor_path: descriptor_path,
          output_dir: out,
          cfg: { "review" => { "agent" => "codex" } }
        )

        assert_equal File.join(out, "workflows", "sample"), package.package_root
        assert_equal %w[
          README.md
          assets/diagram.txt
          manifest.yml
          nested/revise.md
          shared.md
          workflow.yml
        ], package.files
        assert_equal "shared instructions\n", File.read(File.join(package.package_root, "shared.md"))
        descriptor = YAML.safe_load(File.read(File.join(package.package_root, "workflow.yml")))
        assert_equal "./shared.md", descriptor.fetch("stages")[1].fetch("instruction")
        reviewer = descriptor.fetch("stages")[2].fetch("reviewers").first
        assert_equal "./shared.md", reviewer.fetch("instruction")
        assert_equal "./nested/revise.md",
                     descriptor.fetch("stages")[2].fetch("council").fetch("revise").fetch("instruction")
        assert_equal [ "./assets/diagram.txt" ], descriptor.fetch("metadata").fetch("assets")
        assert_includes File.read(File.join(package.package_root, "README.md")), "# sample"
        assert_includes File.read(File.join(package.package_root, "README.md")), "Minimum Hive version"
        assert_equal %w[stage:draft stage:review/reviewer:shared],
                     package.owners.fetch("shared.md")
        assert_equal "codex", package.dependencies.find { |row| row.fetch("skill") == "/review" }
                                               .fetch("agent")
      end
    end
  end

  def test_author_readme_is_copied_verbatim
    with_publishable_fixture(readme: true) do |_source, descriptor_path, workflow|
      with_tmp_dir do |out|
        package = Hive::Honeycomb::PackageBuilder.build(
          workflow: workflow, descriptor_path: descriptor_path, output_dir: out
        )
        assert_equal "Author supplied\n\x00bytes".b,
                     File.binread(File.join(package.package_root, "README.md"))
      end
    end
  end

  def test_author_readme_may_use_the_reserved_output_name_at_its_source
    with_publishable_fixture(readme: true) do |_source, descriptor_path, workflow|
      owned = File.join(File.dirname(descriptor_path), "sample")
      FileUtils.mv(File.join(owned, "README.source.md"), File.join(owned, "README.md"))
      File.write(descriptor_path, File.read(descriptor_path).sub("README.source.md", "README.md"))
      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)

      with_tmp_dir do |out|
        package = Hive::Honeycomb::PackageBuilder.build(
          workflow: workflow, descriptor_path: descriptor_path, output_dir: out
        )
        assert_equal "Author supplied\n\x00bytes".b,
                     File.binread(File.join(package.package_root, "README.md"))
      end
    end
  end

  def test_rejects_outside_paths_and_escaping_symlinks
    with_tmp_dir do |dir|
      workflows = File.join(dir, "workflows")
      owned = File.join(workflows, "unsafe")
      FileUtils.mkdir_p(owned)
      outside = File.join(dir, "outside.md")
      File.write(outside, "outside\n")

      [ outside, File.join(owned, "escape.md") ].each_with_index do |instruction, index|
        File.symlink(outside, instruction) if index == 1
        descriptor_path = File.join(workflows, "unsafe.yml")
        File.write(descriptor_path, unsafe_descriptor(instruction))
        workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)

        with_tmp_dir do |out|
          error = assert_raises(Hive::ConfigError) do
            Hive::Honeycomb::PackageBuilder.build(
              workflow: workflow, descriptor_path: descriptor_path, output_dir: out
            )
          end
          assert_match(/outside owned workflow directory/, error.message)
          refute File.exist?(File.join(out, "workflows", "unsafe"))
        end
      ensure
        FileUtils.rm_f(File.join(owned, "escape.md"))
      end
    end
  end

  def test_rejects_reserved_output_names_and_duplicate_asset_targets
    with_tmp_dir do |dir|
      workflows = File.join(dir, "workflows")
      owned = File.join(workflows, "reserved")
      FileUtils.mkdir_p(owned)
      File.write(File.join(owned, "workflow.yml"), "asset\n")
      descriptor_path = File.join(workflows, "reserved.yml")
      File.write(descriptor_path, <<~YAML)
        id: reserved
        metadata:
          version: 1.0.0
          author: Author
          description: Reserved target
          minimum_hive_version: 0.3.7
          assets: [./reserved/workflow.yml]
        stages:
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)

      with_tmp_dir do |out|
        error = assert_raises(Hive::ConfigError) do
          Hive::Honeycomb::PackageBuilder.build(
            workflow: workflow, descriptor_path: descriptor_path, output_dir: out
          )
        end
        assert_match(/reserved output name/, error.message)
      end

      File.write(descriptor_path, File.read(descriptor_path).sub(
        "assets: [./reserved/workflow.yml]",
        "assets: [./reserved/workflow.yml, ./reserved/workflow.yml]"
      ))
      workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
      with_tmp_dir do |out|
        error = assert_raises(Hive::ConfigError) do
          Hive::Honeycomb::PackageBuilder.build(
            workflow: workflow, descriptor_path: descriptor_path, output_dir: out
          )
        end
        assert_match(/duplicate packaged path|reserved output name/, error.message)
      end
    end
  end

  def test_identical_builds_are_byte_for_byte_deterministic_and_content_addressed
    with_publishable_fixture do |_source, descriptor_path, workflow|
      with_tmp_dir do |first|
        with_tmp_dir do |second|
          one = Hive::Honeycomb::PackageBuilder.build(
            workflow: workflow, descriptor_path: descriptor_path, output_dir: first
          )
          two = Hive::Honeycomb::PackageBuilder.build(
            workflow: workflow, descriptor_path: descriptor_path, output_dir: second
          )

          assert_equal one.files, two.files
          one.files.each do |path|
            assert_equal File.binread(File.join(one.package_root, path)),
                         File.binread(File.join(two.package_root, path)), path
          end
          assert_equal one.manifest.fetch("aggregate_sha256"),
                       two.manifest.fetch("aggregate_sha256")

          File.write(File.join(File.dirname(descriptor_path), "sample", "shared.md"), "changed\n")
          changed_workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
          with_tmp_dir do |third|
            changed = Hive::Honeycomb::PackageBuilder.build(
              workflow: changed_workflow, descriptor_path: descriptor_path, output_dir: third
            )
            refute_equal one.manifest.fetch("aggregate_sha256"),
                         changed.manifest.fetch("aggregate_sha256")
          end
        end
      end
    end
  end

  def test_version_override_changes_package_without_editing_source_descriptor
    with_publishable_fixture do |_source, descriptor_path, workflow|
      original = File.binread(descriptor_path)
      with_tmp_dir do |out|
        package = Hive::Honeycomb::PackageBuilder.build(
          workflow: workflow,
          descriptor_path: descriptor_path,
          output_dir: out,
          version: "2.0.0-rc.1"
        )
        descriptor = YAML.safe_load(File.read(File.join(package.package_root, "workflow.yml")))
        assert_equal "2.0.0-rc.1", descriptor.fetch("metadata").fetch("version")
        assert_equal "2.0.0-rc.1", package.version
        assert_equal original, File.binread(descriptor_path)
      end
    end
  end

  private

    def with_publishable_fixture(readme: false)
      with_tmp_dir do |dir|
        workflows = File.join(dir, "workflows")
        owned = File.join(workflows, "sample")
        FileUtils.mkdir_p(File.join(owned, "assets"))
        FileUtils.mkdir_p(File.join(owned, "nested"))
        File.write(File.join(owned, "shared.md"), "shared instructions\n")
        File.write(File.join(owned, "nested", "revise.md"), "revise instructions\n")
        File.write(File.join(owned, "assets", "diagram.txt"), "diagram\n")
        File.binwrite(File.join(owned, "README.source.md"), "Author supplied\n\x00bytes".b) if readme
        descriptor_path = File.join(workflows, "sample.yml")
        File.write(descriptor_path, fixture_descriptor(readme: readme))
        workflow = Hive::Workflows::DescriptorParser.parse_file(descriptor_path)
        yield(dir, descriptor_path, workflow)
      end
    end

    def fixture_descriptor(readme:)
      <<~YAML
        id: sample
        metadata:
          version: 1.2.3
          author: Example Author
          description: A sample publishable workflow
          minimum_hive_version: 0.3.7
          #{'readme: ./sample/README.source.md' if readme}
          assets:
            - ./sample/assets/diagram.txt
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: draft
            kind: agent
            state_file: draft.md
            instruction: ./sample/shared.md
            permissions: read-only
          - name: review
            kind: council
            state_file: review.md
            agent: codex
            reviewers:
              - name: shared
                instruction: ./sample/shared.md
              - name: skill
                skill: /review
            council:
              quorum: 2
              max_rounds: 2
              exit_rule: consensus
              revise:
                instruction: ./sample/nested/revise.md
      YAML
    end

    def unsafe_descriptor(instruction)
      <<~YAML
        id: unsafe
        metadata:
          version: 1.0.0
          author: Author
          description: Unsafe path
          minimum_hive_version: 0.3.7
        stages:
          - name: work
            kind: agent
            state_file: work.md
            instruction: #{instruction}
      YAML
    end
end
