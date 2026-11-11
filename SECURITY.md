# Security Policy

## Supported versions

The latest commit on the `main` branch is supported.

## Reporting a vulnerability

Please **do not** open a public issue for a security problem. Use GitHub's
private vulnerability reporting on this repository (Security → Report a
vulnerability) or contact the maintainer through the GitHub profile listed in
`LICENSE`.

Include the affected script, reproduction steps, and the impact. Please avoid
including real Cookies, project IDs, or platform task records in the report.

## Credential handling

- The developer-platform Cookie is stored only as a Windows DPAPI ciphertext
  bound to the current Windows user (`lobby-test.local.json`).
- The plaintext Cookie exists only in process memory during a request.
- The Cookie is sent only to `https://mc-launcher.webapp.163.com`.
- The ZIP upload goes to the temporary file-picker URL and does not carry the
  Cookie.
- `lobby-test.local.json`, `lobby-test.last.json`, `lobby-test.lock` and
  `packages/` are excluded by `.gitignore`.

If you believe a credential was exposed, revoke the developer-platform session
and reconfigure the tool on a trusted machine.

## Scope

This is an unofficial community tool. It is not affiliated with NetEase,
MC Studio, Mojang Studios or the QUMOD project.
