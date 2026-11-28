require "hive/runtime_control_plane/storage_attributes"

Hive::RuntimeControlPlane::StorageAttributes.default_runner = lambda do |command, *|
  raise "unexpected storage attribute command: #{command}" unless command == "stat"

  "ef53 ext2/ext3\n"
end
