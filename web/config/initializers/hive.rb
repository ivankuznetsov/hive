# The web tier reuses hive's transport-agnostic classes; the gem requires
# them lazily, so load the ones the controllers depend on at boot.
require "hive"
require "hive/media_manifest"
require "hive/web/github_auth"
require "hive/web/status_feed"
require "hive/web/dispatcher"
require "hive/web/agents_auth"
require "hive/web/loopback"
require "hive/web/telegram_validator"
require "hive/web/telegram_tester"
require "hive/archive_filter"
require "hive/commands/init"
require "hive/commands/approve"
