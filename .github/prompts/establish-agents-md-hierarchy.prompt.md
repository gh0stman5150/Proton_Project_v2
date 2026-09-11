Act as a Senior Platform Engineer responsible for AI-agent tooling
consistency across a multi-repository workspace.

Your objective is to audit this workspace and establish a correct
`AGENTS.md` hierarchy: workspace guidance plus repository guidance where distinct,
each containing only what belongs at its level, with nothing duplicated
between them.

## Ground rules

- Follow the active agent's instruction-resolution rules. Do not assume
  every agent discards parent instructions when it finds a nearer file.
  Keep scope explicit and avoid contradictory guidance at different levels.
- Establish workspace boundaries from the supplied workspace roots and any
  workspace configuration. If the workspace opens only one repository, its
  root `AGENTS.md` can serve both roles. Do not turn a system parent directory
  into a workspace or create an extra file solely to force two levels.
- Inventory checked-out upstream dependencies separately from maintained
  repositories. Do not add project-owned instructions inside a dependency
  merely because it has Git metadata; document its role in the owning repo.
- Target length: keep every individual `AGENTS.md` file (workspace and
  per-repo) under roughly 300 lines. If a repo-level file would need to
  exceed that to stay useful, split further with nested `AGENTS.md` files
  inside that repo's subprojects rather than growing the single file.
- Do not invent conventions the workspace doesn't already have. Infer rules
  from what the repositories actually do (build tooling, test runners,
  directory structure, existing lint/CI config, existing instruction files
  such as `.github/copilot-instructions.md`, `CONTRIBUTING.md`, or
  per-repo `AGENTS.md` files already present). If something is ambiguous or
  contradicted across repos, flag it instead of guessing.

## Step 1: Inventory the workspace

1. List every repository in the workspace and, for each, note:
   - primary language(s)/runtime(s) and package manager,
   - build, lint, and test commands,
   - whether it already has an `AGENTS.md`, `.github/copilot-instructions.md`,
     `CLAUDE.md`, `.cursorrules`, or equivalent agent-instruction file,
   - any safety-critical or destructive operations it performs (data
     mutation, filesystem changes, deployments, external API calls) that an
     agent should be cautious around.
2. Identify what, if anything, is genuinely shared across *all* repositories
   in the workspace — not "true of most repos" but true of the workspace as
   a whole. Typical candidates: a shared monorepo build system, a shared
   commit-message or branch-naming convention, a shared review/PR process,
   how the repos relate to or depend on one another, workspace-wide
   prohibited practices (e.g., "never commit secrets," "never push directly
   to main across any repo here").
3. Identify what is repository-specific and must not be promoted to the
   workspace level: language conventions, per-repo test commands, per-repo
   safety invariants, per-repo directory maps, per-repo prohibited
   practices that don't apply elsewhere.

If a rule could plausibly belong in either place, put it at the repo level.
Over-scoping a repo-specific rule to the workspace file causes it to be
silently applied (and potentially wrong or irrelevant) in every other repo
that doesn't override it.

## Step 2: Write or update the workspace-level `AGENTS.md`

Place this at the root of the workspace (the folder that contains the
repositories, not inside any one of them) when there is a distinct declared
workspace root. For a single repository opened as the workspace, update its
root file instead and explain why no separate parent file is needed.
Keep separate workspace guidance short. It should answer,
for an agent that hasn't opened any individual repo yet:

- What is this workspace, and how do the repositories in it relate to each
  other (independent projects vs. a coordinated system)?
- Where is each repository, in one line, with a pointer to that repo's own
  `AGENTS.md` for specifics.
- Any workspace-wide conventions identified in Step 1.2 — commit/PR
  conventions, secrets handling, cross-repo dependency rules.
- Any workspace-wide prohibited practices.
- Nothing else. Do not restate any repo's build/test commands, language
  conventions, or repo-specific safety invariants here — those belong in
  that repo's own file, and duplicating them risks the two copies drifting
  out of sync.

## Step 3: Write or update each repository's `AGENTS.md`

For each repository identified in Step 1 that doesn't already have an
adequate one:

- Cover whichever of the following sections are actually relevant to that
  repo — don't force a section that doesn't apply, and don't invent content
  to fill one:
  - **Purpose**: what the repo does, in a few sentences.
  - **Repository layout**: a directory map with one line per major path
    explaining its responsibility.
  - **Non-negotiable invariants**: behavior that must never change without
    explicit review — especially anything destructive, security-sensitive,
    or safety-critical (data mutation, deployments, auth, payments,
    filesystem or infra changes). If the repo has no such behavior, omit
    this section rather than padding it.
  - **Coding conventions**: patterns actually observed in the codebase
    (naming, error handling, structuring), not generic style-guide
    boilerplate the repo doesn't follow.
  - **Change workflow**: the expected sequence for making a change (tests
    to update, docs to update, review steps) if the repo has one worth
    stating.
  - **Validation commands**: exact, copy-pasteable build/lint/test commands
    with real flags — not "run the tests."
  - **Prohibited practices**: things an agent would otherwise plausibly do
    that are wrong for this specific repo.
  - **Known gaps / follow-ups**: open issues worth flagging to whoever
    touches this code next, if any exist.
- Do not repeat anything already stated in the workspace-level file.
  Reference it if useful ("see the workspace `AGENTS.md` for commit
  conventions") rather than copying it.
- If the repo already has a `.github/copilot-instructions.md` or similar,
  either consolidate it into `AGENTS.md` (preferred, since `AGENTS.md` is
  the broader-adopted convention) or keep both in sync explicitly — state
  in each file which one is authoritative if they must coexist, so they
  don't silently diverge.
- If the repo is itself large enough that one file would exceed ~300 lines
  or would mix unrelated subproject conventions (e.g., a repo with separate
  frontend/backend/infra directories with different toolchains), add nested
  `AGENTS.md` files inside those subdirectories instead of inflating the
  repo-root file.

## Step 4: Verify there is no duplication or contradiction

1. Diff the content categories across the workspace file and every
   repo-level file. Flag any rule that appears in more than one file.
2. For each flagged duplicate, either delete it from the more general file
   (keeping it at the more specific level) or, if it must exist at both
   levels for a specific reason, state that reason explicitly next to it so
   a future editor doesn't "fix" the duplication by deleting the wrong copy.
3. Confirm no repo-level file contradicts the workspace-level file. If one
   repo genuinely needs to override a workspace-wide rule, say so explicitly
   in that repo's file rather than leaving an unexplained conflict for the
   agent to guess about.
4. Confirm every repository referenced in the workspace-level file actually
   has the `AGENTS.md` it points to, and that the path is correct.

## Deliverables

1. The new or updated workspace-level `AGENTS.md`, or the documented
   single-repository decision to use the repository root file for both roles.
2. The new or updated `AGENTS.md` for each repository that needed one.
3. A short summary listing:
   - which repositories got a new file vs. an updated one,
   - what content was moved from a repo-level file up to the workspace
     level (or the reverse), and why,
   - any existing instruction files (`.github/copilot-instructions.md`,
     etc.) that were consolidated or left in place with a stated
     authority rule,
   - any workspace-wide convention you inferred but could not confirm
     (call these out explicitly rather than asserting them as fact),
   - any repository you could not fully audit and why.
