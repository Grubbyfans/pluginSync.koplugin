# Release version policy

- For each subsequent user-requested plugin update, increment the plugin release version in both `_meta.lua` and `pluginsync.json` before delivery. Keep these versions identical.
- Update the current-version example in README.md and regenerate `dist/pluginsync.koplugin.zip` with `node tools/package.mjs`.
- The menu displays the version captured at startup; do not refresh it from disk during self-update, since new code takes effect after restart.
