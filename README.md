# Microsoft Foundry Governance Lab

A governance standard and deployable reference lab for platform engineers and application teams adopting Microsoft Foundry. The goal is to centralize access to approved models while giving teams project-scoped access to their agents and data dependencies.

## Repository Contents

| Document | Contents |
| --- | --- |
| [Governance](docs/Governance.md) | Requirements for model access, identity, networking, data protection and production releases. |
| [Components And Architecture](docs/Components.md) | Resource responsibilities, request flows and authorization boundaries. |
| [Lab Lifecycle](docs/Lifecycle.md) | Prerequisites, staged deployment, repeat testing and guarded teardown. |
| [Independent Lifecycle](docs/independent-lifecycle.md) | New core infrastructure only, later targeted tests and separately approved teardown; current lifecycle and topology diagrams. |
| [Tests And Results](docs/Tests.md) | Q01-Q11 assertions, reference results and validation limits. |
| [Diagram Files](diagrams/README.md) | PNG, SVG and editable Excalidraw downloads for the figures embedded in the documents. |

Implementation: `infra/` contains Bicep templates and the gateway policy; `scripts/` contains operational commands; `tests/` contains offline safety and structural checks.

## Run The Lab

For a new lab, start with the [independent lifecycle](docs/independent-lifecycle.md) and `scripts/Invoke-Lab.ps1`: `Create`, `Status`, explicit `Test` groups, and separately approved `Teardown`. Creation runs no lab tests and grants no future removal consent. Resources remain active between requests.

The new command provisions the default four-group **core** topology, not the expanded Standard agent-service dependencies or hosted workloads. The [advanced retained workflow](docs/Lifecycle.md) and its Q01-Q11 reference results remain separate. Do not migrate existing minimal/expanded state to the core coordinator.

## GitHub Copilot

Open the repository root in VS Code and use Copilot Agent mode. The included [workspace instructions](.github/copilot-instructions.md) and [lab skill](.github/skills/foundry-governance-lab/SKILL.md) support architecture questions, deployment, status checks, testing and teardown. Invoke `/foundry-governance-lab` followed by your request, for example:

```text
/foundry-governance-lab Run the local package checks without calling Azure.
```

Keep `.github/` when copying the repository. An Azure MCP server is optional; the scripts enforce execution safeguards, and Copilot tool approvals still apply.

## Word Downloads

These downloads describe the earlier expanded reference workflow. For the current independent creation/test/teardown contract, use the Markdown guide above.

[Governance](word/Governance.docx) | [Components And Architecture](word/Components.docx) | [Lab Lifecycle](word/Lifecycle.docx) | [Tests And Results](word/Tests.docx)
