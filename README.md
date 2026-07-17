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
         dirExists: [lib]
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
- **`exclude`** — glob patterns subtracted from include matches.
- **`groups`** — named sets of path globs used when filtering by group.

### `scripts`

Each script must declare **exactly one** of `run:` or `exec:` (XOR):

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

There is no `steps` / multi-script composition inside Ripple — compose with the
shell (`&&`) outside the tool.

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

### `ripple exec`

Run an ad-hoc command **once per matching package**, sequentially, with cwd set
to each package directory. Pass the executable and its arguments after `--`.

```bash
ripple exec -- dart analyze .
ripple exec --group libs -- dart test
ripple exec --packages core,ui --fail-fast -- dart format --set-exit-if-changed .
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
ripple run analyze.ci --packages core,ui --fail-fast
```

Behavior depends on the script kind:

- **`run:`** — runs once with cwd = the Ripple root. Only `RIPPLE_ROOT_PATH` is
  set. Package filters (`--group`, `--packages`, `--dir-exists`,
  `--file-exists`, `--depends-on`, and `RIPPLE_PACKAGES`) are rejected.
- **`exec:`** — runs once per matching package (same sequential / fail-fast
  model as [`ripple exec`](#ripple-exec)). Script-declared `filters` are
  intersected with CLI filters and `RIPPLE_PACKAGES`. Package path/name vars
  are set in addition to `RIPPLE_ROOT_PATH`.

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

`RIPPLE_PACKAGES` (selection filter) is read by Ripple itself; it is not
injected into child processes beyond normal parent-environment inheritance.

## Non-goals

Ripple intentionally does **not**:

- Create or manage Dart **workspaces**
- Generate **`pubspec_overrides.yaml`** or otherwise link packages
- Provide script **`steps`** / multi-script composition (use shell `&&` instead)
- Discover packages by anything other than `pubspec.yaml` presence under
  include/exclude globs
- Publish to pub.dev as the v1 distribution channel (use git tags with
  `dart install` as above)
