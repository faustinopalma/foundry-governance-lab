# Tested Governance Flows

The expanded reference experiment exercised the permitted flows and denials below. Its assertions passed, but these are historical results, not certification of a newly deployed lab. The [core test workflow](independent-lifecycle.md#later-targeted-tests) is separate from this expanded suite.

The private runner executes the request checks. The runtime-grant check reads Azure management APIs from the operator's computer. These origins matter: runner connectivity does not prove the same network behavior from an agent runtime.

## Flows At A Glance

| Flow that must work | Related flow that must be blocked | Observed boundary |
| --- | --- | --- |
| An approved client invokes the model through APIM. | The same request without authentication. | Authentication required. |
| An approved caller uses a token for the gateway's expected audience. | An unapproved caller or a token for another audience. | Caller and audience authorization. |
| The approved model route resolves. | A caller selects an unconfigured model route. | The caller cannot choose an arbitrary backend through that API. |
| A developer lists agents in its own project. | The same identity lists a sibling project's agents. | Project-scoped authorization for the tested operation. |

The experiment also verified the existing agent's identity and version, completed agent inference and checked scoped runtime grants. It did not demonstrate every possible bypass, data access or hosted workload.

## Assertions And Results

The identifiers below link the explanations to the private test report. They are evidence references, not a performance score.

### Q01: Private Name Resolution

**Assertion.** Gateway and case-A service names resolve only to private addresses from the runner.

**Observed result.** Both destinations resolved exclusively to private addresses. **PASS.**

### Q02: Authorized Gateway Inference

**Assertion.** An approved client sends a valid chat request with a cognitive-services token and receives a completed assistant response matching the expected content.

**Observed result.** Successful inference with the expected `OK` response. **PASS.**

### Q03: Authentication Required

**Assertion.** The same request without a bearer token is rejected while the authorized control succeeds.

**Observed result.** Authentication rejection, HTTP `401`. **PASS.**

### Q04: Caller Allowlist Enforced

**Assertion.** An identity outside the gateway allowlist is rejected despite supplying a token for the expected audience; the approved caller succeeds.

**Observed result.** HTTP `403` with the policy's `CallerNotAllowed` denial. **PASS.**

### Q05: Token Audience Enforced

**Assertion.** A token intended for the Foundry agent service is rejected by the gateway route while the correctly targeted token succeeds.

**Observed result.** Authentication rejection, HTTP `401`. **PASS.**

### Q06: Deployment Route Restricted

**Assertion.** The approved client cannot select an unconfigured deployment route.

**Observed result.** HTTP `404` for the unconfigured route. **PASS.**

### Q07: Developer Access To Own Project

**Assertion.** The case-A developer can list agents in A-dev and receives a valid list response.

**Observed result.** Successful own-project listing with the expected schema. **PASS.**

### Q08: Sibling Project Access Denied

**Assertion.** The same identity and token cannot list A-test agents while own-project listing succeeds.

**Observed result.** Typed authorization denial on the sibling project, HTTP `403`. **PASS.**

### Q09: Owned Agent Version Preserved

**Assertion.** The existing agent matches the expected ownership marker, definition and recorded version. Repeat tests do not create, update or delete it.

**Observed result.** The expected existing agent and version were verified. **PASS.**

### Q10: Agent Inference Completes

**Assertion.** After ownership verification, a Foundry Responses API request explicitly referencing that agent version returns a completed, validated assistant response. Storage, streaming, background execution and truncation are disabled for the request, with a bounded output budget.

**Observed result.** The referenced agent completed inference successfully. **PASS.**

### Q11: Runtime Grants Match Their Intended Scope

**Assertion.** A-test's runtime-role deployment has succeeded. Its assignments match the recorded identity and exact roles/scopes: Blob Data Contributor on the blobstore container, Blob Data Owner on the agent container and Cosmos DB Built-in Data Contributor on the memory database. No extra assignment is accepted.

**Observed result.** The assignments matched their expected IDs, principal, roles and scopes. **PASS.** This is configuration evidence, not a runtime data-access test.

## Interpretation

The expanded quick suite requires exactly the defined assertions, each with PASS. Missing, duplicate or nonpassing assertions fail acceptance. A timeout, unavailable prerequisite or unrelated error is not an expected denial. Evaluate each rejection alongside its successful control.

For an existing matching expanded state, [Invoke-QuickLab.ps1](../scripts/Invoke-QuickLab.ps1) runs these checks with `-StatePath` and `-RunLive`. It requires explicit approval for live requests and possible inference charges, preserves the existing agent and does not provision missing prerequisites. Do not apply it as the default test command for a new core deployment; use the [independent lifecycle](independent-lifecycle.md).

## Coverage Limits

| Area | What remains unproven |
| --- | --- |
| Production authorization | Gateway app roles are not implemented or tested; caller denial exercises the lab allowlist. |
| Usage controls | Presence of rate/quota policies does not prove threshold enforcement or spending control. |
| Runtime networks | Cross-case traffic and direct-model denial need checks from the relevant runtime identities and network paths. |
| Project permissions | Own/sibling listing does not qualify every operation or cross-case authorization. |
| Data access | Runtime grants do not prove reads, writes, retrieval or the absence of inherited permissions. |
| Other workloads | Only A-dev has a validated agent inference path in this experiment; hosted-agent execution was not tested. |
| Telemetry and retention | Internal hops were not independently correlated. Request storage flags do not audit all service-managed stores. |
| Production operation | Availability, recovery, content safety and application-level user/session ownership require separate acceptance. |

See the [governance principles](Governance.md) for the broader requirements, [earlier experiments](lab-summary.md) for their distinct findings and the [test plan](test-plan.md) for additional scenarios that are not qualified by this suite.
