# Start the Turbo Stream status broadcaster only in a SERVING process —
# `bin/rails server` defines Rails::Server; rake tasks, db:prepare, the
# console, and the test runner do not (tests drive StatusBroadcaster
# explicitly). A broadcaster during db:prepare would poll and broadcast
# into half-created solid_cable tables.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  next unless defined?(Rails::Server)

  StatusBroadcaster.start!
end

at_exit { StatusBroadcaster.stop! if defined?(StatusBroadcaster) }
