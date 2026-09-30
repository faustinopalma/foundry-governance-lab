# Governance Lab Tests

**Reference result: 11 of 11 assertions passed.** Q01-Q10 execute on the [private runner](Components.md#34-private-test-runner); Q11 reads Azure management APIs from the operator's computer. Names and identities refer to the [delivered configuration](Components.md). Use the [repeat-test procedure](Lifecycle.md#repeat-quick-tests) to run the suite in a new or retained environment.

![Figure 1. Positive controls and expected denials establish the specific boundaries exercised by the eleven assertions.](../diagrams/03-access-controls.png)

## Assertions And Results

### Q01: Private Name Resolution

**Assertion.** Every address returned by the runner for the gateway and case-A service names is private.

**Observed result.** Both names resolved exclusively to private addresses. **PASS.**

### Q02: Authorized Gateway Inference

**Assertion.** An approved client's cognitive-services token and a valid chat request produce HTTP 200, a completed assistant message and the exact text `OK`.

**Observed result.** HTTP 200 and the completed `OK` response. **PASS.**

### Q03: Authentication Required

**Assertion.** The same valid request without a bearer token produces HTTP 401 while Q02 passes.

**Observed result.** HTTP 401. **PASS.**

### Q04: Caller Allowlist Enforced

**Assertion.** The dev-a identity, which is outside the gateway caller allowlist, receives HTTP 403 with `CallerNotAllowed` when using a cognitive-services token; Q02 must pass.

**Observed result.** HTTP 403 with `CallerNotAllowed`. **PASS.**

### Q05: Token Audience Enforced

**Assertion.** A token with audience `https://ai.azure.com` produces HTTP 401 on the gateway route; Q02 must pass.

**Observed result.** HTTP 401. **PASS.**

### Q06: Deployment Route Restricted

**Assertion.** A request for an unconfigured deployment route produces HTTP 404 with the same approved client used by Q02.

**Observed result.** HTTP 404. **PASS.**

### Q07: Developer Access To Own Project

**Assertion.** dev-a lists A-dev agents and receives HTTP 200 with a valid agent-list response.

**Observed result.** HTTP 200 with the expected list schema. **PASS.**

### Q08: Sibling Project Access Denied

**Assertion.** The same identity and token used by Q07 receive a typed authorization denial, HTTP 403, when listing A-test agents; Q07 must pass.

**Observed result.** The expected authorization denial on A-test. **PASS.**

### Q09: Owned Agent Version Preserved

**Assertion.** Reading the agent returns HTTP 200, the expected ownership marker and definition, and latest version `1`. The repeat-test workflow performs no agent creation, update or deletion.

**Observed result.** The expected existing agent and version were verified. **PASS.**

### Q10: Agent Inference Completes

**Assertion.** After Q09 passes, a Foundry Responses API request explicitly referencing agent version `1` returns HTTP 200 and a completed, validated assistant response. The request disables storage, streaming, background execution and truncation and sets a bounded output budget.

**Observed result.** The referenced agent completed inference successfully. **PASS.**

### Q11: Runtime Grants Match Their Intended Scope

**Assertion.** A-test's runtime role deployment is Succeeded and returns exactly three assignments to its project managed identity: Blob Data Contributor on the blobstore container, Blob Data Owner on the agent container and Cosmos DB Built-in Data Contributor on `enterprise_memory`. Each assignment's ID, principal, role definition and scope match its deployment record.

**Observed result.** All three assignments matched. **PASS.**

## Interpretation

Acceptance requires exactly Q01-Q11, each with PASS. Missing, duplicate or nonpassing assertions fail acceptance. Inspect the private report identified in the command output to distinguish an unexpected response from an unavailable prerequisite; neither counts as a pass.

An expected denial establishes the tested authorization boundary only when its permitted control succeeds. A timeout or network failure cannot substitute for the required service response.

## Coverage Limits

| Area | Evidence not established by this suite |
| --- | --- |
| Gateway app roles | The [production app-role pattern](Governance.md#33-production-app-role-authorization) is neither implemented nor tested. Q04 exercises the lab's object-ID allowlist. |
| Usage limits | Rate and quota threshold enforcement has not been exercised. The [quota-by-key reference](https://learn.microsoft.com/azure/api-management/quota-by-key-policy) is inconsistent about v2 tier applicability; configured presence is not enforcement evidence. |
| Runtime networks | Q01 and dependency probes originate on the runner. Cross-case agent traffic and direct agent-to-model network denials require tests from the relevant agent subnets. |
| Project permissions | Q07-Q08 cover A-dev/A-test agent listing. Other operations and A/B authorization remain untested; an A/B check could compare the same permitted and denied operation without activating inference on B. |
| Data access | Q11 checks assignment configuration. A-test data-plane reads and writes, inherited effective permissions and a populated retrieval application have not been validated. |
| Other actors and workloads | consumer-a, dev-b, publisher-a and publisher-b are not exercised. Only A-dev has a validated agent inference path; no hosted-agent container is tested. |
| Telemetry and retention | Internal request hops are not independently traced or attributed. Application traces are not established by provisioning monitoring resources; request storage settings and workspace retention do not audit every service-managed store. |
| Production operation | Availability, disaster recovery, load capacity and application content safety require separate qualification against the [operational acceptance requirements](Governance.md#7-operational-acceptance). |
