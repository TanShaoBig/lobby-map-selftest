# Lobby Map Self-Test (LobbyMapSelfTest)

[中文文档](README.md) · English overview

A Windows PowerShell tool for packaging Minecraft (NetEase / MC Studio)
**lobby maps** and driving the online-lobby self-test upload flow.
Keywords: lobby map, self-test, map packager, MC Studio, Cookie.

> Unofficial community tool. Not affiliated with NetEase, MC Studio, Mojang,
> or the QUMOD project. Test on a disposable project first.

## What it does

- Packages a map project into a lobby-ready ZIP with a configurable top-level
  directory (`map/` by default).
- Replaces every pack header/module UUID with a fresh v4 UUID, updating internal
  dependencies and both `world_*_packs.json` files. Versions stay unchanged.
- Supports configurable **exclusion rules** (`*`, `**`, `?`, `!` negation)
  instead of hard-coded `.pyc` / `__pycache__` / `.gitignore` filters.
- Stores the **lobby component ID** (`item_id`) and the developer-platform
  **Cookie** locally. The Cookie is encrypted with Windows DPAPI for the
  current Windows user.
- Runs the full flow: package → upload → update project resource → apply for
  self-test → wait until ready.
- Provides status query, old self-test cancellation, and safe recovery from
  uncertain write results without automatic replay.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in)
- .NET Framework 4.6+ (built in)

## Quick start

```powershell
git clone https://github.com/TanShaoBig/lobby-map-selftest.git
cd lobby-map-selftest

# Open the configuration window
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Upload-LobbySelfTest.ps1 -ConfigureOnly

# Package only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pack-LobbyMap.ps1

# Package, upload and wait for the self-test
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Upload-LobbySelfTest.ps1
```

The configuration dialog asks for:

1. Lobby component ID (`item_id`);
2. Developer-platform Cookie (F12 → Network → a request starting with `me` →
   copy the request header `Cookie`);
3. Map source directory;
4. ZIP output directory (empty = `packages/` beside the scripts);
5. Exclusion rules, one per line.

## Exclusion rules

Patterns match paths relative to the map source root, use `/`, and are
case-insensitive. Rules are evaluated in order; a later `!` rule re-includes a
path matched earlier.

```text
**/*.pyc
**/__pycache__/**
**/.gitignore
**/.git/**
**/*.log
!behavior_packs/my_pack/keep.pyc
```

Defaults:

```text
**/*.pyc
**/__pycache__/**
**/.gitignore
```

## Configuration file

`lobby-test.local.json` (gitignored), schema version 2:

```json
{
  "schemaVersion": 2,
  "modId": "YOUR_LOBBY_COMPONENT_ID",
  "cookieProtected": "<DPAPI ciphertext, written by the dialog>",
  "sourcePath": "D:\\maps\\my_map",
  "outputDirectory": "",
  "archiveRoot": "map",
  "includeDirectories": ["behavior_packs", "db", "resource_packs"],
  "includeFiles": ["level.dat", "level.dat_old", "levelname.txt", "world_behavior_packs.json", "world_icon.jpeg", "world_resource_packs.json"],
  "excludePatterns": ["**/*.pyc", "**/__pycache__/**", "**/.gitignore"]
}
```

See [`config.example.json`](config.example.json). Never commit a real Cookie,
project ID, personal path, or task record.

## Tests

All tests are offline and use fake credentials and an in-memory HTTP handler:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PackRules.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LobbySelfTestConfig.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LobbySelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LobbySelfTestCancel.ps1
```

## Credits

The upload / lobby self-test protocol implementation refers to the QUMOD
ecosystem:

- [QuMod online-test documentation](https://qumod.cc/QuModLibs/Modules/MultiplayerLobby/QuickLobbyManager.html#线上测试)
- [QuModLibs Tools/NeLobby](https://github.com/GitHub-Zero123/QuModLibs/tree/master/Tools/NeLobby)
- [NeLobbyAutoKit](https://gitee.com/bili_zero123/ne-lobby-auto-kit) by Zero123 (BSD-3-Clause)

The upstream license is reproduced in
[`THIRD-PARTY-NeLobbyAutoKit-LICENSE.txt`](THIRD-PARTY-NeLobbyAutoKit-LICENSE.txt).
This project does not download or execute the upstream executable.

## License

[MIT](LICENSE) © 2026 TanShaoBig and contributors
