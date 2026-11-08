# Preserve resolved dependencies during supervisor self-reentry

The detached supervisor now receives canonical directories from the running
interpreter's load path. RubyGems activation alone does not describe dependencies
loaded through a resolved RUBYLIB, which caused isolated CLI scenarios to fail
before their worker started. Ambient Bundler settings and RUBYOPT remain cleared.
A subprocess regression disables RubyGems and requires a temporary dependency,
so globally installed gems cannot mask the missing path.
