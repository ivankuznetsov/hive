require "digest"
require "fileutils"
require "open3"
require "yaml"

module HoneycombRegistryHelper
  class RegistryFixture
    attr_reader :remote, :work, :cache, :releases

    def initialize(root)
      @remote = File.join(root, "registry.git")
      @work = File.join(root, "registry-work")
      @cache = File.join(root, "registry-cache")
      @releases = Hash.new { |hash, key| hash[key] = [] }
      run!("git", "init", "--bare", "--quiet", remote)
      run!("git", "init", "-b", "main", "--quiet", work)
      run!("git", "-C", work, "config", "user.email", "honeycomb-test@example.com")
      run!("git", "-C", work, "config", "user.name", "Honeycomb Test")
      run!("git", "-C", work, "config", "commit.gpgsign", "false")
      run!("git", "-C", work, "remote", "add", "origin", remote)
      File.write(File.join(work, "README.md"), "Honeycomb test registry\n")
      run!("git", "-C", work, "add", "README.md")
      run!("git", "-C", work, "commit", "-m", "initialize registry", "--quiet")
    end

    def publish(name: "demo", version:, instruction:, tools: [ "Read" ], fault: nil)
      package_root = File.join(work, "workflows", name)
      FileUtils.rm_rf(package_root)
      FileUtils.mkdir_p(File.join(package_root, "instructions"))
      files = package_files(name, instruction, tools)
      if fault == :invalid_descriptor
        files["workflow.yml"] = files.fetch("workflow.yml").sub("id: #{name}", "id: wrong-name")
      end
      files.each do |path, bytes|
        target = File.join(package_root, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, bytes)
      end

      hashes = files.to_h { |path, bytes| [ path, Digest::SHA256.hexdigest(bytes) ] }
      hashes["workflow.yml"] = "0" * 64 if fault == :bad_hash
      hashes["../escape"] = "0" * 64 if fault == :path_escape
      hashes["nested-repository"] = "0" * 64 if fault == :submodule
      manifest = manifest_for(hashes, tools)
      File.write(File.join(package_root, "manifest.yml"), manifest.to_yaml)
      File.write(File.join(package_root, "undeclared.txt"), "not inventoried\n") if fault == :undeclared
      if fault == :symlink
        File.symlink("instructions/work.md", File.join(package_root, "asset-link"))
        hashes["asset-link"] = Digest::SHA256.hexdigest("instructions/work.md")
        File.write(File.join(package_root, "manifest.yml"), manifest_for(hashes, tools).to_yaml)
      end

      run!("git", "-C", work, "add", "--all", "workflows/#{name}")
      if fault == :submodule
        object = run!("git", "-C", work, "rev-parse", "HEAD").strip
        run!(
          "git", "-C", work, "update-index", "--add", "--cacheinfo",
          "160000,#{object},workflows/#{name}/nested-repository"
        )
      end
      run!("git", "-C", work, "commit", "-m", "release #{name} #{version}", "--quiet")
      sha = run!("git", "-C", work, "rev-parse", "HEAD").strip
      tag = "#{name}/v#{version}"
      digest = Hive::Honeycomb::Manifest.package_digest(hashes)
      run!("git", "-C", work, "tag", tag, sha)
      releases[name] << { "version" => version, "tag" => tag, "sha" => sha, "digest" => digest }
      write_catalog!
      run!("git", "-C", work, "add", "catalog.yml")
      run!("git", "-C", work, "commit", "-m", "catalog #{name} #{version}", "--quiet")
      run!("git", "-C", work, "push", "--force", "origin", "HEAD:main", "--tags", "--quiet")
      releases.fetch(name).last
    end

    def registry
      Hive::Honeycomb::Registry.new(remote_url: remote, cache_dir: cache)
    end

    private

    def package_files(name, instruction, tools)
      {
        "workflow.yml" => <<~YAML,
          id: #{name}
          stages:
            - name: work
              kind: agent
              state_file: work.md
              instruction: ./instructions/work.md
              permissions:
                preset: scoped
                tools: [#{tools.join(', ')}]
            - name: done
              kind: terminal
              state_file: done.md
        YAML
        "instructions/work.md" => instruction,
        "assets/badge.bin" => "\x89HIVE\x00".b
      }
    end

    def manifest_for(hashes, tools)
      {
        "version" => 1,
        "files" => hashes,
        "permissions" => {
          "presets" => [ "scoped" ],
          "tools" => tools,
          "dirs" => [],
          "bash" => tools.include?("Bash"),
          "yolo" => false
        }
      }
    end

    def write_catalog!
      workflows = releases.keys.sort.to_h do |name|
        records = releases.fetch(name)
        [ name, { "latest" => records.last.fetch("version"), "releases" => records } ]
      end
      File.write(File.join(work, "catalog.yml"), { "version" => 1, "workflows" => workflows }.to_yaml)
    end

    def run!(*argv)
      out, err, status = Open3.capture3(*argv)
      return out if status.success?

      raise "command failed: #{argv.join(' ')}\n#{err.empty? ? out : err}"
    end
  end

  def with_honeycomb_registry
    with_tmp_dir do |root|
      yield RegistryFixture.new(root)
    end
  end
end
