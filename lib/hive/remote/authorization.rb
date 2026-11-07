# frozen_string_literal: true

require "hive/remote/contract"

require "digest"
require "json"
require "hive/config"
require "hive/remote/errors"

module Hive
  module Remote
    class Authorization
      SCOPES = Contract::SCOPES
      NAME = Contract::PROJECT_NAME

      attr_reader :token

      def self.fingerprint(project)
        state_root = project.fetch("hive_state_path") { File.join(project.fetch("path"), ".hive-state") }
        canonical = File.realpath(state_root)
        Digest::SHA256.hexdigest(JSON.generate([
          project.fetch("name"), project.fetch("registration_id"), canonical,
          project["repository_identity"]
        ]))
      rescue SystemCallError, KeyError
        nil
      end

      def initialize(token:, installation_id:, projects: Hive::Config.method(:registered_projects))
        @token = token
        @installation_id = installation_id
        @projects = projects
      end

      def principal = "installation:#{@installation_id}:token:#{token.fetch('id')}"

      def scope!(scope)
        return true if token.fetch("scopes").include?(scope.to_s)

        raise Error.new(code: "insufficient_scope", status: 403, message: "token lacks the required scope")
      end

      def projects
        @projects.call.select do |project|
          next true if token.fetch("all_projects")

          grant = token.fetch("projects").find { |row| row.fetch("name") == project.fetch("name") }
          fingerprint = self.class.fingerprint(project)
          grant && fingerprint && grant.fetch("fingerprint") == fingerprint
        end
      end

      def project!(name)
        if name.to_s.match?(NAME) && name != "." && name != ".."
          project = projects.find { |row| row.fetch("name") == name }
          return project if project
        end
        raise Error.new(code: "not_found", status: 404, message: "resource not found")
      end
    end
  end
end
