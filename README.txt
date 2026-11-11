Lobby Map Self-Test (LobbyMapSelfTest)
=============

A Windows PowerShell tool for packaging Minecraft (NetEase / MC Studio) lobby map
projects and uploading them to the online-lobby self-test flow.

Full documentation (Chinese, with English quick start): README.md

Quick start:
1. Run 配置上传自测.cmd (or .\Upload-LobbySelfTest.ps1 -ConfigureOnly).
2. Fill in the lobby component ID, developer-platform Cookie, map source
   directory, output directory and exclusion rules.
3. Run Pack-LobbyMap.cmd to package only.
4. Run 打包并上传自测.cmd to package, upload and wait for the self-test.

Security:
- The Cookie is encrypted with Windows DPAPI for the current Windows user.
- lobby-test.local.json, lobby-test.last.json and packages/ are gitignored.
- Never commit a real Cookie, project ID, personal path or task record.

License: MIT. See LICENSE.
Third-party notices: THIRD-PARTY-NeLobbyAutoKit-LICENSE.txt.
Credits: QUMOD / QuModLibs / NeLobbyAutoKit (Zero123, BSD-3-Clause).
