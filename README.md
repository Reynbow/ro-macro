# RO Macro

Ragnarok-oriented macro HUD built with **AutoHotkey v2** and **WebView2** ([github.com/Reynbow/ro-macro](https://github.com/Reynbow/ro-macro)).

## Requirements

- **Windows 10/11** with the [WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) (normally already installed with Edge).
- The app requests **Administrator** on start so key events reach the game reliably.

## Run from source

1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Clone this repo and open the folder.
3. Run `a-ragnarok.ahk` (double-click or run with `AutoHotkey64.exe`).

Optional tray icons: run `powershell -ExecutionPolicy Bypass -File scripts\make-ro-macro-icon.ps1` once to create `assets\ro-macro-on.ico` and `ro-macro-off.ico`.

## Version number

Edit the **`VERSION`** file (e.g. `1.0.0`). The script reads it at startup for the in-app version and update checks. **GitHub Release tags** should use the same semver with a `v` prefix (e.g. `v1.0.1`).

## Standalone `.exe` (no AutoHotkey for end users)

From this directory:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
```

Output:

- `dist\RO-Macro-windows-<version>\` — folder to zip or ship as-is: **`RO-Macro.exe`**, **`Lib\`**, **`VERSION`**, and **`assets\`** (if present).
- `dist\RO-Macro-windows-<version>.zip` — convenience archive.

Prerequisites: AutoHotkey v2 installed so **`Ahk2Exe.exe`** and **`AutoHotkey64.exe`** (base binary) are present. The script does **not** use Ahk2Exe’s MPRESS option (that would require a separate `MPRESS.exe` in the Compiler folder and shows a prompt if missing).

## GitHub Releases (CI)

Pushing a tag matching `v*` builds the zip on GitHub Actions and attaches it to the release (see `.github/workflows/release.yml`).

## Updates

The HUD checks GitHub for a newer **release** periodically and shows **Update** in the title bar when `VERSION` is behind the latest release tag. Tray: **Check for updates** / **Open GitHub releases**.

## License

MIT — see [LICENSE](LICENSE).
