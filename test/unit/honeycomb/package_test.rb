require "test_helper"
require "digest"
require "hive/honeycomb/package"

class HoneycombPackageTest < Minitest::Test
  include HiveTestHelper

  FakeRegistry = Struct.new(:entries, :blobs) do
    def git_object!(*args)
      case args.first
      when "ls-tree" then entries
      when "cat-file" then blobs.fetch(args.last)
      else raise "unexpected git args #{args.inspect}"
      end
    end
  end

  def test_verifies_tree_inventory_descriptor_and_stages_only_declared_files
    fixture = package_fixture
    with_tmp_dir do |parent|
      package = Hive::Honeycomb::Package.new(registry: fixture.fetch(:registry))
      verified = package.verify(fixture.fetch(:pin), staging_parent: parent)

      assert_equal "demo", verified.pin.name
      assert_equal %w[instructions/work.md logo.bin workflow.yml], verified.files.keys.sort
      assert_equal :demo, verified.descriptor.id
      assert File.file?(File.join(verified.staging_dir, "workflow.yml"))
      assert File.file?(File.join(verified.staging_dir, "logo.bin"))
      refute File.exist?(File.join(verified.staging_dir, "manifest.yml"))
      assert_equal true, verified.security_report.summary.fetch("shell_capable")
    end
  end

  def test_rejects_hash_mismatch_extra_tree_entry_and_non_regular_modes
    [ :bad_hash, :extra, :symlink, :submodule ].each do |fault|
      fixture = package_fixture(fault: fault)
      with_tmp_dir do |parent|
        assert_raises(Hive::Honeycomb::IntegrityError) do
          Hive::Honeycomb::Package.new(registry: fixture.fetch(:registry)).verify(
            fixture.fetch(:pin), staging_parent: parent
          )
        end
        assert_empty Dir.children(parent), "#{fault} must fail before leaving staged content"
      end
    end
  end

  def test_rejects_wrong_descriptor_id_and_uninventoried_instruction
    [ :wrong_id, :uninventoried_instruction ].each do |fault|
      fixture = package_fixture(fault: fault)
      with_tmp_dir do |parent|
        assert_raises(Hive::ConfigError) do
          Hive::Honeycomb::Package.new(registry: fixture.fetch(:registry)).verify(
            fixture.fetch(:pin), staging_parent: parent
          )
        end
        assert_empty Dir.children(parent)
      end
    end
  end

  private

  def package_fixture(fault: nil)
    instruction_ref = fault == :uninventoried_instruction ? "./missing.md" : "./instructions/work.md"
    id = fault == :wrong_id ? "other" : "demo"
    files = {
      "workflow.yml" => <<~YAML,
        id: #{id}
        stages:
          - name: work
            kind: agent
            state_file: work.md
            instruction: #{instruction_ref}
            permissions:
              preset: scoped
              tools: [Read, Bash]
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      "instructions/work.md" => "$ git status\n",
      "logo.bin" => "\x89PNG\x00".b
    }
    hashes = files.to_h { |path, bytes| [ path, Digest::SHA256.hexdigest(bytes) ] }
    hashes["workflow.yml"] = "0" * 64 if fault == :bad_hash
    manifest = {
      "version" => 1,
      "files" => hashes,
      "permissions" => {
        "presets" => [ "scoped" ], "tools" => %w[Read Bash], "dirs" => [], "bash" => true, "yolo" => false
      }
    }.to_yaml
    tree_files = files.merge("manifest.yml" => manifest)
    tree_files["extra.txt"] = "extra" if fault == :extra

    blobs = {}
    entries = tree_files.keys.sort.map.with_index do |path, index|
      oid = format("%040x", index + 1)
      blobs[oid] = tree_files.fetch(path)
      mode = if fault == :symlink && path == "logo.bin"
        "120000"
      elsif fault == :submodule && path == "logo.bin"
        "160000"
      else
        "100644"
      end
      type = mode == "160000" ? "commit" : "blob"
      "#{mode} #{type} #{oid}\tworkflows/demo/#{path}\0"
    end.join

    digest = Hive::Honeycomb::Manifest.package_digest(hashes)
    pin = Hive::Honeycomb::ResolvedPin.new(
      source: Hive::Honeycomb::SOURCE, name: "demo", sha: "f" * 40, version: "1.0.0",
      tag: "demo/v1.0.0", digest: digest, selector_kind: "latest", selector_value: nil
    )
    { registry: FakeRegistry.new(entries, blobs), pin: pin }
  end
end
