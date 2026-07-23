# Ripple

Repo-agnostic CLI for discovering Dart packages and running commands or named
scripts across a consumer repository via `ripple.yaml`.

Ripple does **not** manage Dart workspaces, generate `pubspec_overrides`, or
link packages. Each package stays independent; Ripple only discovers directories
that contain a `pubspec.yaml` and runs processes in them (or once at the repo
root for `run:` scripts).

## Install

Requires the [Dart SDK](https://dart.dev/get-dart) (stable 3.5+).

Distribution for v1 is **git tags** (not pub.dev). Install the `ripple`
executable globally with [`dart install`](https://dart.dev/tools/dart-install)
using a [package descriptor](https://dart.dev/to/package-descriptors):

```bash
dart install 'ripple_cli@{git: {url: https://github.com/mrverdant13/ripple.git, ref: ripple_cli/<version>}}'
```

The `ref` must be a git tag (or commit SHA). Release tags follow
`ripple_cli/<version>`, where `<version>` is the exact string from
`pubspec.yaml` (no `v` prefix).

Equivalent URL form:

```bash
dart install https://github.com/mrverdant13/ripple.git --git-ref ripple_cli/<version>
```

Re-run the same command to upgrade. For a local checkout:

```bash
dart install 'ripple_cli@{path: /path/to/ripple}'
```

Confirm the install:

```bash
ripple --version
# ripple_cli <version>
```

## Quick start

1. **Add a `ripple.yaml`** at the root of your consumer repository:

   ```yaml
   name: my_repo

   packages:
     include:
       - packages/*
       - tool
     exclude:
       - '**/example/**'

   scripts:
     format:
       run: dart format --set-exit-if-changed .
     analyze:
       exec: dart analyze --fatal-infos --fatal-warnings .
       filters:
         - dirExists: [lib]
   ```

2. **List discovered packages** (directories under `include` that contain
   `pubspec.yaml`, minus `exclude`):

   ```bash
   ripple list
   ```

3. **Run an ad-hoc command** once per matching package (pass the command after
   `--`):

   ```bash
   ripple exec -- dart test
   ```

4. **Run a named script** from `ripple.yaml`:

   ```bash
   ripple run format
   ripple run analyze
   ```

Ripple walks upward from the current working directory until it finds
`ripple.yaml`; that file's directory is the Ripple root.

## `ripple.yaml`

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
  Patterns that match the Ripple root itself (e.g. `**`, `.`) select the root
  package when it has a `pubspec.yaml`.
- **`exclude`** — glob patterns subtracted from include matches.
- **`groups`** — named sets of path globs used when filtering by group.

### `scripts`

Each script must declare **exactly one** of `run:` or `exec:` (XOR):

- **`run:`** — execute once with cwd = the Ripple root. Must not declare
  `filters`.
- **`exec:`** — execute once per matching package with cwd = that package.
  Optional `filters` is a **list** of single-key filter nodes (see below).

The value of `run:` / `exec:` is either a **string** (one command) or a **YAML
list of strings** (sequential steps). Steps always stop on the first non-zero
exit. For `exec:` lists, all steps run for a package before the next package
(unless `--fail-fast` stops package iteration). Commands are not run through a
shell — use `sh -c '…'` inside a step when you need pipes, redirects, or other
shell features. Unquoted `&&` in a string command is rejected; use a YAML list
instead.

```yaml
scripts:
  format.ci:
    run: dart format --set-exit-if-changed .

  check.ci:
    run:
      - dart format --set-exit-if-changed .
      - dart analyze --fatal-infos --fatal-warnings .
      - dart test

  analyze.ci:
    exec: dart analyze --fatal-infos --fatal-warnings .
    filters:
      - dirExists: [lib]
      - match: ['*_api', core]
      - noMatch: ['*_test']

  test.e2e:
    exec: dart test
    filters:
      - match: ['*_app']
      - or:
          - dependsOn: [test]
          - dirExists: [test]
      - and:
          - noMatch: ['*_test']
          - fileExists: [pubspec.yaml]
```

`filters` is list-form only. A top-level list is an implicit **and**. Nested
`and` / `or` nodes are allowed. Each node is a map with **exactly one** key:

| Key | Value | Semantics |
| --- | --- | --- |
| `and` / `or` | list of filter nodes | Boolean combination |
| `dirExists` / `fileExists` | list of relative paths | Every path must exist (AND) |
| `dependsOn` | list of package names | Every name must be a direct dep (AND) |
| `group` | string | Package must be in that `packages.groups` entry |
| `match` | list of name globs | Package name matches any glob (OR) |
| `noMatch` | list of name globs | Package name matches none (OR exclude) |

`match` / `noMatch` are **package-name** globs (not path globs). They are
distinct from top-level `packages.include` / `packages.exclude`, which match
relative package paths. CLI flat flags (`--match`, `--dir-exists`, …) build an
in-memory `and` of the same leaf kinds. CLI `--no-match` follows the
`--no-<filter>` / `no<Filter>` negation pattern.

Map-form filters (a YAML map of leaf keys) are rejected. Invalid configs (both
`run` and `exec`, neither, `filters` on a `run:` script, empty command lists,
unquoted `&&` in a string command, invalid filter nodes, or malformed YAML)
fail with a clear config error.

There is no cross-script composition (for example referencing other script ids
inside a list). Compose named scripts from the shell when needed
(`ripple run format.ci && ripple run analyze.ci`).

## Commands

### `ripple list`

Print packages discovered from `packages.include` / `packages.exclude`, after
optional filters. Output is one relative path per line (relative to the Ripple
root), sorted for stable review.

```bash
ripple list
ripple list --group libs
ripple list --match core --match ui
ripple list --no-match '*_test'
ripple list --dir-exists test
ripple list --file-exists README.md
ripple list --depends-on path
```

| Flag | Description |
| --- | --- |
| `--group <name>` | Only packages in that named `packages.groups` entry. |
| `--match <glob>` | Only packages whose name matches this glob (repeatable, OR). |
| `--no-match <glob>` | Exclude packages whose name matches this glob (repeatable, OR). |
| `--dir-exists <path>` | Only packages that contain this relative directory (repeatable, AND). |
| `--file-exists <path>` | Only packages that contain this relative file (repeatable, AND). |
| `--depends-on <pkg>` | Only packages that declare this direct dependency (repeatable, AND). |

`RIPPLE_PACKAGES` (comma-separated **exact** package names, not globs)
intersects with `--match` / `--no-match` and every other active filter. Running
outside any `ripple.yaml` ancestry fails with a config-not-found error.

### `ripple exec`

Run an ad-hoc command **once per matching package**, sequentially, with cwd set
to each package directory. Pass the executable and its arguments after `--`.

Each package is wrapped in begin/end stderr banners using that package's
relative path (same form as [`ripple list`](#ripple-list)). Inside that
block, Ripple also prints start/end banners for the resolved command (after
`$RIPPLE_*` substitution) so each argv is visible next to its output:

```text
[ripple] ▶ packages/core
[ripple] $ dart analyze .
… command output …
[ripple] $ dart analyze .  (exit 0)
[ripple] ■ packages/core  (exit 0)
```

On an interactive terminal, banners are colorized (cyan start; green or red
end by exit code). Color is disabled when stderr is not a TTY, when
`NO_COLOR` is set, or when `TERM=dumb`. If the previous command left the
cursor mid-line (for example `printf` without a trailing newline), Ripple
inserts a newline before the next banner so markers stay on their own line.

```bash
ripple exec -- dart analyze .
ripple exec --group libs -- dart test
ripple exec --match core --match ui --fail-fast -- dart format --set-exit-if-changed .
```

Uses the same filter flags as [`ripple list`](#ripple-list). Additional flag:

| Flag | Description |
| --- | --- |
| `--fail-fast` | Stop after the first package whose command exits non-zero. |

Without `--fail-fast`, every selected package still runs; the overall exit code
is the first non-zero package exit (or `0` when all succeed).

Missing `--` / an empty command fails with a usage error.

### `ripple run`

Execute a named script from `ripple.yaml`. Script ids may contain dots
(e.g. `format.ci`).

```bash
ripple run format.ci
ripple run analyze.ci --group libs
ripple run analyze.ci --match core --match ui --fail-fast
```

Behavior depends on the script kind:

- **`run:`** — runs once with cwd = the Ripple root (all list steps in order).
  Only `RIPPLE_ROOT_PATH` is set. Package filters (`--group`, `--match`,
  `--no-match`, `--dir-exists`, `--file-exists`, `--depends-on`, and
  `RIPPLE_PACKAGES`) are rejected. Each step gets command start/end stderr
  banners (no package-scope banners).
- **`exec:`** — for each matching package, runs all list steps in that package
  (same sequential / fail-fast model as [`ripple exec`](#ripple-exec)).
  Script-declared `filters` are intersected with CLI filters and
  `RIPPLE_PACKAGES`. Package path/name vars are set in addition to
  `RIPPLE_ROOT_PATH`. Begin/end stderr package-scope banners are printed once
  per package; each step also gets its own command start/end banners. The
  package end banner reports that package's exit code.

Uses the same filter flags as [`ripple list`](#ripple-list). Additional flag:

| Flag | Description |
| --- | --- |
| `--fail-fast` | For `exec:` scripts, stop after the first package whose command exits non-zero. |

Unknown script names fail with a clear error that lists available scripts.

## Environment variables

Child processes receive these variables in the environment (and as `$VAR` /
`${VAR}` substitutions in command arguments):

| Variable | Value |
| --- | --- |
| `RIPPLE_ROOT_PATH` | Absolute path to the Ripple root (directory containing `ripple.yaml`). Always set. |
| `RIPPLE_PACKAGE_PATH` | Absolute path to the current package directory. Set for `exec` / `exec:` only. |
| `RIPPLE_PACKAGE_NAME` | Package name from that package's `pubspec.yaml`. Set for `exec` / `exec:` only. |

`RIPPLE_PACKAGES` (exact name allowlist selection filter) is read by Ripple
itself; it is not injected into child processes beyond normal
parent-environment inheritance.

## Non-goals

Ripple intentionally does **not**:

- Create or manage Dart **workspaces**
- Generate **`pubspec_overrides.yaml`** or otherwise link packages
- Provide cross-script composition or sip-style `${{ }}` references (use a YAML
  list for in-script steps, or shell `&&` between `ripple run` invocations)
- Discover packages by anything other than `pubspec.yaml` presence under
  include/exclude globs
- Publish to pub.dev as the v1 distribution channel (use git tags with
  `dart install` as above)
