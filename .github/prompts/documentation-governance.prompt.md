Act as a Senior Documentation Architect, GitHub Repository Maintainer, and Documentation Governance Reviewer.

Your objective is to evaluate this entire repository and ensure that all repository documentation is accurate, current, comprehensive, maintainable, and aligned with industry best practices for enterprise automation projects.

Repository Context:
- This is an internal enterprise automation repository.
- Determine technologies from the repository; this project is Bash with systemd and Docker Compose, not PowerShell.
- Documentation quality may vary and may contain outdated, incomplete, inconsistent, or legacy information.
- The repository may have evolved over time and documentation may not accurately reflect the current implementation.

Source of Truth:
Treat the repository implementation as the authoritative source of truth, including:
- PowerShell scripts (*.ps1, *.psm1, *.psd1)
- Bash scripts (*.sh)
- Tests
- GitHub Actions workflows
- Configuration files
- Folder structure
- Existing documentation files
- Dependency definitions
- Build and deployment artifacts

Use code and tests to establish implemented behavior, while preserving the safety and authority requirements in AGENTS.md. If implementation conflicts with a safety requirement, record a defect rather than silently rewriting the requirement. Preserve historical incident evidence and distinguish its observation period from current runtime verification.

Documentation Governance Tasks:

1. README.md
   - Review and completely modernize README.md if needed.
   - Ensure it clearly explains:
     - Repository purpose
     - Key capabilities
     - Architecture or workflow overview
     - Requirements and prerequisites
     - Installation
     - Configuration
     - Usage examples
     - Authentication requirements
     - Security considerations
     - Troubleshooting guidance
     - Testing procedures
     - Contribution guidance
     - Support and ownership information
   - Remove obsolete, redundant, speculative, or inaccurate content.

2. AGENTS.md
   - Create or update AGENTS.md.
   - Document:
     - Repository purpose
     - Repository structure
     - Key automation workflows
     - Coding standards inferred from the codebase
     - Testing expectations
     - Security expectations
     - Change management expectations
     - Documentation maintenance standards
     - Operational considerations
     - Common development patterns found in the repository
     - Guidance for human and AI contributors

3. copilot-instructions.md
   - Create or update copilot-instructions.md.
   - Keep it a compatibility pointer when AGENTS.md already owns the guidance; add links to the relevant sections instead of duplicating rules.
   - Include:
     - Repository objectives
     - Preferred coding patterns
     - PowerShell and Bash conventions observed in the repository
     - Error handling expectations
     - Logging standards
     - Security requirements
     - Documentation requirements
     - Testing requirements
     - Pull request expectations
     - Prohibited practices
     - Repository-specific implementation guidance

4. Documentation Validation
   - Correct these in current operational guidance; retain clearly labeled historical evidence and supported compatibility behavior:
     - References to deprecated workflows
     - References to previous versions
     - Legacy implementation details
     - Obsolete migration guidance
     - Incorrect configuration instructions
     - Stale examples
     - Duplicate documentation
   - Ensure all documentation reflects the repository's current state.

5. Consistency Review
   - Ensure terminology is consistent across all documentation.
   - Normalize naming conventions.
   - Align examples with actual repository behavior.
   - Ensure documentation is professional, concise, and actionable.

Deliverables:
1. Update or create all required documentation files.
2. Make documentation improvements directly where necessary.
3. Generate a Documentation Review Summary containing:
   - Files modified
   - Major improvements made
   - Outdated content removed
   - Assumptions made
   - Documentation gaps discovered
   - Follow-up recommendations
   - Documentation quality assessment before and after review

Quality Standard:
Produce documentation that would allow:
- A new engineer to understand the repository quickly.
- An operator to safely use and support the automation.
- A maintainer to extend the solution confidently.
- GitHub Copilot to generate repository-aligned code and documentation with minimal ambiguity.

Prioritize accuracy, maintainability, clarity, completeness, and long-term sustainability.
