The isolation source files and profiles_README.md come unchanged from Hive
revision `966211001e76d53da50879a582668b5b2e381607`, before the explicit
credential declaration. Together with removal of the new operator guide, they
provision the old installed-runtime fixture for the manual refresh/revert
integration test. Never execute the legacy wrapper with real credentials.
