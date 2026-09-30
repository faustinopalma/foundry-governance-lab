# Microsoft Foundry Governance Lab

A governance standard and deployable reference lab for platform engineers and application teams adopting Microsoft Foundry. The goal is to centralize access to approved models while giving teams project-scoped access to their agents and data dependencies.

## Repository Contents

| Document | Contents |
| --- | --- |
| [Governance](docs/Governance.md) | Requirements for model access, identity, networking, data protection and production releases. |
| [Components And Architecture](docs/Components.md) | Resource responsibilities, request flows and authorization boundaries. |
| [Lab Lifecycle](docs/Lifecycle.md) | Prerequisites, staged deployment, repeat testing and guarded teardown. |
| [Tests And Results](docs/Tests.md) | Q01-Q11 assertions, reference results and validation limits. |
| [Diagram Files](diagrams/README.md) | PNG, SVG and editable Excalidraw downloads for the figures embedded in the documents. |

Implementation: `infra/` contains Bicep templates and the gateway policy; `scripts/` contains operational commands; `tests/` contains offline safety and structural checks.

## Run The Lab

Start with [preparation and prerequisites](docs/Lifecycle.md#preparation). For an existing environment, use [repeat tests](docs/Lifecycle.md#repeat-quick-tests) or the separately approved [teardown procedure](docs/Lifecycle.md#teardown).

## GitHub Copilot

Open the repository root in VS Code and use Copilot Agent mode. The included [workspace instructions](.github/copilot-instructions.md) and [lab skill](.github/skills/foundry-governance-lab/SKILL.md) support architecture questions, deployment, status checks, testing and teardown. Invoke `/foundry-governance-lab` followed by your request, for example:

```text
/foundry-governance-lab Run the local package checks without calling Azure.
```

Keep `.github/` when copying the repository. An Azure MCP server is optional; the scripts enforce execution safeguards, and Copilot tool approvals still apply.

## Word Downloads

[Governance](word/Governance.docx) | [Components And Architecture](word/Components.docx) | [Lab Lifecycle](word/Lifecycle.docx) | [Tests And Results](word/Tests.docx)
