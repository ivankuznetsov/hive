require "hive/commands/module/base"
require "hive/modules/doctor"

module Hive
  module Commands
    class Module
      class Doctor < Base
        def initialize(name, doctor: nil, **options)
          super(**{ yes: false, dry_run: false, receipt: nil }.merge(options))
          @name = name.to_s
          @doctor = doctor
        end

        def call!
          result = (@doctor || Hive::Modules::Doctor.new(inspector: inspector, store: store)).check(@name)
          payload = {
            "schema" => "hive-module-doctor",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-module-doctor"),
            "ok" => true, **result
          }
          lines = result.fetch("checks").map do |row|
            "#{row.fetch('status')} #{row.fetch('code')}#{row['subject'] ? " #{row['subject']}" : ''}"
          end
          emit(payload, human_lines: lines)
        end

        private

        def envelope_schema = "hive-module-doctor"
      end
    end
  end
end
