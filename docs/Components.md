# Foundry Governance Lab: Components And Architecture

Logical names such as A-dev and models identify component roles; deployment-specific identifiers remain in private run state. The [governance standard](Governance.md) defines the requirements behind this configuration.

## 1. Resource Groups And Responsibilities

| Resource group | Main components | Responsibility |
| --- | --- | --- |
| models | Central Foundry resource, model deployment and private endpoint | Supply the shared inference backend. |
| integration | API Management (APIM), shared network and DNS, test VM, test identities and shared monitoring | Govern model access and provide private connectivity and test execution. |
| case-a | Foundry resource A, dev/test projects, dedicated project dependencies and case monitoring | Host application projects for use case A. |
| case-b | Foundry resource B, dev/test projects, dedicated project dependencies and case monitoring | Host application projects for use case B. |

The groups share one virtual network owned by integration. Private endpoints belong to their service's resource group but attach to subnets in that shared network. Each use case contains both development and test environments.

![Figure 1. Resource ownership and configured service relationships.](../diagrams/01-architecture.png)

## 2. Central Model Hosting

The models group contains a Foundry resource of type AIServices and the lab-chat deployment of gpt-4.1-mini, using Global Standard. Its processing-location implications are covered by the [approved model contract](Governance.md#31-approved-model-contract).

Public data-plane access and local key authentication are disabled. The private endpoint exposes the `account` subresource. Foundry uses several DNS domains, including cognitiveservices, openai and services.ai; their private DNS zones do not represent three different private endpoint types. Storage, Search and Cosmos DB have their own service-specific endpoints.

APIM's managed identity receives Cognitive Services OpenAI User on the central resource. The lab does not grant direct central-model inference access to project identities or the synthetic client.

## 3. Integration Services

### 3.1 API Management

APIM uses Standard v2 with one capacity unit, a system-assigned managed identity and a disabled developer portal. In its final configuration, public gateway access is disabled.

An inbound private endpoint serves gateway clients. Outbound VNet integration uses snet-apim to reach the central model's private endpoint.

The lab-inference API exposes one HTTPS operation: POST /openai/deployments/lab-chat/chat/completions. It is not a general proxy to all model deployments.

| Control | Configuration and meaning |
| --- | --- |
| Authentication | Validate an Entra bearer token for the lab tenant and audience `https://cognitiveservices.azure.com`. Missing or invalid tokens are rejected. |
| Caller authorization | Accept only the object IDs of the A-dev project identity and the synthetic client identity. A valid token from another caller receives 403 CallerNotAllowed. |
| Subscription keys | No APIM subscription key is required. Entra authentication is still mandatory. |
| Request structure | Require application/json, a body of at most 16,384 bytes and 1-16 messages, each with a string role. This is structural validation, not prompt-content safety screening. |
| Generation parameters | Set max_tokens to 256 and n to 1; remove model and max_completion_tokens. Default stream to false when absent, without prohibiting an explicit streaming request. |
| Routing | Fix the backend to the central account and deployment lab-chat. Override the API version and remove unmatched query parameters. An unconfigured deployment route is rejected. |
| Backend credentials | Remove any api-key header and authenticate with APIM's own managed identity. The caller's identity is not forwarded as the model credential. |
| Usage controls | Configure 20 calls per minute and a 200-call quota per 24-hour period, using shared counters rather than a separate allowance for each caller. |

Production authorization is specified in [Governance, section 3.3](Governance.md#33-production-app-role-authorization); the [coverage limits](Tests.md#coverage-limits) distinguish these settings from verified enforcement. No semantic cache, multi-model routing, failover backend or additional APIM content-safety policy is configured.

### 3.2 Request And Identity Flow

The direct gateway test obtains a token as client and calls APIM. APIM validates that caller, applies its policy, obtains a separate token as the gateway identity and invokes lab-chat. The response returns through APIM to the client.

The agent path starts with dev-a calling the A-dev Foundry project API using a token for `https://ai.azure.com`. Foundry executes the existing agent. Its governed-models project connection calls APIM using the project managed identity and the cognitive-services audience. APIM then calls the same central model with its own identity and returns the result to the agent service, which completes the caller's response.

![Figure 2. Configured token audiences and caller identities along the two request paths.](../diagrams/02-inference-flow.png)

### 3.3 Shared Network And DNS

One VNet contains eight subnets. No peering, VPN gateway or Bastion resource is deployed in this profile.

| Subnet | Role |
| --- | --- |
| snet-agent-a | Delegated agent network for both A-dev and A-test. |
| snet-agent-b | Separate delegated agent network for both B-dev and B-test. |
| snet-apim | Outbound VNet integration for API Management. |
| snet-runner | Private test VM and its network interface. |
| snet-models-pe | Private endpoint for the central Foundry account. |
| snet-case-a-pe | Private endpoints for case A and its data dependencies. |
| snet-case-b-pe | Private endpoints for case B and its data dependencies. |
| snet-integration-pe | Inbound APIM and Azure Monitor private endpoints. |

Network security groups are assigned to the two agent subnets, APIM, the runner and the endpoint subnets. Their configured rules deny cross-case agent traffic and direct agent access to the central-model subnet, while permitting the intended gateway and same-case dependency paths. Additional rules allow Cosmos DB direct-mode TCP traffic from each case's agent subnet only to the recorded private endpoint addresses. The runner subnet denies inbound connections.

Private DNS zones and VNet links cover Foundry, APIM, Blob Storage, Search, Cosmos DB and Azure Monitor. An ACR private DNS zone is reserved by the broader template.

The NAT gateway and its public IP provide outbound connectivity for the runner and agent subnets.

### 3.4 Private Test Runner

The runner is an Ubuntu VM with PowerShell, a private NIC and a managed OS disk. It has no public IP and uses Trusted Launch, Secure Boot and vTPM. Its attached [test identities](#5-test-identities) supply the tokens used by the checks; the operator's Azure credentials remain on the operator's computer. The model and agent run in managed Azure services independently of this VM.

Azure VM Run Command executes scripts through the VM Agent with elevated operating-system privileges. The operator needs management-plane RBAC authorization, without a VPN or inbound SSH connection to the VM or a route to the private service endpoints. The VM must be running, its agent healthy and its required Azure outbound connectivity available. Test requests originate inside the lab VNet and remain subject to destination network and authorization controls.

### 3.5 Monitoring

Integration and each case have a Log Analytics workspace and an Application Insights resource. Central-model metrics use the integration workspace; the case resources use their respective workspaces. The configured APIM and Foundry diagnostic settings export metrics, not prompt or response payloads.

An Azure Monitor Private Link Scope in integration links these monitoring resources, with private-only ingestion and query modes. Its private endpoint and DNS configuration provide the monitoring network path. Workspace retention and ingestion controls are defined in infrastructure.

## 4. Case A And Case B

Each case's Foundry resource has project management enabled, a private endpoint and agent network injection into its delegated subnet. Resources and projects have separate system-assigned identities.

| Component per case | Purpose |
| --- | --- |
| Two projects: dev and test | Separate application definitions, connections and project authorization. |
| Two Storage accounts | One per project for files and agent-service data, with private Blob access. |
| Two Search services | One per project, connected as the vector-store dependency. |
| Two Cosmos DB accounts | One per project, connected as the agent-service conversation-state dependency. |
| Project connections | Bind each project to its own Storage, Search and Cosmos resources using Entra authentication. |
| Capability hosts | Account- and project-level service configuration for Agents and their dependencies. They are not customer-managed VMs. |
| Private endpoints and NICs | Connect Foundry and data services to the appropriate case endpoint subnet. |
| Monitoring and role assignments | Provide case-level monitoring resources and scoped permissions for developers and service identities. |

The infrastructure disables public access and local-key authentication on the case Foundry and data resources. Each project receives the provisioning and Search permissions defined by its dependency template. Additional configuration differs by project:

| Project | Agent, model connection and additional runtime access |
| --- | --- |
| A-dev | Agent, governed-models connection to APIM and scoped Blob/Cosmos runtime grants. |
| A-test | Three scoped Blob/Cosmos runtime grants; no model connection. |
| B-dev and B-test | No model connection or additional scoped Blob/Cosmos runtime grants. |

No container registries or customer-hosted agent containers are deployed.

## 5. Test Identities

The integration group contains seven user-assigned managed identities attached to the runner as synthetic test actors.

| Test identity | Intended role in this profile |
| --- | --- |
| dev-a | Case A developer: Reader on the parent Foundry resource and project access on A-dev. |
| consumer-a | Separate consumer role assigned on A-dev. |
| dev-b | Case B developer: Reader on the parent Foundry resource and project access on B-dev. |
| publisher-a and publisher-b | Reserved for container-publishing scenarios. No registry is deployed, so these actors have no active registry-publishing function here. |
| client | Explicitly allowlisted direct APIM caller, without the lab's direct central-model inference grant. |
| denied | Negative-test actor with no intended application authorization from the lab. Its name does not implement an explicit deny policy. |

Administrators and code able to request tokens on the shared VM can use all its attached identities. This test arrangement provides no isolation between untrusted workloads.

## 6. Configuration Sources

APIM's service configuration, network integration, private endpoint, API, operation, JSON schema, policy and central-model RBAC assignment are declared in Bicep. The policy XML is loaded by the template. The customer procedure does not require completing APIM configuration manually in the portal.

Before activation, the PowerShell scripts read the existing APIM identity and pass its principal ID to Bicep, which creates the role assignment. [Lab Lifecycle](Lifecycle.md) defines the deployment sequence and completion gates.

## References

- [Diagram files and editable sources](../diagrams/README.md).
- [Foundry private networking](https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks) and [managed identities](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview).
- [APIM outbound VNet integration](https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound).
- [Azure VM Run Command](https://learn.microsoft.com/azure/virtual-machines/linux/run-command).
