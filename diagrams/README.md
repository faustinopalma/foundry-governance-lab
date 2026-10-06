# Diagram Files

PNG files are ready to insert into documents. SVG files preserve vector quality when enlarged. Excalidraw files contain editable shapes, labels and arrows and can be opened with a compatible editor, including [Microsoft Excalidraw](https://aka.ms/excalidraw).

| Figure | Explanation | Files |
| --- | --- | --- |
| Earlier expanded architecture | [Current core and expansion boundaries](../docs/architecture.md#add-agent-dependencies-explicitly) | [PNG](01-architecture.png), [SVG](01-architecture.svg), [Excalidraw](01-architecture.excalidraw) |
| Expanded request and identity flow | [Identity boundaries](../docs/architecture.md#distinguish-caller-runtime-and-backend-identities) | [PNG](02-inference-flow.png), [SVG](02-inference-flow.svg), [Excalidraw](02-inference-flow.excalidraw) |
| Access-control assertions | [Tests and results](../docs/Tests.md) | [PNG](03-access-controls.png), [SVG](03-access-controls.svg), [Excalidraw](03-access-controls.excalidraw) |
| Governance architecture | [Model ownership and Integration](../docs/Governance.md#govern-model-access-through-integration) | [PNG](04-governance.png), [SVG](04-governance.svg), [Excalidraw](04-governance.excalidraw) |
| Identity boundaries | [Separate authorization decisions](../docs/Governance.md#separate-development-invocation-and-administration) | [PNG](05-identity-boundaries.png), [SVG](05-identity-boundaries.svg), [Excalidraw](05-identity-boundaries.excalidraw) |
| Earlier expanded lifecycle | [Existing-state procedure](../docs/Lifecycle.md) | [PNG](06-lifecycle.png), [SVG](06-lifecycle.svg), [Excalidraw](06-lifecycle.excalidraw) |

The current core diagrams live with the [architecture](../docs/architecture.md) and [independent lifecycle](../docs/independent-lifecycle.md). The earlier expanded figures describe that profile, not the core coordinator or current Azure inventory. The governance figure groups responsibilities by team; it does not place production and non-production in the same resource.

The text-source exporter does not include binary or editable diagram assets. Use the Git repository for the complete illustrated documentation.
