require "test_helper"
require "hive/workflow_package/source_snapshot"

class WorkflowPackageSourceSnapshotTest < Minitest::Test
  include HiveTestHelper

  Snapshot = Hive::WorkflowPackage::SourceSnapshot

  def test_snapshots_only_referenced_instructions_and_declared_assets
    with_source_tree do |workflows, authored, descriptor, metadata|
      File.write(File.join(authored, "unused.txt"), "ignored\n")

      snapshot = Snapshot.capture(
        name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
        authored_dir: authored, metadata: metadata
      )

      assert_equal %w[README.md assets/context.txt instructions/work.md workflow.yml], snapshot.files.keys
      assert_equal [ "external/reviewer" ], snapshot.external_skills
      refute_includes snapshot.files.values.map(&:bytes).join, "ignored"
      rewritten = YAML.safe_load(snapshot.files.fetch("workflow.yml").bytes)
      assert_equal "instructions/work.md", rewritten.dig("stages", 1, "instruction")
    end
  end

  def test_rejects_symlinks_traversal_and_undeclared_missing_files
    with_source_tree do |workflows, authored, descriptor, metadata|
      FileUtils.rm_f(File.join(authored, "work.md"))
      File.symlink("README.md", File.join(authored, "work.md"))
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end

      FileUtils.rm_f(File.join(authored, "work.md"))
      File.write(File.join(authored, "work.md"), "work\n")
      bad = metadata.with(assets: [ "../outside.txt" ])
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: bad)
      end
    end
  end

  def test_rejects_symlinked_intermediate_directories
    with_source_tree do |workflows, authored, descriptor, metadata|
      outside = File.join(File.dirname(workflows), "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "context.txt"), "escaped\n")
      FileUtils.rm_rf(File.join(authored, "assets"))
      File.symlink(outside, File.join(authored, "assets"))

      error = assert_raises(Hive::ConfigError) do
        Snapshot.capture(
          name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
          authored_dir: authored, metadata: metadata
        )
      end

      assert_match(/linked|symlink|owned workflow root/, error.message)
    end
  end

  def test_rejects_identity_root_reference_and_dependency_drift
    with_source_tree do |workflows, authored, descriptor, metadata|
      original = File.read(descriptor)
      File.write(descriptor, original.sub("id: demo", "id: other"))
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end

      File.write(descriptor, original.sub("./demo/work.md", "../outside.md"))
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end

      File.write(descriptor, original.sub("external/reviewer", "bad skill"))
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end
    end
  end

  def test_rejects_invalid_or_missing_owned_roots
    with_source_tree do |workflows, authored, descriptor, metadata|
      outside_descriptor = File.join(File.dirname(workflows), "outside.yml")
      FileUtils.cp(descriptor, outside_descriptor)
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: outside_descriptor,
                         authored_dir: authored, metadata: metadata)
      end

      real = File.join(File.dirname(workflows), "real-authored")
      FileUtils.mv(authored, real)
      File.symlink(real, authored)
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end
    end

    with_tmp_dir do |root|
      missing = File.join(root, "missing")
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(
          name: "demo", workflows_dir: missing, descriptor_path: File.join(missing, "demo.yml"),
          authored_dir: File.join(missing, "demo"), metadata: Data.define(:assets).new(assets: [])
        )
      end
    end
  end

  def test_private_path_guards_reject_collisions_escape_and_realpath_drift
    with_source_tree do |workflows, authored, descriptor, metadata|
      instance = Snapshot.new(
        name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
        authored_dir: authored, metadata: metadata
      )
      assert_equal "scalar", instance.send(:transform_descriptor, "scalar") { flunk }
      assert_raises(Hive::ConfigError) do
        instance.send(:resolve_owned_path, nil, kind: "instruction")
      end
      assert_raises(Hive::ConfigError) do
        instance.send(:add_unique!, { "instructions/work.md" => "/one" },
                      "instructions/work.md", "/two")
      end
      assert_raises(Hive::ConfigError) { instance.send(:validate_skill!, "bad skill") }
      assert_raises(Hive::ConfigError) do
        instance.send(:validate_path_components!, File.join(File.dirname(workflows), "outside"),
                      package_path: "outside")
      end

      source = File.join(authored, "work.md")
      original = File.method(:realpath)
      replacement = lambda do |path|
        path == source ? File.join(File.dirname(workflows), "outside") : original.call(path)
      end
      with_replaced_singleton_method(File, :realpath, replacement) do
        assert_raises(Hive::ConfigError) do
          instance.send(:validate_path_components!, source, package_path: "instructions/work.md")
        end
      end
    end
  end

  def test_rejects_hardlinks_read_races_and_missing_records
    with_source_tree do |workflows, authored, descriptor, metadata|
      context = File.join(authored, "assets", "context.txt")
      File.link(context, File.join(authored, "assets", "context-copy.txt"))
      assert_raises(Hive::ConfigError) do
        Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                         authored_dir: authored, metadata: metadata)
      end
    end

    with_source_tree do |workflows, authored, descriptor, metadata|
      target = File.join(authored, "work.md")
      original = File.method(:open)
      replacement = lambda do |*args, &block|
        file = original.call(*args, &block)
        next file unless args.first == target && block.nil?

        reads = 0
        wrapper = Object.new
        wrapper.define_singleton_method(:read) { |*values| file.read(*values) }
        wrapper.define_singleton_method(:close) { file.close }
        wrapper.define_singleton_method(:stat) do
          reads += 1
          stat = file.stat
          next stat if reads == 1

          changed = Object.new
          %i[dev ino size ctime mode nlink].each do |field|
            value = stat.public_send(field)
            changed.define_singleton_method(field) { value }
          end
          changed.define_singleton_method(:mtime) { stat.mtime + 1 }
          changed.define_singleton_method(:file?) { true }
          changed
        end
        wrapper
      end
      with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::ConfigError) do
          Snapshot.capture(name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
                           authored_dir: authored, metadata: metadata)
        end
      end

      instance = Snapshot.new(
        name: "demo", workflows_dir: workflows, descriptor_path: descriptor,
        authored_dir: authored, metadata: metadata
      )
      denied = lambda do |*args, &block|
        raise Errno::EACCES, target if args.first == target

        original.call(*args, &block)
      end
      with_replaced_singleton_method(File, :open, denied) do
        assert_raises(Hive::ConfigError) do
          instance.send(:read_record, target, package_path: "instructions/work.md")
        end
      end
    end
  end

  private

  def with_source_tree
    with_tmp_dir do |root|
      workflows = File.join(root, "workflows")
      authored = File.join(workflows, "demo")
      FileUtils.mkdir_p(File.join(authored, "assets"))
      descriptor = File.join(workflows, "demo.yml")
      File.write(descriptor, <<~YAML)
        id: demo
        stages:
          - name: inbox
            kind: terminal
            state_file: idea.md
          - name: work
            kind: agent
            state_file: work.md
            instruction: ./demo/work.md
            skill: external/reviewer
            mapping_role: development
            mapping_contract: demo-work-v1
            permissions: read-only
          - name: done
            kind: terminal
            state_file: done.md
      YAML
      File.write(File.join(authored, "work.md"), "work\n")
      File.write(File.join(authored, "README.md"), "# Demo\n")
      File.write(File.join(authored, "assets", "context.txt"), "context\n")
      metadata = Data.define(:assets).new(assets: [ "assets/context.txt" ])
      yield workflows, authored, descriptor, metadata
    end
  end
end
