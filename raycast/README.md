# ScreenOff for Raycast

This extension is a Raycast front end for the bundled `screenoff` CLI. It contains:

- **Manage Displays**: list displays and run the individual `on`, `off`, and `toggle` commands.
- **Turn On External Displays**, **Turn Off External Displays**, and **Toggle External Displays**: no-view commands intended for Raycast hotkeys.
- **Restore Display by ID** and **Turn on All Online Displays**: direct access to the CLI recovery and `on all` commands.

The extension builds and bundles ScreenOff's open-source CLI plus its `m1ddc` fallback helper. No ScreenOff app installation or Raycast preference is needed.

Develop locally:

```sh
npm install
npm run dev
```

To publish to the Raycast Store, set `author` in `package.json` to the verified Raycast Store handle that owns the extension.
