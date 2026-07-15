require "tmpdir"
require "hive/commands/workflow/base"
require "hive/workflow_package/publisher"

module Hive
  module Commands
    class Workflow
      class Publish < Base
        SCHEMA = "hive-workflow-publish".freeze

        def initialize(name, project_root:, version:, json: false, stdout: $stdout, publisher: nil)
          super(project_root: project_root, json: json, stdout: stdout)
          @name = name.to_s
          @version = version.to_s
          @publisher = publisher || Hive::WorkflowPackage::Publisher.new(
            @name, project_root: project_root, version: @version
          )
        end

        def call!
          Dir.mktmpdir("hive-workflow-package-") do |root|
            package = @publisher.package(destination: root)
            pr_url = @publisher.publish(package)
            result = payload(package, pr_url)
            emit(result, human_lines: [
              "hive: submitted honeycomb/#{package.name}@#{package.version} for review",
              "pull request: #{pr_url}",
              "status: pending_review (not yet listed)"
            ])
          end
        end

        private

        def payload(package, pr_url)
          {
            "schema" => SCHEMA,
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
            "ok" => true,
            "status" => "pending_review",
            "name" => package.name,
            "version" => package.version,
            "manifest_digest" => package.manifest_digest,
            "warnings" => package.warnings,
            "pr_url" => pr_url,
            "listed" => false
          }
        end

        def envelope_schema = SCHEMA
      end
    end
  end
end
