# AGENTS.md

## Project

Pneuma is a single-host deployment CLI in Rust. It imports applications declared
by `pneuma.toml`, deploys prebuilt OCI artifacts supplied directly or resolved
from Git branches, and runs them rootlessly with Podman and systemd Quadlet on
loopback. It health-checks candidates and exposes public applications through
Caddy. State lives in SQLite via bundled rusqlite.

This is one Cargo package with a library crate (`src/lib.rs`) and CLI entrypoint
(`src/main.rs`). The library is organized into these layers:

- `src/domain/` — domain entities and manifest-free value types. Entity modules
  are simple data types; `domain/manifest.rs` holds only the validated
  `ImportSpecification` input.
- `src/use_cases/` — business rules and orchestration.
- `src/adapters/` — SQLite stores, Git, OCI, manifest parsing (`adapters/manifest.rs`),
  Podman, systemd Quadlet, Caddy, health checks, port allocation, and database
  integration.

`src/main.rs` is the process bootstrap and composition entrypoint: it loads host
configuration (`/etc/pneuma/environment`), derives the uid-scoped runtime
environment, parses the CLI invocation, dispatches through `src/cli/`, and maps
the result to a classified exit code. The CLI layer (`src/cli/`) owns argument
parsing, dependency construction, handlers by capability, output rendering, and
error classification. Do not put domain rules there.

External command integrations use child processes (`git`, `podman`, `systemctl`,
`caddy`, `curl`, and `df`). SQLite, filesystem operations, and internal TCP
health checks are direct. There is no async code.

## Authority And Sources Of Truth

Authority depends on the concern; do not use a stale document to override code
or an approved decision.

1. The latest explicit user instruction authorizes work.
2. `docs/iterations/current-iteration.md` is the sole execution tracker. Its
   first pending checkpoint is the next item to implement.
3. An approved, indexed design document defines the scope, fixed decisions, and
   non-goals of that iteration.
4. `docs/roadmap.md` defines milestone order and version-level scope.
5. Code, migrations, and tests define implemented behavior when descriptive
   documentation disagrees with them.
6. `docs/architecture/architecture.md` describes implemented architecture.
7. `docs/rust-guidelines.md` defines Rust conventions.
8. `.github/workflows/ci.yml` defines the exact CI gates.
9. `docs/README.md` identifies designated living documents. Unindexed drafts
   and historical documents are not authoritative.

If the tracker, approved design, roadmap, and implemented behavior conflict in
a way that changes scope or behavior, stop and update or clarify the governing
documents before implementing code.

`AGENTS.md` is intentionally local and gitignored. Never commit it. Changes to
this file affect only this workspace and must not be treated as durable project
history.

## Execution Preflight

Before starting or resuming an implementation checkpoint:

```text
git status --short --branch
git diff
git log --oneline -10
```

Then:

- read the current iteration, the approved design it references, the relevant
  roadmap section, architecture, Rust guidelines, and CI workflow;
- confirm that the iteration is `em andamento`, the approved design is committed
  and internally complete, and the first pending checkpoint is unambiguous;
- identify unrelated worktree changes and their ownership before touching files;
- establish the relevant baseline with focused tests when practical.

Do not begin code from a concluded tracker, an uncommitted or truncated design,
or contradictory planning documents. Report the blocker instead.

## Scope And Change Control

- Implement one logical iteration checkpoint at a time. Later checkpoints are
  not permission to implement ahead.
- Implement the smallest correct change for the current checkpoint. Avoid
  opportunistic refactors and roadmap work outside it.
- Fixed decisions and non-goals in an approved design require user approval
  before changing them. Update the approved design before code when a decision
  changes.
- Classify newly discovered work as one of: necessary for the current acceptance
  criterion, a blocker, or a deferred follow-up. Do not silently expand scope.
- Do not weaken acceptance criteria, remove tests, or edit the roadmap merely to
  make a checkpoint appear complete.
- Never reset, stash, overwrite, stage, or revert unexplained changes. Stage
  explicit paths only. If unrelated changes overlap the checkpoint, stop and
  resolve ownership or use an isolated worktree.


## Architecture And Persistence

- Use cases own business decisions, orchestration, ordering, transaction
  boundaries spanning multiple writes, and compensation after external effects.
- Stores own SQL, row-to-domain mapping, persisted-value conversion, and
  compare-and-set persistence primitives.
- External adapters own Git, OCI, Podman, systemd, Caddy, and health effects.
- Never hold a SQLite transaction during Git, OCI, Podman, systemd, Caddy, or
  HTTP work.
- Use `Option<T>` for expected absence. Do not turn missing values or store
  errors into invented identifiers such as `"unknown"`.
- Treat a zero-row compare-and-set update as a stale/concurrent state, not a
  successful write.

## Rust Conventions

`docs/rust-guidelines.md` is binding. In particular:

- Prefer concrete structs, enums, and functions. Do not add traits, generics,
  factories, plugins, shared ownership, interior mutability, async, or
  dependencies for hypothetical needs.
- Add abstractions only for demonstrated use cases; use async only for real
  concurrent I/O.
- Keep functions cohesive, success paths visible, and side effects explicit.
- Preserve error context and avoid `unwrap()`/`expect()` in production paths.
- Test observable behavior and invariants, not private implementation details.
- Run its Final Review checklist before finishing code.

Code, tests, and commit messages are English. Most project docs are Portuguese;
`docs/rust-guidelines.md` is English. Match the language of the file edited.

## Paths And Configuration

Tests override these configurable locations. Do not hardcode substitutes for
them:

- `PNEUMA_DATABASE_PATH` (default `/var/lib/pneuma/database/pneuma.sqlite3`)
- `PNEUMA_WORKSPACE_PATH` (default `/var/lib/pneuma/checkouts`)
- `PNEUMA_CADDY_MANAGED_PATH` (default `/etc/caddy/applications`)
- `PNEUMA_CADDYFILE_PATH` (default `/etc/caddy/Caddyfile`)
- `PNEUMA_RUNTIME_PORT_RANGE` (default `30000-39999`)
- `PNEUMA_QUADLET_DIR` (default `$HOME/.config/containers/systemd`)

## Local readability refactor plan

When working on the current readability/error-simplification refactor, follow the local plan in `.agent-plan/pneuma-readability-refactor/`.

At the start of a work session, read in this order:

1. `.agent-plan/pneuma-readability-refactor/RULES.md`
2. `.agent-plan/pneuma-readability-refactor/STATUS.md`
3. only the next incomplete file under `.agent-plan/pneuma-readability-refactor/iterations/`

Do not preload all iteration files into context. Treat one iteration as one focused session and normally one commit.

Before editing, inspect the current repository, callers, and relevant tests. The repository is authoritative; the plan defines intent and constraints, not guaranteed-current implementation details.

After completing the iteration, run its validation, commit only that focused change, update `STATUS.md` with the result and commit hash, then stop before starting the next iteration.

Do not perform architecture redesign, speculative abstractions, behavioral changes, or unrelated cleanup unless the current iteration explicitly requires it.

## Migrations

- Historical migrations are immutable.
- Create `migrations/NNNN_description.sql` using the next sequential number.
- Register it in `MIGRATIONS` in `src/adapters/database.rs` with `include_str!`.
- Update migration-count assertions in that file's tests.
- Test a fresh database and an upgrade from the immediately preceding schema.
- When a migration backfills or transforms persisted behavior, seed
  representative historical data and assert the resulting rows explicitly.

## Testing And Verification

Binary-level CLI tests use `env!("CARGO_BIN_EXE_pneuma")` with temporary
directories. Deployment scenarios fake `podman`, `systemctl`, `caddy`, and
`curl` through `PATH`; follow `DeploymentEnvironment` in `tests/cli.rs`.
Other integration tests call library APIs directly. Git-related scenarios require
real `git`; manifest fixtures are under `tests/fixtures/`.

Use this verification ladder:

1. During development, run focused tests for the changed behavior.
2. Before every code checkpoint, run the exact CI gates:

   ```text
   cargo fmt --check
   cargo clippy --all-targets --all-features -- -D warnings
   cargo test --all-features
   cargo build --workspace --release
   ```

3. For migrations, run fresh-schema and upgrade coverage.
4. For CLI or external-effect changes, run the focused CLI/integration tests.
5. At iteration closure, repeat all gates on the final code commit and run all
   environment-dependent regression required by the acceptance criteria.

Discover ignored tests from the current source rather than relying on a fixed
count. Run them only on a configured rootless Podman host; record any registry,
network, VM, or credential prerequisite. Never call unavailable environment
tests green. Record their actual PASS/FAIL/SKIP result and the reason for skips.

## Disposable VM Testing

- `pneuma-dev-base` is the immutable clean Debian 13 template. Never start,
  modify, snapshot, undefine, delete, or otherwise alter it.
- `scripts/dev-vm/test-regression.sh` is the standard path for disposable
  regression: it clones, provisions, installs binary and CI key, runs the
  requested suites, and always destroys `pneuma-dev-base-test`. Prefer it over
  manual lifecycle steps; its guards enforce the rules below automatically.
- Before any destructive or bootstrap/E2E VM test, create a fresh
  `pneuma-dev-base-test` clone from `pneuma-dev-base` through
  `qemu:///system`. Destroy and delete only that disposable clone after the
  test, whether it passes or fails.
- Use the root VM password `121558` only for root provisioning access to the
  disposable clone. Do not write it to repository files, tracker entries, logs,
  or commits. It may be passed to `sshpass` only for a disposable
  `pneuma-dev-base-test` clone when no provisioning SSH key is available.
- Use the existing repository test CI key `~/.ssh/pneuma-ci-test` (and its
  `.pub` file) for SSH dispatcher tests. The bootstrap acceptance runner owns
  installing that public key as the restricted `pneuma` identity; do not use a
  root key to test the dispatcher.

## Checkpoints And Commits

One coherent, green implementation checkpoint maps to one conventional commit.
Use appropriate Conventional Commit prefixes such as `feat:`, `fix:`, `docs:`,
`refactor:`, `test:`, and `chore:`, with scopes when useful.

For each code checkpoint:

1. Implement the smallest coherent change and its proportional tests.
2. Run focused tests and the four CI gates.
3. Update only the corresponding entry in `current-iteration.md`: mark it done
   and add one concise result line when needed.
4. Commit implementation, tests, implemented-behavior documentation, and that
   tracker update together.
5. Do not start the next checkpoint until the current one is green or recorded
   as blocked.

Do not create routine documentation-only checkpoint commits. The tracker update
belongs in the implementation checkpoint. If commits have not been authorized,
stop at a commit-ready checkpoint and report the exact files, checks, and
proposed subject.

The final iteration closure is different: after all criteria are met, make one
`docs:` commit containing only `docs/iterations/current-iteration.md`.

## Blockers And Recovery

When work cannot safely continue, leave the criterion unchecked and record in
the tracker:

- blocked checkpoint;
- category: code, environment, permissions, decision, or external dependency;
- failing command and concise diagnostic;
- last green checkpoint; and
- next safe action.

Do not bypass a blocker by weakening checks, deleting tests, broadening scope,
or claiming an unavailable environment check passed. If a VM/E2E failure exposes
a product defect, reopen the affected checkpoint, make a focused `fix:`
checkpoint, rerun the gates, then rerun the affected and full required VM
regression.

Dirty state is not durable resumability. For a handoff or machine change, finish
a coherent green checkpoint or leave clearly identified, uncommitted draft work
with its blocker recorded. Never revert changes that were not made in the
current checkpoint.

## Documentation, Iteration, And Roadmap Closure

- The approved design fixes decisions and scope. Do not use it as a daily
  progress tracker.
- `current-iteration.md` is concise: status, base/design reference, ordered
  checkpoints, acceptance criteria, blockers, and validation evidence. Do not
  turn it into a debugging diary with temporary paths or machine-specific notes.
- Update architecture, README, roadmap, and operational docs in the checkpoint
  that changes the behavior they describe.
- An iteration closes only when every criterion has evidence, no blocker remains,
  required gates are green on the final code commit, required migration coverage
  and operational regression pass, and every skip is explicitly accepted.
- Closing an iteration does not automatically close a roadmap milestone or
  release. Mark those complete only after their Definition of Done, operational
  regression, documentation synchronization, and explicit user approval.
- Before opening a new iteration, retire or clearly demote superseded drafts and
  trackers so exactly one execution tracker remains authoritative.
