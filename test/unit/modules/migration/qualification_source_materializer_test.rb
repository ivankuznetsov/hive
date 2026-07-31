require "test_helper"
require "rubygems/package"
require "stringio"
require "zlib"
require "hive/modules/migration/qualification_source_materializer"

class ModulesMigrationQualificationSourceMaterializerTest <
    Minitest::Test
  include HiveTestHelper

  MATERIALIZER =
    Hive::Modules::Migration::QualificationSourceMaterializer

  def test_materializes_only_regular_files_and_directories_with_fixed_modes
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      destination = File.join(root, "source")
      result = MATERIALIZER.new.materialize(
        archive(
          "bin/hive" => "#!/usr/bin/env ruby\n",
          "lib/hive.rb" => "module Hive; end\n",
          "modules/patrol/manifest.yml" => "name: patrol\n"
        ),
        destination: destination,
        executable_ref: "bin/hive"
      )

      assert_equal destination, result.root
      assert_match(/\A[0-9a-f]{64}\z/, result.tree_sha256)
      assert_equal 3, result.file_count
      assert_equal 0o700,
                   File.stat(File.join(destination, "bin/hive")).mode &
                     0o777
      assert_equal 0o600,
                   File.stat(File.join(destination, "lib/hive.rb")).mode &
                     0o777
      assert_equal "#!/usr/bin/env ruby\n",
                   File.binread(File.join(destination, "bin/hive"))
    end
  end

  def test_rejects_traversal_links_duplicates_and_cleans_staging
    cases = [
      archive("../escape" => "owned\n"),
      archive(
        "safe" => "first\n",
        "safe/child" => "collision\n"
      ),
      archive_with_symlink("link", "../escape")
    ]

    cases.each do |bytes|
      with_tmp_dir do |root|
        File.chmod(0o700, root)
        destination = File.join(root, "source")

        assert_raises(Hive::ConfigError) do
          MATERIALIZER.new.materialize(
            bytes,
            destination: destination,
            executable_ref: "bin/hive"
          )
        end
        refute_path_exists destination
        refute_path_exists File.join(root, "escape")
      end
    end
  end

  def test_enforces_entry_and_expansion_limits_before_publication
    with_tmp_dir do |root|
      File.chmod(0o700, root)
      destination = File.join(root, "source")
      materializer = MATERIALIZER.new(
        max_entries: 1,
        max_file_bytes: 8,
        max_total_bytes: 8,
        max_ratio: 10_000
      )

      assert_raises(Hive::ConfigError) do
        materializer.materialize(
          archive(
            "bin/hive" => "12345678",
            "extra" => "x"
          ),
          destination: destination,
          executable_ref: "bin/hive"
        )
      end
      refute_path_exists destination
    end
  end

  private

  def archive(files)
    tar = StringIO.new("".b)
    Gem::Package::TarWriter.new(tar) do |writer|
      files.each do |name, bytes|
        writer.add_file_simple(name, 0o600, bytes.bytesize) do |io|
          io.write(bytes)
        end
      end
    end
    gzip(tar.string)
  end

  def archive_with_symlink(name, target)
    tar = StringIO.new("".b)
    Gem::Package::TarWriter.new(tar) do |writer|
      writer.add_symlink(name, target, 0o777)
    end
    gzip(tar.string)
  end

  def gzip(bytes)
    output = StringIO.new("".b)
    writer = Zlib::GzipWriter.new(output)
    writer.write(bytes)
    writer.close
    output.string
  end
end
