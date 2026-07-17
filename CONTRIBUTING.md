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

### Repository layout

```
ripple/                         # repo root = package root
├── pubspec.yaml                # name: ripple_cli
├── bin/
│   └── ripple.dart             # CLI entrypoint (`ripple`)
├── lib/
│   ├── ripple_cli.dart
│   └── src/
│       ├── config.dart
│       ├── discovery.dart
│       ├── filters.dart
│       ├── exec.dart
│       ├── scripts.dart
│       └── cli/
│           ├── list_command.dart
│           ├── exec_command.dart
│           └── run_command.dart
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

From the repo root:

```bash
dart run bin/ripple.dart
dart run bin/ripple.dart list
dart run bin/ripple.dart exec -- dart analyze .
dart run bin/ripple.dart run <script>
```

Use `dart run` against the local package so changes are exercised without relying
on a globally activated `ripple` binary.

### Common local checks

```bash
dart format --set-exit-if-changed .
dart analyze --fatal-infos --fatal-warnings .
dart test
```

Once CI workflows land, prefer the same checks CI runs (format / analyze / test).

### Install from git (consumers)

Ripple is distributed as a **git-consumable** package first (pub.dev optional later):

```bash
dart pub global activate \
  --source git https://github.com/mrverdant13/ripple.git \
  --git-ref <tag-or-sha>
```

Consumers discover packages via a root `ripple.yaml` (include/exclude globs;
a directory is a package iff it contains `pubspec.yaml`). See [README.md](README.md)
for the config schema and CLI surface once documented there.

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
- Script kind XOR (`run` vs `exec`; reject both, neither, or `filters` on `run:`)
- Fail-fast on ad-hoc `exec` and `exec:` scripts
- Variable substitution (`RIPPLE_ROOT_PATH`, `RIPPLE_PACKAGE_PATH`, `RIPPLE_PACKAGE_NAME`)

---

## Commit conventions

This repository uses [Conventional Commits](https://www.conventionalcommits.org/).

### Format

- Setup/infra work (no scope): `<type>: <description>`
- Scoped work (one area): `<type>(<scope>): <description>`
- Scoped work (multiple areas): `<type>(<scope1>,<scope2>): <description>`

Use a **single scope** when the change is confined to one area. Use **multiple
comma-separated scopes** (no spaces) when a PR or commit intentionally spans more
than one.

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

Use scopes for changes tied to a specific area of the package:

| Scope | Area |
| --- | --- |
| `config` | `ripple.yaml` parsing and validation |
| `discovery` | Include/exclude globs and package discovery |
| `filters` | `dirExists` / `fileExists` / `dependsOn` / `group` / package scope |
| `exec` | Ad-hoc and scripted command execution |
| `scripts` | Named `run:` / `exec:` scripts |
| `cli` | Command runner and `list` / `exec` / `run` commands |

For cross-cutting setup or CI-only changes, omit the scope: `chore: …`, `ci: …`,
`docs: …`.

### Multiple scopes

When a change touches more than one scoped area, list every affected scope in
parentheses, separated by commas:

```
feat(discovery,filters): intersect group selection with package filters
fix(exec,scripts): honor fail-fast for named exec scripts
```

Guidelines:

- Include only scopes that are **meaningfully changed**.
- Prefer **one scope** when one area owns the change.
- The **PR title** should use the same scoped format as the primary commit when
  the PR spans multiple areas.

### Examples

```
chore: scaffold ripple_cli package and bin entrypoint
ci: add format analyze and test workflow
feat(config): parse ripple.yaml packages and scripts
feat(discovery): resolve include/exclude globs to pubspec packages
feat(cli): add list exec and run commands
fix(filters): treat RIPPLE_PACKAGES as an intersection with CLI flags
test(discovery): cover fixture decoys under exclude globs
docs: add README and CONTRIBUTING
```

---

## Releases

v1 distribution is **git tags** for consumers to pin with `--git-ref`. Automated
pub.dev publishing is out of scope until the package is ready for it.

### Tag format

```
ripple_cli/<version>
```

- **`ripple_cli`** — package name (matches `pubspec.yaml` `name:`).
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
- [ ] Formatting verified (`dart format --set-exit-if-changed .`)
- [ ] Analysis verified (`dart analyze --fatal-infos --fatal-warnings .`)
- [ ] Tests verified (`dart test`)
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
