# Extending The Lab To Agent Workloads

The core separates model hosting, application projects and gateway control. Standard expansion supplies the services an agent runtime needs; hosted expansion adds a container supply chain and custom execution. These are additional scopes, not automatic consequences of creating the core.

This document explains the dependencies and intended governance checks. It is not a queue of pending operations or approval to resume a historical deployment. Use recorded state to establish what exists and which coordinator owns it.

## Standard Agent Dependencies

| Component | Purpose | Governance boundary |
| --- | --- | --- |
| Storage | Files and agent-service data. | Private access and data roles on the project's discovered workspace containers. |
| Search | Retrieval and vector-store services. | Project-specific service and data permissions; retrieval still needs application/user authorization. |
| Cosmos DB | Agent-service conversation state. | Private connectivity and native data-plane access scoped to the required database. |
| Dependency connections | Bind the project to its services. | Correct scope, service identity and authentication; visibility is not authorization. |
| Capability hosts | Configure the agent service and its dependencies. | Preserve existing immutable or service-managed hosts; do not recreate them to bypass a failed gate. |
| Gateway connection | Bind the agent's model access to APIM. | Verify caller identity, token audience, model/protocol support and gateway authorization together. |

Use dedicated dependency services per project where required by this design. Dev/test still share their case's delegated agent subnet; dedicated services and roles do not create dev/test network isolation.

Resource creation permissions and runtime data permissions serve different purposes. Discover service-created containers after the project host is ready, then review exact identities and scopes before assigning runtime access. Do not replace precise grants with account-wide permissions to avoid discovery.

## Existing Environments

Expansion must preserve the original ownership set, account and project identities, creation-time network configuration, existing hosts and working agent. A smaller historical profile is not converted by changing its flag or rerunning the main template with a larger topology.

The foundation coordinator adds missing case/project resources and records expansion separately. Later coordinators bind their changes to that evidence and the original state. A verified prerequisite must be reused, not submitted again. New source does not retroactively update old evidence hashes.

| Workflow | Owning script |
| --- | --- |
| Existing case A Standard dependencies and hosts | [Invoke-StandardStage.ps1](../scripts/Invoke-StandardStage.ps1) |
| Additional case and projects | [Invoke-ExpansionFoundation.ps1](../scripts/Invoke-ExpansionFoundation.ps1) |
| Additional project's private dependencies | [Invoke-ExpansionStandard.ps1](../scripts/Invoke-ExpansionStandard.ps1) |
| Bounded dependency observation | [Invoke-ExpansionWatchdog.ps1](../scripts/Invoke-ExpansionWatchdog.ps1) |
| Expanded private endpoint verification | [Test-ExpansionPrivate.ps1](../scripts/Test-ExpansionPrivate.ps1) |
| Expanded Cosmos Direct rule | [Invoke-ExpansionCosmosNetwork.ps1](../scripts/Invoke-ExpansionCosmosNetwork.ps1) |
| Resource-host reuse and project hosts | [Invoke-ExpansionHosts.ps1](../scripts/Invoke-ExpansionHosts.ps1) |
| Scoped runtime grants | [Invoke-ExpansionRuntimeAccess.ps1](../scripts/Invoke-ExpansionRuntimeAccess.ps1) |

Review the selected script's parameters and current state before execution. These coordinators are not interchangeable with the independent core entry point.

## Dependency Order

For the original Standard workflow, complete private dependencies, verify them from the runner, verify resource-host reuse, create the project host, discover and grant scoped data access, apply the required Cosmos network rule, then refresh private evidence before agent invocation. The [runbook](runbook.md#standard-expansion) provides commands and gates.

The additional-project expansion has its own sequence: foundation, project dependencies, private checks and Cosmos networking precede its host and runtime-access coordinators. Follow those recorded prerequisites rather than applying the original workflow's order to a different coordinator.

Every mutating stage requires reviewed scope and unchanged inputs. `Preview` validates proposed changes; `Deploy` submits once; `Status` verifies actual completion and postconditions. A terminal root is necessary but not sufficient. Stop on missing ownership, unexpected modifications, active nested work or changed identities.

The watchdog bounds local execution and performs read-only diagnosis. A local deadline does not cancel Azure provisioning or authorize replay. An observed successful root does not replace full `Status` verification. Preserve pending intent and receipts until reconciliation succeeds.

## Hosted Agents

A hosted agent adds a separate delivery chain: build an image, publish it to the permitted registry repository, let the platform pull that exact artifact, start the runtime, then authorize its calls to APIM and data services.

Publishing and image-pull roles must not be confused with runtime permissions. Observe the actual platform pull identity and hosted runtime identity. A successful publisher push, runner pull or clean Linux dependency installation does not establish managed-platform startup.

Keep registries private and repository access scoped. The selected hosting path must support the project's private registry and account network configuration. Hosted requirements may include ACR ARM-audience authentication, which differs from the historical core setting. That enables a token audience, not public access or registry admin credentials; it still requires explicit design review before changing the setting.

If documentation or the selected API path leaves identity or endpoint privacy ambiguous, qualify the actual contract. Do not grant both candidate identities broad access or open a public endpoint as an implicit workaround. Unsupported behavior remains blocked.

## Required Flow Tests

| Permitted flow | Corresponding restriction |
| --- | --- |
| Original agent still invokes through its configured gateway route. | Expansion does not replace its identity, host, network or policy bindings. |
| Each developer and consumer performs its permitted project operations. | Sibling-project and cross-case operations outside its role are denied. |
| Agent/runtime reaches APIM with the expected token. | Unapproved callers, audiences, models and direct central inference are refused. |
| Platform starts the approved image using its actual pull identity. | A controlled fixture without repository permission cannot start. |
| Runtime reaches its own dependencies. | Restricted cross-case and central-model network paths are blocked from that runtime. |
| Authorized operators correlate a request and inspect its telemetry. | Other-case readers cannot access protected logs; synthetic payloads and tokens are not unexpectedly captured. |
| A temporary grant works before revocation and after restoration. | Fresh requests are denied after revocation within the observed propagation behavior. |

Use [the test plan](test-plan.md) for evidence criteria. Destructive fixtures and permission revocation require explicit selection; they do not authorize deleting the retained application or lab.

## Preserve The Environment And Evidence

Inherited policies remain part of the environment. A failed automatic diagnostic or alert deployment may be classified only with exact target, failed-operation and absence evidence; naming alone is insufficient. Classification neither turns the failure into success nor permits editing external policy, monitoring or provider registrations.

When a post-submission read-only validator needs correction, archive and verify its original reviewed source first. Only the coordinator's documented revision path may record that difference. Keep original review hashes, templates, parameters and outputs unchanged; a missing archive or unrelated source change remains a blocker.

Historical foundation, dependency, host and runner checks did not establish hosted execution or complete governance. Consult [recorded results](lab-summary.md), not old progress notes, and obtain a separate request for further deployment, tests or removal.
