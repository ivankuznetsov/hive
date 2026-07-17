require "test_helper"
require "timeout"
require "hive/patrol/source_reader"

class HivePatrolSourceReaderTest < Minitest::Test
  include HiveTestHelper

  def test_reads_ordinary_polyglot_sources_and_confined_symlinks
    with_tmp_dir do |dir|
      files = {
        "lib/service.rb" => "class Service; end\n",
        "src/worker.py" => "def work(): return True\n",
        "packages/web/index.ts" => "export const ready = true\n"
      }
      files.each do |path, content|
        full = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
      end
      File.symlink("service.rb", File.join(dir, "lib", "service_link.rb"))
      reader = Hive::Patrol::SourceReader.new(dir)

      files.each { |path, content| assert_equal content, reader.read_utf8(path) }
      assert reader.regular_file?("lib/service_link.rb")
      assert_equal files.fetch("lib/service.rb"), reader.read_utf8("lib/service_link.rb")
    end
  end

  def test_rejects_external_and_special_file_symlinks_without_blocking
    with_tmp_dir do |dir|
      Dir.mktmpdir("source-reader-outside") do |outside|
        outside_source = File.join(outside, "outside.rb")
        File.write(outside_source, "raise 'must not be read'\n")
        File.symlink(outside_source, File.join(dir, "external.rb"))
        File.symlink("/dev/zero", File.join(dir, "device.rb")) if File.exist?("/dev/zero")
        reader = Hive::Patrol::SourceReader.new(dir)

        Timeout.timeout(1) do
          refute reader.regular_file?("external.rb")
          assert_equal "", reader.read_utf8("external.rb")
          if File.exist?("/dev/zero")
            refute reader.regular_file?("device.rb")
            assert_equal "", reader.read_utf8("device.rb")
          end
        end
      end
    end
  end

  def test_caps_bytes_before_utf8_decoding_and_handles_unusable_paths
    with_tmp_dir do |dir|
      cap = Hive::Patrol::SourceReader::MAX_SOURCE_BYTES
      File.write(File.join(dir, "large.rb"), ("a" * cap) + "TAIL")
      File.write(File.join(dir, "empty.rb"), "")
      reader = Hive::Patrol::SourceReader.new(dir)

      content = reader.read_utf8("large.rb", limit: cap * 2)
      assert_equal cap, content.bytesize
      refute_includes content, "TAIL"
      assert_equal "", reader.read_bytes("large.rb", limit: 0)
      assert_equal "", reader.read_bytes("large.rb", limit: -1)
      assert_equal "", reader.read_bytes("empty.rb")
      refute reader.regular_file?("missing.rb")
      refute reader.regular_file?(".")
      assert_equal "", reader.read_utf8("missing.rb")
    end
  end

  def test_open_failure_degrades_to_empty_bytes
    with_tmp_dir do |dir|
      path = File.join(dir, "source.rb")
      File.write(path, "puts :ok\n")
      reader = Hive::Patrol::SourceReader.new(dir)

      with_replaced_singleton_method(
        File, :open, ->(*) { raise Errno::EIO, "simulated read race" }
      ) do
        assert_equal "".b, reader.read_bytes("source.rb")
      end
    end
  end
end
