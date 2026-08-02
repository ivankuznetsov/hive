require "test_helper"
require "digest"
require "json"
require "open3"
require "stringio"
require_relative "../../../packaging/release_candidate/artifacts"
require_relative "../../../packaging/release_candidate/runner"

class ReleaseCandidateArtifactsTest < Minitest::Test
  include HiveTestHelper

  def test_rejects_a_non_full_candidate_sha_before_building
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::Artifacts.new(
        repo_root: Dir.pwd,
        candidate_sha: "main",
        candidate_dir: File.join(Dir.pwd, "tmp", "release-candidates", "main", "candidate")
      )
    end

    assert_includes error.message, "full 40-character commit SHA"
  end

  def test_verifier_rejects_substituted_and_unmanifested_artifacts
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      artifacts.verify!

      gem = File.join(artifacts.candidate_dir, "hive-cli-0.6.9.gem")
      File.open(gem, "ab") { |file| file.write("substitution") }
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "size mismatch"

      artifacts = fixture_artifacts(File.join(dir, "extra"))
      File.write(File.join(artifacts.candidate_dir, "unmanifested.txt"), "extra")
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "unmanifested"
    end
  end

  def test_verifier_rejects_symlinked_artifact_and_malformed_builder_revision
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      gem = File.join(artifacts.candidate_dir, "hive-cli-0.6.9.gem")
      outside = File.join(dir, "outside.gem")
      FileUtils.mv(gem, outside)
      File.symlink(outside, gem)

      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "regular file"

      artifacts = fixture_artifacts(File.join(dir, "revision"))
      manifest_path = File.join(artifacts.candidate_dir, "manifest.json")
      manifest = JSON.parse(File.read(manifest_path))
      manifest["builder_revision"] = "drifted"
      File.write(manifest_path, JSON.generate(manifest))
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "builder revision"
    end
  end

  def test_artifact_path_collision_fails_before_any_build
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate")
      File.write(candidate, "occupied")
      artifacts = HiveReleaseCandidate::Artifacts.new(
        repo_root: dir, candidate_sha: "a" * 40, candidate_dir: candidate
      )

      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.call }
      assert_includes error.message, "collision"
      assert_equal "occupied", File.read(candidate)
    end
  end

  def test_builder_revision_tracks_the_exact_creator_contract_source_closure
    expected = %w[
      packaging/live_agent_skills/proof.rb
      packaging/live_agent_skills/proof_primitives.rb
      packaging/live_agent_skills/workflow_creator.rb
      packaging/live_agent_skills/workflow_creator_contract.rb
      packaging/live_agent_skills/workflow_creator_bundle.rb
      packaging/live_agent_skills/workflow_creator_execution_contract.rb
      packaging/live_agent_skills/build.rb
    ]
    assert_equal expected, HiveReleaseCandidate::Artifacts::LIVE_AGENT_BUILDER_INPUTS

    with_tmp_dir do |dir|
      export = File.join(dir, "export")
      expected.each do |relative|
        path = File.join(export, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{relative}\n")
      end
      artifacts = HiveReleaseCandidate::Artifacts.new(
        repo_root: dir, candidate_sha: "a" * 40,
        candidate_dir: File.join(dir, "candidate")
      )
      first = artifacts.send(:builder_revision, export)
      File.open(File.join(export, expected.fetch(4)), "a") { |file| file.write("drift\n") }
      second = artifacts.send(:builder_revision, export)

      refute_equal first, second
    end
  end

  def test_source_builder_rejects_noncanonical_archive_aliases
    with_tmp_dir do |dir|
      target = "packaging/live_agent_skills/workflow_creator_contract.rb"
      cases = {
        "embedded-dot" => [ "packaging/live_agent_skills/./workflow_creator_contract.rb", :extra ],
        "leading-dot" => [ "./#{target}", :extra ],
        "case-alias" => [ target.sub("workflow_creator", "Workflow_Creator"), :extra ],
        "repeated-separator" => [ target.sub("/workflow", "//workflow"), :extra ],
        "exact-duplicate" => [ target, :extra ],
        "protected-symlink" => [ target, :symlink ]
      }
      cases.each do |label, (alias_name, kind)|
        artifacts = fixture_artifacts(File.join(dir, label))
        source = File.join(artifacts.candidate_dir, "hive-source-#{'a' * 40}.tar.gz")
        inputs = fixture_builder_inputs
        Zlib::GzipWriter.open(source) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            inputs.each do |name, bytes|
              next if kind == :symlink && name == target

              tar.add_file_simple(name, 0o600, bytes.bytesize) { |io| io.write(bytes) }
            end
            if kind == :symlink
              tar.add_symlink(alias_name, "proof.rb", 0o777)
            else
              tar.add_file_simple(alias_name, 0o600, 7) { |io| io.write("aliased") }
            end
          end
        end
        manifest_path = File.join(artifacts.candidate_dir, "manifest.json")
        manifest = JSON.parse(File.read(manifest_path))
        record = manifest.fetch("files").fetch(File.basename(source))
        record["sha256"] = Digest::SHA256.file(source).hexdigest
        record["size"] = File.size(source)
        File.write(manifest_path, JSON.generate(manifest))

        error = assert_raises(HiveReleaseCandidate::Error, label) { artifacts.verify! }
        assert_match(/candidate source (?:contains|duplicates|builder)/, error.message, label)
      end
    end
  end

  def test_source_builder_rejects_pax_path_rewrites_that_extraction_honors
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      source = File.join(artifacts.candidate_dir, "hive-source-#{'a' * 40}.tar.gz")
      target = "packaging/live_agent_skills/proof.rb"
      build_source_fixture(
        source, builder_inputs: fixture_builder_inputs,
        pax_rewrite: [ target, "EVIL-PAX" ]
      )
      refresh_source_record!(artifacts, source)

      extracted = File.join(dir, "extracted")
      FileUtils.mkdir_p(extracted)
      stdout, stderr, status = Open3.capture3("tar", "-xzf", source, "-C", extracted)
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_equal "EVIL-PAX", File.binread(File.join(extracted, target))

      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "unsupported archive metadata"
    end
  end

  def test_source_builder_accepts_only_the_exact_git_global_pax_comment
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      source = File.join(artifacts.candidate_dir, "hive-source-#{'a' * 40}.tar.gz")
      build_source_fixture(
        source, builder_inputs: fixture_builder_inputs,
        global_comment: "a" * 40
      )
      refresh_source_record!(artifacts, source)

      assert artifacts.verify!

      build_source_fixture(
        source, builder_inputs: fixture_builder_inputs,
        global_comment: "b" * 40
      )
      refresh_source_record!(artifacts, source)
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "noncanonical global archive metadata"
    end
  end

  def test_source_builder_rejects_a_second_gzip_member_visible_to_tar
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      source = File.join(artifacts.candidate_dir, "hive-source-#{'a' * 40}.tar.gz")
      build_concatenated_source_fixture(source, builder_inputs: fixture_builder_inputs)
      refresh_source_record!(artifacts, source)

      stdout, stderr, status = Open3.capture3("tar", "-tzf", source)
      assert status.success?, stderr
      assert_includes stdout.lines.map(&:chomp), "benign-second-member.txt"

      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "exactly one gzip member"
    end
  end

  def test_source_builder_requires_canonical_tar_end_padding
    invalid_padding = {
      "missing" => "".b,
      "nonzero" => ("\0" * 1_023) + "x",
      "oversized" => "\0" * (HiveReleaseCandidate::Artifacts::MAX_SOURCE_TAR_PADDING_BYTES + 1_024),
      "non-block-aligned" => "\0" * 1_025
    }

    invalid_padding.each do |label, padding|
      with_tmp_dir do |dir|
        artifacts = fixture_artifacts(dir)
        source = File.join(artifacts.candidate_dir, "hive-source-#{'a' * 40}.tar.gz")
        tar = StringIO.new("".b)
        fixture_builder_inputs.each do |name, body|
          append_tar_entry(tar, name: name, body: body)
        end
        File.binwrite(source, gzip_member(tar.string + padding))
        refresh_source_record!(artifacts, source)

        error = assert_raises(HiveReleaseCandidate::Error, label) { artifacts.verify! }
        assert_includes error.message, "noncanonical tar padding", label
      end
    end
  end

  def test_source_builder_enforces_compressed_entry_expansion_and_member_limits
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      cases = {
        MAX_SOURCE_ARCHIVE_BYTES: [ 1, "compressed-size limit" ],
        MAX_SOURCE_ARCHIVE_ENTRIES: [ 1, "entry or expanded-size limit" ],
        MAX_SOURCE_EXPANDED_BYTES: [ 1, "entry or expanded-size limit" ],
        MAX_BUILDER_INPUT_BYTES: [ 1, "builder input exceeds the size limit" ]
      }
      cases.each do |name, (limit, message)|
        with_replaced_constant(HiveReleaseCandidate::Artifacts, name, limit) do
          error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
          assert_includes error.message, message, name
        end
      end
    end
  end

  def test_paths_reject_symlinked_root_and_nonblocking_concurrent_lock
    with_tmp_dir do |repo|
      safe_parent = File.join(repo, "tmp", "release-candidates")
      FileUtils.mkdir_p(safe_parent)
      outside = File.join(repo, "outside")
      FileUtils.mkdir_p(outside)
      linked = File.join(safe_parent, "linked")
      File.symlink(outside, linked)

      error = assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::Paths.new(
          repo_root: repo, candidate_sha: "a" * 40, runs_root: linked
        )
      end
      assert_includes error.message, "symlink"

      paths = HiveReleaseCandidate::Paths.new(
        repo_root: repo,
        candidate_sha: "a" * 40,
        runs_root: File.join(safe_parent, "owned")
      )
      paths.prepare!
      File.open(paths.lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        error = assert_raises(HiveReleaseCandidate::TemporaryError) do
          paths.with_lock { flunk "concurrent caller must not enter the lock" }
        end
        assert_includes error.message, "already being operated"
      end
    end
  end

  def test_committed_coverage_identity_ignores_dirty_worktree_bytes
    with_tmp_dir do |repo|
      run_git(repo, "init", "-b", "main")
      run_git(repo, "config", "user.email", "test@example.com")
      run_git(repo, "config", "user.name", "Hive Test")
      FileUtils.mkdir_p(File.join(repo, "test/e2e"))
      FileUtils.mkdir_p(File.join(repo, "lib/hive"))
      FileUtils.mkdir_p(File.join(repo, ".github/workflows"))
      coverage = File.join(repo, "test/e2e/coverage.yml")
      File.write(coverage, "committed coverage\n")
      File.write(
        File.join(repo, "lib/hive/version.rb"),
        "module Hive; VERSION = \"0.6.9\"; end\n"
      )
      File.write(File.join(repo, ".github/workflows/ci.yml"), "name: CI\n")
      run_git(repo, "add", ".")
      run_git(repo, "commit", "-m", "fixture")
      sha = run_git(repo, "rev-parse", "HEAD").strip

      File.write(coverage, "dirty replacement\n")
      input = HiveReleaseCandidate::Repository.new(repo).inputs(sha).fetch("coverage")

      assert_equal "available", input.fetch("status")
      assert_equal Digest::SHA256.hexdigest("committed coverage\n"), input.fetch("sha256")
      refute_equal Digest::SHA256.file(coverage).hexdigest, input.fetch("sha256")
    end
  end

  private

  def fixture_artifacts(dir)
    candidate = File.join(dir, "candidate")
    FileUtils.mkdir_p(candidate)
    files = {
      "hive-cli-0.6.9.gem" => [ "gem", "gem bytes" ],
      "hive-agent-skills-#{'a' * 40}.tar.gz" => [ "skills", "skill bytes" ],
      "hive-web-0.6.9.tar.gz" => [ "web", "web bytes" ]
    }
    files.each do |name, (_kind, bytes)|
      path = File.join(candidate, name)
      File.binwrite(path, bytes)
    end
    source_name = "hive-source-#{'a' * 40}.tar.gz"
    builder_inputs = fixture_builder_inputs
    build_source_fixture(
      File.join(candidate, source_name),
      builder_inputs: builder_inputs
    )
    files[source_name] = [ "source", nil ]
    records = files.to_h do |name, (kind, _bytes)|
      path = File.join(candidate, name)
      [
        name,
        {
          "kind" => kind,
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "size" => File.size(path)
        }
      ]
    end
    builder_digest = Digest::SHA256.new
    builder_inputs.each do |path, bytes|
      builder_digest << path << "\0" << bytes << "\0"
    end
    managed = File.expand_path("../../../packaging/managed_web_archive.rb", __dir__)
    builder_digest << "packaging/managed_web_archive.rb\0" << File.binread(managed) << "\0"
    manifest = {
      "schema" => HiveReleaseCandidate::Artifacts::MANIFEST_SCHEMA,
      "schema_version" => 1,
      "candidate_sha" => "a" * 40,
      "hive_version" => "0.6.9",
      "skill_version" => "1",
      "canonical_digest" => "b" * 64,
      "builder_revision" => builder_digest.hexdigest,
      "files" => records
    }
    File.write(File.join(candidate, "manifest.json"), JSON.generate(manifest))
    HiveReleaseCandidate::Artifacts.new(
      repo_root: dir, candidate_sha: "a" * 40, candidate_dir: candidate
    )
  end

  def build_source_fixture(destination, builder_inputs:, global_comment: nil, pax_rewrite: nil)
    tar = StringIO.new("".b)
    append_tar_entry(
      tar, name: "pax_global_header", body: "52 comment=#{global_comment}\n",
      typeflag: "g"
    ) if global_comment
    builder_inputs.each do |relative, bytes|
      append_tar_entry(tar, name: relative, body: bytes)
    end
    if pax_rewrite
      target, bytes = pax_rewrite
      append_tar_entry(tar, name: "pax-header", body: pax_record("path", target), typeflag: "x")
      append_tar_entry(tar, name: "benign-overwrite", body: bytes)
    end
    tar.write("\0" * 1_024)
    Zlib::GzipWriter.open(destination) { |gzip| gzip.write(tar.string) }
  end

  def append_tar_entry(io, name:, body:, typeflag: "0")
    header = Gem::Package::TarHeader.new(
      name: name, prefix: "", mode: 0o600, size: body.bytesize,
      typeflag: typeflag
    )
    io.write(header.to_s)
    io.write(body)
    io.write("\0" * ((512 - (body.bytesize % 512)) % 512))
  end

  def build_concatenated_source_fixture(destination, builder_inputs:)
    first = StringIO.new("".b)
    builder_inputs.each do |name, body|
      append_tar_entry(first, name: name, body: body)
    end
    second = StringIO.new("".b)
    append_tar_entry(second, name: "benign-second-member.txt", body: "second member\n")
    second.write("\0" * 1_024)
    File.binwrite(destination, gzip_member(first.string) + gzip_member(second.string))
  end

  def gzip_member(bytes)
    compressed = StringIO.new("".b)
    writer = Zlib::GzipWriter.new(compressed)
    writer.write(bytes)
    writer.finish
    compressed.string
  end

  def pax_record(key, value)
    length = key.bytesize + value.bytesize + 4
    loop do
      record = "#{length} #{key}=#{value}\n"
      return record if record.bytesize == length

      length = record.bytesize
    end
  end

  def refresh_source_record!(artifacts, source)
    manifest_path = File.join(artifacts.candidate_dir, "manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    record = manifest.fetch("files").fetch(File.basename(source))
    record["sha256"] = Digest::SHA256.file(source).hexdigest
    record["size"] = File.size(source)
    File.write(manifest_path, JSON.generate(manifest))
  end

  def with_replaced_constant(owner, name, value)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

  def fixture_builder_inputs
    HiveReleaseCandidate::Artifacts::LIVE_AGENT_BUILDER_INPUTS.to_h do |path|
      [ path, "#{File.basename(path)} fixture\n" ]
    end
  end

  def run_git(repo, *argv)
    stdout, stderr, status = Open3.capture3("git", *argv, chdir: repo)
    assert status.success?, stderr
    stdout
  end
end
