# Foundry Governance And Reference Lab

- [Governance](docs/Governance.md): general technical standard, illustrated with the governance architecture and separate authorization decisions along a request.
- [Components And Architecture](docs/Components.md): component responsibilities, private networking and identities, with architecture, request-flow and access-control diagrams.
- [Lab Lifecycle](docs/Lifecycle.md): prerequisites, creation commands and guarded teardown, with lifecycle and architecture diagrams.
- [Tests And Results](docs/Tests.md): eleven assertions, their motivations, expected behavior and passing reference results, with a map of the exercised controls.
- [diagrams/README.md](diagrams/README.md): general governance architecture and lab diagrams, with PNG, SVG and editable Excalidraw files.
- `infra/`: Bicep templates and gateway policy.
- `scripts/`: deployment, repeat-test and teardown commands, including their helper modules.
- `tests/`: local safety and structural checks used by the supplied commands.

Run commands from this folder with PowerShell 7 on Windows. Keep private run state, credentials and generated evidence outside this folder. Use a fresh lab identifier to create an environment; never replay creation against the active reference lab. The reference assertions passed; a new environment must pass its own checks. Teardown is a separate destructive action, not part of testing.

The governance standard defines general requirements. The lab documents describe the reference implementation and the controls actually tested; they do not establish compliance with every requirement in the standard. The package contains no subscription configuration, credentials or raw customer evidence. Runtime metadata and required API/model versions remain in the executable code.

## Use With GitHub Copilot

Open this folder itself in VS Code, with GitHub Copilot enabled, and use Agent mode in Chat. Keep the included `.github` directory when copying or distributing the package. The [workspace instructions](.github/copilot-instructions.md) route relevant requests to the [Foundry governance lab skill](.github/skills/foundry-governance-lab/SKILL.md). No personal skills or access to the original author's workspace are required.

Use natural-language requests or invoke the skill explicitly:

- `/foundry-governance-lab Explain how the application agents reach the central model and which identities authorize each hop.`
- `/foundry-governance-lab Check the prerequisites and spin up a new lab. Ask for my Azure target and approvals before creating resources.`
- `/foundry-governance-lab Run the local package checks without calling Azure.`
- `/foundry-governance-lab Run Q01-Q11 against my existing lab. Ask for the private state path and leave the lab running.`
- `/foundry-governance-lab Inspect the current deployment stage without submitting it again.`
- `/foundry-governance-lab Plan teardown of my lab and show the resources that would be removed. Do not delete anything.`
- `/foundry-governance-lab Tear down my lab through the guarded customer workflow. Confirm the target and request approval before each deletion step.`

For execution, the workstation needs the prerequisites in [docs/Lifecycle.md](docs/Lifecycle.md), an authenticated Azure context, sufficient permissions and approved capacity. Copilot requests missing target details and approvals; it does not create credentials or grant itself access. Initialization requires explicit deployment and eventual-removal consent, while actual teardown requires a separate request and approval. Live tests can incur inference charges and do not stop the lab afterward.

If the slash command is absent, confirm that VS Code opened the package root and that the skill appears under Chat: Open Customizations, Skills. Check organizational restrictions on customizations and tool execution. An Azure MCP server is optional. The skill supplies instructions, not a deterministic security boundary; the packaged scripts enforce their own checks, and Copilot's tool approval controls still apply.

## Word Downloads

Formatted Word copies remain available separately: [Governance](Governance.docx), [Components And Architecture](Components.docx), [Lab Lifecycle](Lifecycle.docx) and [Tests And Results](Tests.docx).
