# Advanced Lab Operations

For a new core lab, use the [independent lifecycle](independent-lifecycle.md). It separates deployment, selected tests and teardown. This guide explains the additional workflows for an existing minimal or expanded profile; it is not a request to execute them or a record of current Azure state.

## Select The Existing Run

Use PowerShell on Windows and the run's original protected state, authenticated CLI configuration and reviewed source. Do not initialize over an existing run, switch its lifecycle marker or use a historical report as inventory. Keep credentials, generated artifacts and evidence outside the source tree.

```powershell
$statePath = Read-Host 'Absolute path to the existing protected state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'Original state file required'
}
```

Confirm the subscription, tenant, ownership, phase and pending operation before selecting a workflow. Source and executable artifacts must remain unchanged during an active operation. Creation approval does not authorize tests, prerequisite changes or eventual removal.

## Understand The Stage Contract

| Action | Purpose | Gate |
| --- | --- | --- |
| Preview | Compile and validate the scoped change, including what-if. | Review exact targets, identities, private settings and unchanged inputs. |
| Deploy | Submit the reviewed change. | Required approval, matching source and parameters, valid preview and no conflicting active deployment. |
| Status | Observe and verify the submitted change. | Terminal service state and all required postconditions, not merely command success. |

Execute commands separately. While work is pending, observe it instead of replaying Preview or Deploy. Failed, canceled or uncertain submissions retain their evidence and require reconciliation; do not clear pending markers. Resource-host reuse is a verification-only exception that completes during Deploy and has no deployment to observe with Status.

Provider registration, policy compatibility, service availability and capacity are prerequisites. Missing prerequisites are blockers, not permission to register services, alter inherited policy, widen roles or enable public access.

## Standard Expansion

This workflow applies to the existing Standard-capable minimal profile, not automatically to independent core state. It requires completed activation, the original private-access gate and no active main or nested deployment. The [expansion design](full-expansion-plan.md) explains why the services and permissions are separate.

| Stage | Owning operation | Required result |
| --- | --- | --- |
| Private dependencies | `Invoke-StandardStage.ps1 -Stage dependencies` | Private Storage, Search and Cosmos configuration, connections and provisioning roles verified. |
| Pre-host connectivity | `Test-StandardPrivate.ps1` | Exact owned endpoint mappings and runner DNS/TLS checks pass. |
| Resource host | `Invoke-StandardStage.ps1 -Stage account` | Exact existing host verified and reused without recreation. |
| Project host | `Invoke-StandardStage.ps1 -Stage project` | Expected dependency bindings and terminal host state. |
| Scoped access | `Invoke-StandardStage.ps1 -Stage access` | Discovered workspace containers and database receive only the intended runtime grants. |
| Cosmos Direct path | `Invoke-StandardCosmosNetwork.ps1` | Exact endpoint-address rule verified; other rules preserved. |
| Final connectivity | `Test-StandardPrivate.ps1` | Fresh evidence bound to all completed stages and outputs. |
| Agent invocation | `Invoke-LabRunner.ps1 -Action MinimalPrompt` | Ownership and expected version verified before the request; actual response classified. |
| Evidence export | `Export-MinimalPromptEvidence.ps1` | Complete export bound to the same attempt and source/configuration. |

For a stage not yet submitted, use the owning coordinator's Preview, review it, then Deploy and Status. This dependency-stage example shows the pattern; each line is a separate gated action, not an unattended batch:

```powershell
./scripts/Invoke-StandardStage.ps1 -StatePath $statePath -Stage dependencies -Action Preview
./scripts/Invoke-StandardStage.ps1 -StatePath $statePath -Stage dependencies -Action Deploy
./scripts/Invoke-StandardStage.ps1 -StatePath $statePath -Stage dependencies -Action Status
```

Run the private verifier both before host configuration and after all stages and network changes:

```powershell
./scripts/Test-StandardPrivate.ps1 -StatePath $statePath
```

Do not set success flags manually or reuse an older receipt after configuration changes. Runner connectivity does not prove the agent's runtime path.

The resource-host Preview must select verified reuse. An absent, changed or nonterminal host blocks the workflow; do not create a replacement. For a new project host, unexpected prior existence likewise requires reconciliation. Discover the actual workspace containers before the access stage; avoid guessed names or account-wide grants.

The Cosmos rule targets verified endpoint addresses, not an entire subnet. Its coordinator is [Invoke-StandardCosmosNetwork.ps1](../scripts/Invoke-StandardCosmosNetwork.ps1). Fresh activation already includes the corrected backend streaming policy. [Update-LabGatewayPolicy.ps1](../scripts/Update-LabGatewayPolicy.ps1) is a separately reviewed repair path for an eligible older policy, not a routine redeployment step.

## Agent Tests And Evidence

An existing agent's expected version comes from its ownership-verified record. A new agent requires explicit fixture approval; the minimal harness can create on typed absence, so it must not be treated as a universally read-only retest.

```powershell
$expectedAgentVersion = Read-Host 'Expected ownership-verified agent version'
./scripts/Invoke-LabRunner.ps1 -StatePath $statePath -Action MinimalPrompt -ExpectedAgentVersion $expectedAgentVersion
```

The harness checks ownership and version before invocation. A mismatch must stop the test rather than update or recreate the agent. For repeat checks of the existing expanded reference environment, use its non-creating quick workflow only with explicit approval:

```powershell
./scripts/Invoke-QuickLab.ps1 -StatePath $statePath -RunLive
```

Quick checks preserve the existing agent and do not deploy missing prerequisites. Their targeted runtime-grant readback does not replace an extended coordinator's completion receipt. See [tested flows](lab-summary.md) for interpretation.

For MinimalPrompt evidence, select the summary through its matching attempt pointer and received report, not by newest filename. Export that exact attempt:

```powershell
$summaryPath = Read-Host 'Absolute path to the nonce-associated received summary'
./scripts/Export-MinimalPromptEvidence.ps1 -StatePath $statePath -SummaryPath $summaryPath
```

Require completion, file-integrity and attempt/request/version bindings. Preserve earlier exports and record failed attempts too. Do not truncate missing evidence, rewrite hashes or infer service-side retention from request flags. Evidence export grants no removal permission.

## Additional Projects And Hosted Workloads

Use the dedicated coordinators listed in the [expansion design](full-expansion-plan.md#existing-environments). Additional-project workflows have their own host/network prerequisites and separate receipts. Do not replay the main template or change the original profile flag to expand ownership.

Build and publisher checks do not establish platform image pull, hosted startup or runtime identity. Keep those tests distinct, and stop on unsupported identity or private-network contracts instead of introducing fallback access.

## Retained Lab Inspection

Inspect only the ownership-verified resources selected by the original state. Review projects, connection scopes, effective roles, private endpoints, DNS, gateway policy and pending deployment evidence. Do not assume a fixed project count from an old report.

Management-plane visibility does not imply private data-plane reachability. A portal data explorer failing without the private route does not prove service failure. Do not list keys, copy credentials, broaden access or run new inference merely to inspect configuration.

## Evidence And Teardown

Removal is a separate request for the exact lab. New independent core state uses [Invoke-Lab.ps1](../scripts/Invoke-Lab.ps1) and its fresh approval/identifier checks; successful tests are not a removal prerequisite.

Historical minimal and expanded states retain their recorded coordinators and evidence contracts. Do not force them through the independent entry point or reuse a different run's inventory. Legacy minimal removal through [Remove-LabRun.ps1](../scripts/Remove-LabRun.ps1) can require its acceptance receipt, complete invocation export and unchanged bindings. Those technical gates do not grant deletion consent; an unavailable gate requires a separately reviewed supported removal workflow, not fabricated evidence.

Before any destructive step, verify ownership, captured inventory integrity, terminal root/nested deployments and the exact next target. Remove monitoring links before their targets, project capability hosts before projects where applicable, and projects before accounts. Keep integration last. Never directly delete service-managed account hosts or force deletion past remaining service-association links.

Observe submitted deletion to verified absence before advancing. Preserve private evidence after removal. Resource absence does not mean purge, immediate name reuse, complete noninterference or a final bill; those are separate claims.

## Local Checks And Publication

The local suite checks templates, script behavior and safety fixtures without live lab tests:

```powershell
./tests/Test-Local.ps1
```

Bicep may need approved access to restore pinned public modules. Local success does not establish deployed behavior.

[Export-PublicSource.ps1](../scripts/Export-PublicSource.ps1) exports the [text-source allowlist](../public-files.json) to a new external destination, checks confidentiality patterns and verifies copy integrity. It does not publish Git or back up private evidence. Diagram and Word assets are separate from that text-source exporter and need their own publication review. Never publish caches, keys, run state, generated parameters or raw evidence.
