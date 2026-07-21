require "hive/web/environment"

# Direct Rails launches do not pass through `hive web`, so surface the same
# native-environment migration guidance during boot. The CLI translates and
# removes legacy aliases before exec, avoiding duplicate warnings there.
Hive::Web::Environment.emit_warnings(prefix: "Hive web")
