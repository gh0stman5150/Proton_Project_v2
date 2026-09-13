# Compatibility Pointer

The authoritative project instructions are in `../AGENTS.md`. Follow that file for repository location, safety boundaries, fleet invariants, validation, deployment, documentation, and archive-handling requirements.

Read the [project guide](../AGENTS.md) before making changes. Use these owning
sections instead of duplicating their rules here:

- Repository objectives and structure: [Purpose And Instruction Scope](../AGENTS.md#purpose-and-instruction-scope) and [Repository Layout And Tooling](../AGENTS.md#repository-layout-and-tooling)
- Bash, systemd, Docker Compose, helper reuse, error handling, and logging: [Contributor And Documentation Standards](../AGENTS.md#contributor-and-documentation-standards)
- Security requirements and prohibited practices: [Safety Boundaries](../AGENTS.md#safety-boundaries), [qBittorrent Fleet Contract](../AGENTS.md#qbittorrent-fleet-contract), and [Wedge Detection](../AGENTS.md#wedge-detection)
- Repository-specific runtime guidance: [Installer And Runtime Invariants](../AGENTS.md#installer-and-runtime-invariants) and [Host Storage And Boot Invariants](../AGENTS.md#host-storage-and-boot-invariants)
- Testing requirements: [Validation](../AGENTS.md#validation)
- Change, pull request, and deployment expectations: [Change Workflow](../AGENTS.md#change-workflow) and [Contributor And Documentation Standards](../AGENTS.md#contributor-and-documentation-standards)
- Documentation requirements: [Documentation Map](../AGENTS.md#documentation-map) and [Contributor And Documentation Standards](../AGENTS.md#contributor-and-documentation-standards)

Use the [README](../README.md) for setup and the [documentation index](../docs/README.md) for the relevant architecture or runbook. Keep shared rules in the project guide instead of duplicating them here. Workflow-specific prompts apply only to their task and remain subject to that guide.
