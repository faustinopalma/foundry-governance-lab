# Microsoft Foundry Governance Lab

A governance standard and deployable reference lab for platform engineers and application teams adopting Microsoft Foundry. The goal is to centralize access to approved models while giving teams project-scoped access to their agents and data dependencies.

The lab connects Foundry agents to a central model through a private Azure API Management (APIM) gateway. Separate Foundry resources host the models and use-case projects; managed identities authorize each request hop.

## Repository Contents

| Document | Contents |
| --- | --- |
| [Governance](docs/Governance.md) | Requirements for model access, identity, networking, data protection and production releases. |
| [Components And Architecture](docs/Components.md) | Resource responsibilities, request flows and authorization boundaries. |
| [Lab Lifecycle](docs/Lifecycle.md) | Prerequisites, staged deployment, repeat testing and guarded teardown. |
| [Tests And Results](docs/Tests.md) | Q01-Q11 assertions, reference results and validation limits. |
| [Diagrams](diagrams/README.md) | Architecture and concept diagrams in PNG, SVG and editable Excalidraw formats. |

Implementation: `infra/` contains Bicep templates and the gateway policy; `scripts/` contains operational commands; `tests/` contains offline safety and structural checks.

The eleven assertions passed in the reference lab. Its gateway uses an illustrative identity allowlist; the standard specifies Entra app roles for production. Each new environment needs its own acceptance run, and production qualification extends beyond these tests.

## Run The Lab

Use PowerShell 7 on Windows with Azure CLI, Bicep and OpenSSH. Follow the [lifecycle procedure](docs/Lifecycle.md#preparation) to prepare an authenticated Azure context and confirm the target, permissions, capacity and deployment approval.

Keep credentials, run state and generated evidence outside the repository. Create each environment with a fresh lab identifier. Provisioning and live tests incur Azure charges; resources remain deployed until separately approved teardown.

## GitHub Copilot

Open the repository root in VS Code and use Copilot Agent mode. The included [workspace instructions](.github/copilot-instructions.md) and [lab skill](.github/skills/foundry-governance-lab/SKILL.md) support architecture questions, deployment, status checks, testing and teardown. Invoke `/foundry-governance-lab` followed by your request, for example:

```text
/foundry-governance-lab Run the local package checks without calling Azure.
```

Keep `.github/` when copying the repository. An Azure MCP server is optional; the scripts enforce execution safeguards, and Copilot tool approvals still apply.

## Word Downloads

[Governance](word/Governance.docx) | [Components And Architecture](word/Components.docx) | [Lab Lifecycle](word/Lifecycle.docx) | [Tests And Results](word/Tests.docx)
