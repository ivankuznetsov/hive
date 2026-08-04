require "test_helper"
require "digest"
require "rubygems/package"
require "stringio"
require "zlib"
require_relative "../../../packaging/live_agent_skills/workflow_creator_archive"

class WorkflowCreatorArchiveTest < Minitest::Test
  include HiveTestHelper

  Archive = HiveLiveAgentProof::WorkflowCreatorArchive
  Creator = HiveLiveAgentProof::WorkflowCreator

  def test_public_api_admits_a_regular_archive_into_the_exact_execution_record
    with_tmp_dir do |root|
      path = File.join(root, "openclaw.tar.gz")
      write_archive(path, [ [ :directory, "bin", nil ], [ :file, "bin/hive", "hive\n" ] ])

      result = Archive.admit!(
        archive: path, label: "openclaw-package", available_bytes: 1_000_000,
        available_entries: 100
      )

      assert_equal %i[admit!], Archive.singleton_methods(false)
      assert_equal %i[archive label available_bytes available_entries clock],
                   Archive.method(:admit!).parameters.map(&:last)
      assert_equal({
        "label" => "openclaw-package", "artifact_sha256" => Digest::SHA256.file(path).hexdigest,
        "artifact_size" => File.size(path),
        "policy_sha256" => Creator::Vocabulary.fetch("archive_policy_sha256"),
        "entry_count" => 2, "uncompressed_bytes" => 5, "status" => "passed"
      }, result.value)
      assert_equal result.canonical_bytes, Creator::Values.capture(result.value).canonical_bytes
      assert result.frozen?
    end
  end

  def test_candidate_admits_a_real_gem_envelope_and_its_nested_data_archive
    with_tmp_dir do |root|
      path = build_fixture_gem(root)

      result = admit(path, label: "candidate-package")

      assert_equal "candidate-package", result.value.fetch("label")
      assert_equal Digest::SHA256.file(path).hexdigest, result.value.fetch("artifact_sha256")
      assert_equal 4, result.value.fetch("entry_count")
      assert_operator result.value.fetch("uncompressed_bytes"), :>, "FIXTURE = true\n".bytesize
    end
  end

  def test_candidate_refuses_an_unsafe_member_inside_nested_data_archive
    with_tmp_dir do |root|
      path = File.join(root, "unsafe.gem")
      nested = gzip_tar_bytes { |tar| tar.add_symlink("lib/escape", "../../outside", 0o777) }
      write_gem_envelope(path, nested)

      assert_raises(Archive::Error) { admit(path, label: "candidate-package") }
    end
  end

  def test_refuses_traversal_absolute_duplicate_and_conflicting_destinations
    cases = {
      "traversal" => [ [ :file, "../escape", "x" ] ],
      "absolute" => [ [ :file, "/escape", "x" ] ],
      "duplicate" => [ [ :file, "same", "x" ], [ :file, "same", "y" ] ],
      "file-parent" => [ [ :file, "node", "x" ], [ :file, "node/child", "y" ] ]
    }

    cases.each do |name, entries|
      with_tmp_dir do |root|
        path = File.join(root, "#{name}.tar.gz")
        write_archive(path, entries)

        error = assert_raises(Archive::Error, name) { admit(path) }
        assert_equal "workflow-creator archive is not safely admissible", error.message
      end
    end
  end

  def test_refuses_links_devices_and_other_special_members
    %w[1 2 3 4 6 x].each do |type|
      with_tmp_dir do |root|
        path = File.join(root, "special.tar.gz")
        write_raw_archive(path, name: "unsafe", typeflag: type)

        assert_raises(Archive::Error, "type #{type}") { admit(path) }
      end
    end
  end

  def test_refuses_depth_path_compression_time_and_filesystem_budget_exhaustion
    with_tmp_dir do |root|
      path = File.join(root, "limits.tar.gz")
      write_archive(path, [ [ :file, ([ "deep" ] * 33).join("/"), "x" ] ])
      assert_raises(Archive::Error) { admit(path) }

      long_path = "#{"p" * 140}/#{"q" * 100}"
      write_archive(path, [ [ :file, long_path, "x" ] ])
      assert_raises(Archive::Error) { admit(path) }

      write_archive(path, [ [ :file, "bomb", "\0" * 200_000 ] ])
      assert_raises(Archive::Error) { admit(path) }

      write_archive(path, [ [ :file, "safe", "content" ] ])
      assert_raises(Archive::Error) { admit(path, available_bytes: 6) }
      assert_raises(Archive::Error) { admit(path, available_entries: 0) }

      ticks = [ 0.0, 0.0, 6.0 ]
      assert_raises(Archive::Error) { admit(path, clock: -> { ticks.shift || 6.0 }) }
    end
  end

  def test_refuses_a_linked_or_replaced_archive_file
    with_tmp_dir do |root|
      path = File.join(root, "archive.tar.gz")
      write_archive(path, [ [ :file, "safe", "content" ] ])
      File.link(path, File.join(root, "alias.tar.gz"))

      assert_raises(Archive::Error) { admit(path) }
    end
  end

  private

  def admit(path, label: "openclaw-package", available_bytes: 1_000_000, available_entries: 100, clock: nil)
    Archive.admit!(
      archive: path, label:, available_bytes:, available_entries:, clock:
    )
  end

  def write_archive(path, entries)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |tar|
        entries.each do |kind, name, content|
          if kind == :directory
            tar.mkdir(name, 0o755)
          else
            tar.add_file_simple(name, 0o644, content.bytesize) { |io| io.write(content) }
          end
        end
      end
    end
  end

  def write_raw_archive(path, name:, typeflag:)
    header = Gem::Package::TarHeader.new(
      name:, prefix: "", mode: 0o644, size: 0, typeflag:, linkname: "target"
    )
    Zlib::GzipWriter.open(path) { |gzip| gzip.write(header.to_s + ("\0" * 1_024)) }
  end

  def build_fixture_gem(root)
    FileUtils.mkdir_p(File.join(root, "lib"))
    File.write(File.join(root, "lib", "workflow_creator_fixture.rb"), "FIXTURE = true\n")
    spec = Gem::Specification.new do |value|
      value.name = "workflow-creator-fixture"
      value.version = "1.0.0"
      value.summary = "Workflow creator archive fixture"
      value.authors = [ "Hive" ]
      value.files = [ "lib/workflow_creator_fixture.rb" ]
    end
    filename = nil
    capture_io { Dir.chdir(root) { filename = Gem::Package.build(spec, true) } }
    File.join(root, filename)
  end

  def write_gem_envelope(path, nested)
    File.open(path, "wb") do |file|
      Gem::Package::TarWriter.new(file) do |tar|
        { "metadata.gz" => gzip_bytes("metadata"), "data.tar.gz" => nested,
          "checksums.yaml.gz" => gzip_bytes("checksums") }.each do |name, bytes|
          tar.add_file_simple(name, 0o644, bytes.bytesize) { |entry| entry.write(bytes) }
        end
      end
    end
  end

  def gzip_tar_bytes
    io = StringIO.new("".b)
    gzip = Zlib::GzipWriter.new(io)
    Gem::Package::TarWriter.new(gzip) { |tar| yield tar }
    gzip.finish
    io.string
  end

  def gzip_bytes(bytes)
    io = StringIO.new("".b)
    gzip = Zlib::GzipWriter.new(io)
    gzip.write(bytes)
    gzip.finish
    io.string
  end
end
