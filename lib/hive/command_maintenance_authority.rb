# frozen_string_literal: true

require "hive/paths"
require "hive/errors"
require "hive/config"
require "hive/web/github_auth"
require "hive/web/loopback"

module Hive
  # Authenticated actor and the one cross-principal elevation predicate used
  # by every command-receipt maintenance operation. CLI authority derives
  # from custody of the shared Hive state home, never from an operator label.
  class CommandMaintenanceAuthority
    attr_reader :principal, :principal_source, :peer_address, :custody_uid

    def self.local(principal: nil)
      custody = validate_state_home_custody!
      default_principal = "local-owner:uid:#{custody.uid}"
      principal ||= default_principal
      unless principal == default_principal ||
             principal.match?(/\Ainstallation:[^:]+:uid:#{Regexp.escape(custody.uid.to_s)}\z/)
        raise Hive::ConfigError,
              "local installation-owner authority requires a verified local-owner principal"
      end
      new(
        principal: principal,
        principal_source: "local_cli",
        installation_owner: true,
        custody_uid: custody.uid
      )
    end

    def self.loopback(database:, peer_address:)
      custody = validate_state_home_custody!
      unless Hive::Web::Loopback.address?(peer_address)
        raise Hive::ConfigError, "loopback command authority requires a loopback peer address"
      end
      installation = database.installation_identity.fetch(:installation_id)
      new(
        principal: "installation:#{installation}:uid:#{custody.uid}",
        principal_source: "local_loopback",
        installation_owner: true,
        peer_address: peer_address,
        custody_uid: custody.uid
      )
    end

    def self.github(config:, login:, id:, peer_address: nil,
                    config_loader: -> { Hive::Config.load_global_web })
      custody = validate_state_home_custody!
      unless id.is_a?(Integer) && id.positive?
        raise Hive::ConfigError, "keyed web execution requires an authenticated numeric GitHub identity"
      end
      auth = Hive::Web::GithubAuth.new(config: config)
      new(
        principal: "github:#{id}", principal_source: "signed_in_web",
        installation_owner: auth.maintenance_owner?(login, id),
        installation_owner_check: -> {
          Hive::Web::GithubAuth.new(config: config_loader.call).maintenance_owner?(login, id)
        },
        peer_address: peer_address, custody_uid: custody.uid
      )
    end

    def self.validate_state_home_custody!
      stat = File.lstat(Hive::Paths.state_home)
      valid = stat.directory? && !stat.symlink? && stat.uid == Process.euid &&
        (stat.mode & 0o077).zero?
      raise Hive::ConfigError, "Hive state home custody is invalid" unless valid
      stat
    rescue SystemCallError => error
      raise Hive::ConfigError, "Hive state home custody cannot be verified: #{error.message}"
    end

    def initialize(principal:, principal_source:, installation_owner: false,
                   installation_owner_check: nil, peer_address: nil, custody_uid: nil)
      @principal = principal.to_s
      @principal_source = principal_source.to_s
      @installation_owner = installation_owner == true
      @installation_owner_check = installation_owner_check
      @peer_address = peer_address&.to_s
      @custody_uid = custody_uid
      raise ArgumentError, "maintenance principal is required" if @principal.empty?
    end

    def installation_owner?
      @installation_owner_check ? @installation_owner_check.call == true : @installation_owner
    end

    # Resolve mutable web-owner policy before entering a SQLite write
    # transaction. The returned authority retains no provider/config callback,
    # so repeated authorization checks inside the transaction are memory-only.
    def snapshot
      self.class.new(
        principal: principal, principal_source: principal_source,
        installation_owner: installation_owner?, peer_address: peer_address,
        custody_uid: custody_uid
      )
    end

    def authorize!(affected_principal)
      return authority_basis if installation_owner? || affected_principal.to_s == principal

      raise Hive::ConfigError,
            "command receipt maintenance is limited to the installation owner or the receipt owner"
    end

    def authority_basis
      installation_owner? ? "installation_owner" : "own_receipt"
    end
  end
end
