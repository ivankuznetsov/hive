module Hive
  module RuntimeControlPlane
    Diagnosis = Data.define(
      :status, :path, :application_id, :schema_version, :sqlite_version,
      :integrity, :error
    ) do
      def ok? = status == :ok

      def to_h
        {
          status: status, path: path, application_id: application_id,
          schema_version: schema_version, sqlite_version: sqlite_version,
          integrity: integrity,
          error: error && { code: error.code, message: error.message, action: error.action }
        }
      end
    end
  end
end
