# Architecture And Concepts

Diagrams 1-3 and 6 describe the delivered lab profile and complement [Components And Architecture](../docs/Components.md), [Lab Lifecycle](../docs/Lifecycle.md) and [Tests And Results](../docs/Tests.md). A-dev is the validated agent inference path; the additional projects are shown with their documented configuration, not as additional validated inference paths. Diagrams 4-5 illustrate the general architecture and identity boundaries in [Governance](../docs/Governance.md), independently of the lab's validation scope. Relevant figures are embedded beside their explanations in the four Markdown documents and their Word copies; figure numbering within each document follows its reading order.

PNG files are ready to insert into documents. SVG files preserve vector quality when enlarged. Excalidraw files contain editable shapes, labels and arrows and can be opened with a compatible editor, including [Microsoft Excalidraw](https://aka.ms/excalidraw).

## 1. Lab Architecture

The four resource groups separate central model hosting, shared integration resources and two use cases. Each project has dedicated data dependencies; dev/test projects within a case share its agent subnet. Resource-group boundaries are not network boundaries.

[PNG](01-architecture.png) | [SVG](01-architecture.svg) | [Editable Excalidraw](01-architecture.excalidraw)

![Lab resource groups, projects, gateway and data dependencies](01-architecture.png)

## 2. Request And Identity Flow

An approved client can call the gateway directly. Agent inference starts through the A-dev project API and reaches APIM through the configured project connection. APIM validates its caller and authenticates separately to the central model with its own managed identity. The arrows describe the configured service chain; the cited assertions validate the caller response and agent version, not independent telemetry attribution for every hop.

[PNG](02-inference-flow.png) | [SVG](02-inference-flow.svg) | [Editable Excalidraw](02-inference-flow.excalidraw)

![Direct gateway and agent inference with distinct caller, project and gateway identities](02-inference-flow.png)

## 3. Reachability, Identity And Permissions

Private network reachability, gateway authorization and project authorization are separate controls. A valid token does not automatically grant gateway access, and access to A-dev does not grant agent-list access to A-test. Expected denials count as passing assertions only with the required positive controls. The runtime-role check validates the intended assignments, not all effective permissions or data-plane operations.

[PNG](03-access-controls.png) | [SVG](03-access-controls.svg) | [Editable Excalidraw](03-access-controls.excalidraw)

![Private reachability, gateway assertions and project-scoped authorization](03-access-controls.png)

## 4. Governance Architecture

Application teams develop agents in assigned projects and access centrally managed models through an authorized gateway. Project boundaries, runtime identities and data permissions are separate controls. Use separate Foundry resources when network, administration or connection-sharing requirements differ.

[PNG](04-governance.png) | [SVG](04-governance.svg) | [Editable Excalidraw](04-governance.excalidraw)

![Central model governance with use-case projects and scoped runtime authorization](04-governance.png)

## 5. Identity Boundaries

Agent invocation, gateway access, model inference and data access are separate authorization decisions. The identity used on a connection determines which principal needs access at its destination.

[PNG](05-identity-boundaries.png) | [SVG](05-identity-boundaries.svg) | [Editable Excalidraw](05-identity-boundaries.excalidraw)

![Separate caller, runtime and gateway identities and their destination permissions](05-identity-boundaries.png)

## 6. Lab Lifecycle

Deployment stages have explicit review and completion gates. A retained lab supports repeat tests on the existing agent; removal follows a separate approval and guarded teardown workflow.

[PNG](06-lifecycle.png) | [SVG](06-lifecycle.svg) | [Editable Excalidraw](06-lifecycle.excalidraw)

![Preparation, deployment, verification, retained operation and separately approved teardown](06-lifecycle.png)
