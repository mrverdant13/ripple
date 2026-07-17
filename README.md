# Ripple

Repo-agnostic CLI for discovering Dart packages and running commands or named
scripts across a consumer repository via `ripple.yaml`.

## `ripple.yaml`

Place a `ripple.yaml` at the root of the consumer repository. Ripple walks
upward from the current working directory until it finds this file; that file's
directory is the Ripple root.

### Top-level keys

| Key | Required | Description |
| --- | --- | --- |
| `name` | no | Optional display name for the workspace. |
| `packages` | no | Package discovery settings (`include`, `exclude`, `groups`). |
| `scripts` | no | Named scripts keyed by id (ids may contain dots, e.g. `format.ci`). |

### `packages`

```yaml
packages:
  include:
    - packages/*
    - tool
  exclude:
    - '**/example/**'
    - '**/test/**'
  groups:
    core:
      - packages/a
      - packages/b
```

- **`include`** — glob patterns relative to the Ripple root for candidate
  package directories (a directory is a package iff it contains `pubspec.yaml`).
- **`exclude`** — glob patterns subtracted from include matches.
- **`groups`** — named sets of path globs used when filtering by group.

### `scripts`

Each script must declare **exactly one** of `run:` or `exec:`:

- **`run:`** — execute once with cwd = the Ripple root. Must not declare
  `filters`.
- **`exec:`** — execute once per matching package with cwd = that package.
  Optional `filters` may include `dirExists`, `fileExists`, `dependsOn`, and
  `group`.

```yaml
scripts:
  format.ci:
    run: dart format --set-exit-if-changed .

  analyze.ci:
    exec: dart analyze --fatal-infos --fatal-warnings .
    filters:
      dirExists: [lib]
```

Invalid configs (both `run` and `exec`, neither, `filters` on a `run:` script,
or malformed YAML) fail with a clear config error.

## Commands

### `ripple list`

Print packages discovered from `packages.include` / `packages.exclude`, after
optional filters. Output is one relative path per line (relative to the Ripple
root), sorted for stable review.

```bash
ripple list
ripple list --group libs
ripple list --packages core,ui
ripple list --dir-exists test
ripple list --file-exists README.md
ripple list --depends-on path
```

| Flag | Description |
| --- | --- |
| `--group <name>` | Only packages in that named `packages.groups` entry. |
| `--packages <a,b>` | Comma-separated package names; intersected with other filters. |
| `--dir-exists <path>` | Only packages that contain this relative directory (repeatable, AND). |
| `--file-exists <path>` | Only packages that contain this relative file (repeatable, AND). |
| `--depends-on <pkg>` | Only packages that declare this direct dependency (repeatable, AND). |

`RIPPLE_PACKAGES` (comma-separated names) intersects with `--packages` and every
other active filter. Running outside any `ripple.yaml` ancestry fails with a
config-not-found error.
