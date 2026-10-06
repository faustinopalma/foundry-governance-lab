# Governance Principles

Application teams need freedom to build agents without taking over shared models or gaining access to another application's data. Governance defines that freedom, its boundaries and who is accountable for the resulting service.

## Start With Principles

| Principle | What it means |
| --- | --- |
| Centrally managed models | The platform team owns the approved catalog, deployments, access, capacity and model lifecycle. Application teams choose from that catalog. |
| Application-team autonomy | Teams develop and manage agents within their assigned environments without administering shared models or infrastructure. |
| Separation according to risk | Production and non-production have distinct boundaries. Sharing depends on compatible data, administrators, networking and tolerance for mutual impact. |
| Service accountability | Every use case has an owner for quality, application security, consumption and continuity, even when Foundry manages execution. |

Product limitations are constraints on an implementation, not permanent governance principles. Adopt supported capabilities, record material exceptions and revisit them when support and evidence change.

## Place Projects Within Deliberate Boundaries

A **Foundry resource** contains **Foundry projects**. A project organizes agents, connections and application assets; it is not an independent network perimeter. Resource-level administration, inherited permissions and shared connections can affect several projects.

Choose boundaries for the actual capabilities in use: some Foundry APIs require resource-level permissions rather than project-level access. A project boundary cannot supply isolation that the selected API does not support.

Non-production experimentation can share a Foundry resource when its data and access requirements are compatible. Development and test may share resource-level networking and administration. Production belongs in resources separate from non-production; a dedicated resource is the starting point for a new production service.

Production services may share a resource when administrators, network and data requirements are compatible and the impact of shared capacity or failure is acceptable. Apply the same reasoning to registries, monitoring and data stores. Every shared component still needs an owner for operation, capacity and cost.

The lab represents these concerns with separate case A and case B resources and dev/test projects. It does not implement production environments or independent dev/test network perimeters. See [the lab architecture](architecture.md) for its concrete boundaries.

## Govern Model Access Through Integration

Centralization is an ownership model, not a requirement for a single physical model resource. Approved models can be distributed across resources for environment separation, processing geography, capacity or continuity. Any approved case-local deployment remains platform-managed.

**Integration** is the ordinary model-access path. It exposes an agreed service contract: available models and operations, authentication, authorization, usage limits, error behavior and attribution. APIM implements this role in the lab; an existing enterprise integration service can fill it when the full path is supported and qualified.

![Central model governance and application-team boundaries.](../diagrams/04-governance.png)

The figure groups responsibilities by team, not by physical resource. Production uses separate resources from non-production; the arrows show the ordinary governed route, not an approved-exception topology.

Applications invoke their agent endpoint, while applications needing only inference may call an authorized Integration route directly. A connection makes a model discoverable; it does not copy the deployment, authorize the caller or guarantee protocol and tool compatibility.

Where a capability cannot use Integration, a native model route requires explicit platform approval and equivalent identity, data-location, monitoring and usage controls. Application teams must not introduce alternate backends independently. **The lab deliberately tests the stricter gateway-only design:** it provides no native bypass exception or case-local model fallback.

The Integration owner controls routing and attributes usage to an authenticated application or agreed group. Shared project identities do not necessarily distinguish individual agents. Do not trust arbitrary caller-supplied headers for authorization or cost allocation.

## Separate Development, Invocation And Administration

Use Microsoft Entra ID for people and workloads. Organize human access by responsibility and environment; prefer managed or federated identities for services and pipelines. Any necessary secret needs protected storage, rotation and an owner.

A role defines allowed operations; its assignment scope defines where they apply. Management-plane permissions and data-plane permissions are different. Inherited grants are additive, so a narrow project assignment cannot remove broader access.

| Responsibility | Access boundary |
| --- | --- |
| Platform administration | Manage model resources, projects and shared configuration; development and access-administration permissions are considered separately. |
| Application development | Develop and test in the assigned non-production project, with parent-resource read access where needed for discovery. |
| Release pipeline | Only the deployment operations needed in the target environment, without general administration. |
| Application caller | Invoke the selected agent or model route, without agent-development permissions. |
| Agent runtime | Access only its required models, tools and data as the actual runtime or connection identity. |

Foundry User at project scope and Reader on the parent are the development baseline used by the lab. Foundry Agent Consumer applies to supported agent endpoints; other application endpoint contracts can require different invocation permissions. Confirm current role definitions and the actual endpoint before granting access rather than using a broader role to make a request succeed.

![Separate identities authorize agent invocation, model inference and data access.](../diagrams/05-identity-boundaries.png)

The caller's permission to invoke an agent does not automatically authorize access to underlying information. Applications using a shared service identity remain responsible for user, conversation and document ownership. A conversation identifier alone is not proof of access.

Gateway authorization and model-service authorization are also separate. An app-role design can authorize service callers through a registered gateway API and signed role claims; APIM then obtains its own backend token. Validate that the selected Foundry connection supports that audience and token contract. The lab's explicit caller allowlist is not evidence that this production integration has been qualified.

## Choose Execution Independently Of Governance

Use a prompt agent when instructions, approved models and supported managed tools express the required behavior. Use a hosted agent for custom code on the Foundry runtime. An application-managed runtime is another option when execution control or integrations require it, with additional responsibility for endpoints, scaling and operations. A framework choice does not by itself determine hosting or the model-access route.

For container-based hosting, separate image build, publication, platform pull and runtime access. Scan artifacts for vulnerabilities and secrets and release an identifiable immutable image. Observe which identity pulls the image and which identity calls models, tools and data; do not copy permissions between them by assumption.

Applications receive a stable agent interface with authentication and input, output and session contracts. They should not depend on the physical placement of the model backend.

## Protect The Whole Data Path

Define permitted data, users, processing locations, retention and deletion before activation. Include prompts, files, conversation history, tool results and telemetry. Resource location alone does not establish processing geography; the deployment type and service conditions matter.

Managed conversation history does not automatically provide workflow recovery or a complete audit record. Identify what belongs in service-managed state and what needs an application-owned store, including user ownership and deletion across both.

Network controls cover the entire path: callers, gateway, models, runtime, data and operational dependencies. Choose private connectivity or explicitly justified authenticated public access according to service requirements. The lab uses a private baseline. DNS and routing make a destination reachable; service authorization determines what the caller may do there.

Constrain tool destinations, operations and accessible data in services and code. Prompt instructions are not an access-control mechanism. Test prompt-injection and tool-misuse defenses, and require confirmation or proportional safeguards for consequential actions.

## Release And Operate A Service, Not Just An Agent

Select the production agent version explicitly and identify its model, tools, code and configuration. A pinned agent version does not freeze its dependencies. Model catalog or routing changes require checks against affected applications and a usable rollback path.

The service owner sets representative acceptance criteria and approves production readiness. Correlatable telemetry supports diagnosis and consumption attribution without unnecessary payload capture. Never log secrets; any content capture needs a defined purpose, access policy and retention.

Usage limits and monetary budgets are different controls. Budget alerts do not stop spending. Define and test what happens when technical limits are reached, who handles failures and who can suspend service or revoke access. Recovery and alternate backends must preserve the same authorization and data constraints.

## Prove The Boundaries

Before adoption, demonstrate permitted flows and their corresponding restrictions:

- An approved application reaches its agent and model route; an unauthorized caller or alternate route is refused.
- A developer manages its own project; sibling and cross-case operations outside its role are denied.
- A runtime reaches its permitted data and tools; unauthorized data, sessions and tool operations remain inaccessible.
- A release can be activated and rolled back; changing its dependencies does not silently bypass approval.
- Telemetry and alerts reach their owners; restricted readers cannot access another application's protected records.

These are governance acceptance conditions, not a performance score. The [lab test plan](test-plan.md) translates relevant conditions into checks; [executed results](Tests.md) distinguish observed controls from unproven requirements.

At retirement, notify callers, revoke access, handle data and logs according to retention rules, and remove only resources no longer needed. Shared services must remain available to their other users.

## References

- [Foundry resource and project planning](https://learn.microsoft.com/azure/foundry/concepts/planning) and [roles and scopes](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry).
- [Connected models](https://learn.microsoft.com/azure/foundry/agents/how-to/connected-models) and [AI gateway integration](https://learn.microsoft.com/azure/foundry/agents/how-to/ai-gateway).
- [Hosted agents](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents), [their identities and permissions](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions) and [Agent Framework hosting](https://learn.microsoft.com/agent-framework/hosting/).
- [Private networking](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks), [model data protection](https://learn.microsoft.com/azure/foundry/responsible-ai/openai/data-privacy) and [runtime state](https://learn.microsoft.com/azure/foundry/agents/concepts/runtime-components).
- [Agent versions and endpoints](https://learn.microsoft.com/azure/foundry/agents/how-to/configure-agent) and [budget behavior](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets).
