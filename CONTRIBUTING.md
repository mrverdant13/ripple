# Contributing

Thank you for helping build Ripple. This guide covers local development, testing
expectations, and collaboration conventions for this repository.

---

## Local development

### Prerequisites

- **Dart SDK** — stable channel (3.5+). [Install Dart](https://dart.dev/get-dart) or
  use Flutter's bundled SDK.
- **Git**

### Clone and bootstrap

```bash
git clone https://github.com/mrverdant13/ripple.git
cd ripple
dart pub get
```

This repository is a **single Dart package** at the repo root (`name: ripple_cli`).
Dependencies resolve with a normal `dart pub get` — no workspace linking or
`pubspec_overrides` generation.

This repo is also a **Ripple consumer**: root `ripple.yaml` drives local and CI
checks via the same `list` / `exec` / `run` surface consumers use. Prefer
`ripple run …` (or `dart run bin/ripple.dart run …` while iterating on the CLI)
over ad-hoc one-off commands once scripts are defined.

### Repository layout

```
ripple/                         # repo root = package root
├── pubspec.yaml                # name: ripple_cli
├── ripple.yaml                 # Repo management scripts (dogfood Ripple)
├── bin/
│   └── ripple.dart             # Thin executable entrypoint (`ripple`)
├── lib/
│   ├── ripple_cli.dart         # Public barrel
│   └── src/
│       ├── ripple.dart         # Programmatic CLI entry (`ripple(...)`)
│       ├── config.dart
│       ├── discovery.dart
│       ├── filters.dart
│       ├── exec.dart           # Process runner helper (cwd/env/exit code)
│       ├── scripts.dart
│       └── commands/
│           ├── commands.dart               # Commands barrel
│           ├── ripple_command.dart         # Base command
│           ├── ripple_command_runner.dart  # CommandRunner
│           ├── list/list.dart
│           ├── exec/exec.dart
│           └── run/run.dart
├── test/
│   └── fixtures/               # mini consumer trees for discovery/filter tests
├── example/                    # optional demo ripple.yaml + tiny packages
├── README.md                   # User-facing overview
└── CONTRIBUTING.md             # This file
```

**Scope of this package:** Ripple is a **repo-agnostic** runner. Consumer repos
provide their own `ripple.yaml`; this package must not hard-code consumer-specific
paths or assume another tool's config format.

### Running the CLI during development

From the repo root (exercises local sources without a global install):

```bash
dart run bin/ripple.dart
dart run bin/ripple.dart list
dart run bin/ripple.dart exec -- dart analyze .
dart run bin/ripple.dart run <script>
```

Optional — install the local package globally while developing:

```bash
dart install 'ripple_cli@{path: .}'
ripple run <script>
```

Use `dart run bin/ripple.dart` when validating unreleased CLI changes. Use a
path or git install when you want the `ripple` executable on your `PATH`.

### Common local checks

Prefer the dogfood scripts in root `ripple.yaml`:

```bash
dart run bin/ripple.dart run format.ci
dart run bin/ripple.dart run analyze.ci
dart run bin/ripple.dart run test.ci
```

Equivalent direct Dart commands (useful for debugging):

```bash
dart format --set-exit-if-changed .
dart analyze --fatal-infos --fatal-warnings .
dart test
```

CI runs these same Ripple scripts on pull requests and pushes to `main`.

### Install from git (consumers)

Ripple is distributed as a **git-consumable** package first (pub.dev optional later).
Install or upgrade the CLI globally with [`dart install`](https://dart.dev/tools/dart-tool)
([package descriptors](https://dart.dev/to/package-descriptors)):

```bash
dart install 'ripple_cli@{git: {url: https://github.com/mrverdant13/ripple.git, ref: ripple_cli/0.0.1-dev.1}}'
```

Pin `ref` to a release tag (`ripple_cli/<version>`, matching `pubspec.yaml`) or a
commit SHA. Re-run the same command to upgrade. For a local checkout:

```bash
dart install 'ripple_cli@{path: /path/to/ripple}'
```

Consumers discover packages via a root `ripple.yaml` (include/exclude globs;
a directory is a package iff it contains `pubspec.yaml`). See [README.md](README.md)
for install, quick start, config schema, and CLI reference.

---

## Testing expectations

All behavior changes should include or update tests.

| Layer | Location | Notes |
| --- | --- | --- |
| Unit / integration | `test/` | Config parse, discovery, filters, scripts, CLI behavior |
| Fixtures | `test/fixtures/` | Mini consumer trees (include/exclude decoys, XOR `run`/`exec`, fail-fast, vars) |

Prioritize coverage for:

- Glob include/exclude and package discovery
- Filter combos (`dirExists`, `fileExists`, `dependsOn`, `group`, `--packages` / `RIPPLE_PACKAGES`)
- Script kind XOR (`run` vs `exec`; reject both, neither, or `filters` on a `run:` script)
- Fail-fast on ad-hoc `exec` and `exec:` scripts
- Variable substitution (`RIPPLE_ROOT_PATH`, `RIPPLE_PACKAGE_PATH`, `RIPPLE_PACKAGE_NAME`)

---

## Commit conventions

This repository uses [Conventional Commits](https://www.conventionalcommits.org/).

### Format

- Setup/infra work (no scope): `<type>: <description>`
- Package work: `<type>(ripple_cli): <description>`
- Multi-package work (when additional packages exist): `<type>(<scope1>,<scope2>): <description>`

PR titles follow the same format as commit messages.

### Allowed types

| Type | Use for |
| --- | --- |
| `chore` | Setup, infrastructure, maintenance |
| `ci` | CI/CD workflow changes |
| `docs` | Documentation-only changes |
| `feat` | New user-facing functionality |
| `fix` | Bug fixes |
| `refactor` | Internal code changes without behavior changes |
| `test` | Test additions or updates |

### Scopes

Scopes name **packages** (not internal modules), so the convention stays valid if
more packages are added later.

| Scope | Area |
| --- | --- |
| `ripple_cli` | This package (repo root today) |

Use `ripple_cli` for changes to the package. For cross-cutting setup or CI-only
changes that are not package-specific, omit the scope: `chore: …`, `ci: …`,
`docs: …`.

When a future change spans more than one package, list every affected package
scope in parentheses, separated by commas (no spaces):

```
feat(ripple_cli,other_pkg): wire shared helper through CLI
```

### Examples

```
chore: scaffold ripple_cli package and bin entrypoint
ci: add format analyze and test workflow
feat(ripple_cli): parse ripple.yaml packages and scripts
feat(ripple_cli): resolve include/exclude globs to pubspec packages
feat(ripple_cli): add list exec and run commands
fix(ripple_cli): treat RIPPLE_PACKAGES as an intersection with CLI flags
test(ripple_cli): cover fixture decoys under exclude globs
docs: add README and CONTRIBUTING
```

---

## Releases

v1 distribution is **git tags** for consumers to pin with `dart install` `ref`.
Automated pub.dev publishing is out of scope until the package is ready for it.

### Tag format

```
ripple_cli/<version>
```

- **`ripple_cli`** — package name (matches `pubspec.yaml` `name:` and commit scope).
- **`<version>`** — exact version string from `pubspec.yaml`. No `v` prefix.

Examples:

```
ripple_cli/0.0.1-dev.1
ripple_cli/0.1.0
```

### Rules

- Tag the commit that contains the version bump for that release.
- The tag version must match `pubspec.yaml` exactly.
- Create an **annotated** tag with a short message naming the package and version.
- Prefer tagging from `main` after the release commit is merged.
- **One package per release tag** — when additional packages exist, tag each
  package independently as `<scope>/<version>`.

### Manual tag (until release automation lands)

```bash
version=$(grep '^version:' pubspec.yaml | awk '{print $2}')
git tag -a "ripple_cli/${version}" -m "ripple_cli ${version}"
git push origin "ripple_cli/${version}"
```

List tags:

```bash
git tag -l 'ripple_cli/*'
```

---

## Pull request guidelines

- Keep PRs **atomic and reviewable** — one logical change per PR.
- Align the **PR title** with the main commit intent, using the same
  [Conventional Commits](#commit-conventions) format.
- Include **tests** for any behavior changes (unit, fixture, or CLI as appropriate).
- Link related issues or milestone items when applicable.
- Do not commit secrets, `.env` files, or local editor state.
- Do not add workspace linking, foreign config importers, or consumer-specific paths.

### Non-goals (do not expand scope in drive-by PRs)

- Importing or emulating another tool's config format
- Dart workspace / `pubspec_overrides` generation
- Script `steps` / multi-script composition inside Ripple
- Versioning, changelog, or publish orchestration beyond git tags (until planned)

### Review checklist

- [ ] Behavior matches documented CLI and config contracts (or documents intentional deviation)
- [ ] Tests added or updated (fixtures when discovery/filters/scripts change)
- [ ] Formatting verified (`dart run bin/ripple.dart run format.ci` or `dart format --set-exit-if-changed .`)
- [ ] Analysis verified (`dart run bin/ripple.dart run analyze.ci` or `dart analyze --fatal-infos --fatal-warnings .`)
- [ ] Tests verified (`dart run bin/ripple.dart run test.ci` or `dart test`)
- [ ] No consumer-specific hard-coding in the package
- [ ] Public CLI/config changes reflected in `README.md` when user-facing

---

## Documentation

| Artifact | Audience |
| --- | --- |
| [README.md](README.md) | Users — install, quick start, CLI / `ripple.yaml` reference |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributors — this guide |

When adding user-facing behavior, update `README.md` (and this guide when
contributor workflow changes) in the same PR.

---

## Questions

Open an issue for bugs, design questions, or scope clarifications. For behavior
changes, update `README.md` and this guide in the same PR so user and contributor
docs stay in sync.
