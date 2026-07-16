require "open3"
require "pathname"
require "uri"

module Hive
  module RepositoryIdentity
    module_function

    def normalize(remote, base_path: nil)
      value = remote.to_s.strip
      return nil if value.empty?

      if !value.include?("://") &&
          (scp = value.match(/\A(?:[^@\s\/]+@)?(?<host>[^:\/\s]+):(?<path>[^\s]+)\z/))
        return network_identity(scp[:host], scp[:path])
      end

      uri = URI.parse(value)
      return local_identity(uri.path, base_path) if uri.scheme == "file"
      if uri.scheme && uri.host
        host = uri.host
        host = "#{host}:#{uri.port}" if non_default_port?(uri)
        return network_identity(host, uri.path)
      end

      local_identity(value, base_path)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def current(project_root)
      stdout, _stderr, status = Open3.capture3(
        "git", "-C", File.expand_path(project_root), "remote", "get-url", "origin"
      )
      return nil unless status.success?

      normalize(stdout, base_path: project_root)
    rescue SystemCallError, IOError
      nil
    end

    def network_identity(host, path)
      normalized_path = path.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "").sub(/\.git\z/i, "")
      return nil if host.to_s.empty? || normalized_path.empty?

      "#{host.downcase}/#{normalized_path}"
    end

    def local_identity(path, base_path)
      return nil if path.to_s.strip.empty?

      expanded = if Pathname.new(path).absolute?
        File.expand_path(path)
      else
        File.expand_path(path, base_path || Dir.pwd)
      end
      canonical = File.realpath(expanded)
      "local:#{canonical}"
    rescue SystemCallError
      "local:#{expanded}"
    end

    def non_default_port?(uri)
      return false unless uri.port

      defaults = { "http" => 80, "https" => 443, "ssh" => 22, "git" => 9418 }
      defaults[uri.scheme] != uri.port
    end
  end
end
