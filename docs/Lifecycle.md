# Existing Expanded Lab Lifecycle

For a new core lab, use the [independent lifecycle](independent-lifecycle.md): deploy, selected tests and teardown are separate requests. This page is only for an existing matching minimal or expanded state. Do not initialize a new run with this advanced sequence or change a lifecycle marker to make it eligible.

## Preparation

Use the original private state and reviewed package on PowerShell on Windows. Keep authenticated CLI configuration, state and evidence outside the package. Confirm the Azure target, costs and exact requested operations before execution. Live tests need explicit approval even where the advanced workflow requires them as gates.

```powershell
$state = Read-Host 'Absolute path to the existing private state.json'
$compiler = (Get-Command bicep -CommandType Application).Source
```

Review the [stage contract](runbook.md#understand-the-stage-contract) and [private runner](architecture.md#treat-dns-routing-and-authorization-separately). Execute each command separately and inspect its result. After submission, observe the matching Status until terminal service state and postconditions are verified. Do not replay Preview or Deploy while pending, edit source during a run or relax inherited controls to pass a gate.

## Complete The Original Standard Profile

Follow the [Standard sequence](runbook.md#standard-expansion): private dependencies, pre-host connectivity, verified resource-host reuse, project host, scoped access, Cosmos Direct networking and final private checks. Resource-host reuse performs no deployment and has no subsequent Status operation.

Fresh activation includes the final gateway policy. The packaged attestation verifies it without redeployment:

```powershell
./scripts/Update-LabGatewayPolicy.ps1 -StatePath $state -Action Attest
```

Agent acceptance and export are separately authorized steps described in [agent tests and evidence](runbook.md#agent-tests-and-evidence). Require the expected existing agent/version, actual completed inference and complete matching export before expanding this retained profile. A repeat test must not recreate the agent.

## Expand The Retained Profile

The [expansion design](full-expansion-plan.md) explains each dependency and its boundary. Foundation adds the missing case and project resources without replaying the main deployment:

```powershell
./scripts/Invoke-ExpansionFoundation.ps1 -StatePath $state -Action Preview -BicepExecutable $compiler -ApproveFoundationCreation
./scripts/Invoke-ExpansionFoundation.ps1 -StatePath $state -Action Deploy -BicepExecutable $compiler -ApproveFoundationCreation
./scripts/Invoke-ExpansionFoundation.ps1 -StatePath $state -Action Status -BicepExecutable $compiler
```

For each approved additional project, select `a-test`, `b-dev` or `b-test` and complete dependencies and private checks. Complete those checks for all selected projects before their network changes. Each line below is a separate reviewed action, not a batch to run unattended.

```powershell
$project = Read-Host 'Approved project: a-test, b-dev or b-test'
./scripts/Invoke-ExpansionStandard.ps1 -StatePath $state -Project $project -Action Preview -BicepExecutable $compiler -ApproveDependencies
./scripts/Invoke-ExpansionStandard.ps1 -StatePath $state -Project $project -Action Deploy -BicepExecutable $compiler -ApproveDependencies
./scripts/Invoke-ExpansionStandard.ps1 -StatePath $state -Project $project -Action Status -BicepExecutable $compiler
./scripts/Test-ExpansionPrivate.ps1 -StatePath $state -Project $project -BicepExecutable $compiler
```

Then complete the scoped Cosmos network change for each approved project:

```powershell
./scripts/Invoke-ExpansionCosmosNetwork.ps1 -StatePath $state -Project $project -Action Preview -BicepExecutable $compiler -ApproveNetwork
./scripts/Invoke-ExpansionCosmosNetwork.ps1 -StatePath $state -Project $project -Action Deploy -BicepExecutable $compiler -ApproveNetwork
./scripts/Invoke-ExpansionCosmosNetwork.ps1 -StatePath $state -Project $project -Action Status -BicepExecutable $compiler
```

Verify account-host reuse with `a-test` for case A and `b-dev` for case B. The `b-test` project shares the case-B account receipt; do not submit a separate account-host operation for it. Preview must select Reuse, and Deploy must finish that verification without submitting a deployment. There is no account-host Status step.

```powershell
$accountSelector = Read-Host 'Approved account selector: a-test or b-dev'
./scripts/Invoke-ExpansionHosts.ps1 -StatePath $state -Project $accountSelector -Stage account -Action Preview -Compiler $compiler -ApproveHosts
./scripts/Invoke-ExpansionHosts.ps1 -StatePath $state -Project $accountSelector -Stage account -Action Deploy -Compiler $compiler -ApproveHosts
```

After the matching account receipt is complete, create and verify each approved project host:

```powershell
./scripts/Invoke-ExpansionHosts.ps1 -StatePath $state -Project $project -Stage project -Action Preview -Compiler $compiler -ApproveHosts
./scripts/Invoke-ExpansionHosts.ps1 -StatePath $state -Project $project -Stage project -Action Deploy -Compiler $compiler -ApproveHosts
./scripts/Invoke-ExpansionHosts.ps1 -StatePath $state -Project $project -Stage project -Action Status -Compiler $compiler
```

The reference suite verifies additional runtime grants for A-test. It does not qualify the other projects' runtime access by analogy:

```powershell
./scripts/Invoke-ExpansionRuntimeAccess.ps1 -StatePath $state -Project a-test -Action Preview -Compiler $compiler -ApproveRuntimeAccess
./scripts/Invoke-ExpansionRuntimeAccess.ps1 -StatePath $state -Project a-test -Action Deploy -Compiler $compiler -ApproveRuntimeAccess
```

With explicit test approval, [the runtime-grant assertion](Tests.md#q11-runtime-grants-match-their-intended-scope) is the reference workflow's readback criterion for those grants. If still provisioning, retain the submission and observe without redeploying. A passing quick assertion does not manufacture a separate extended-coordinator receipt or establish runtime data-plane access.

## Repeat Quick Tests

For this existing expanded profile, the following explicitly approved test leaves resources deployed and preserves the agent checked by [the ownership assertion](Tests.md#q09-owned-agent-version-preserved):

```powershell
./scripts/Invoke-QuickLab.ps1 -StatePath $state -RunLive
```

Use the [assertions and coverage limits](Tests.md#interpretation) to interpret the private report. A missing prerequisite is a blocker, not permission to start resources, alter roles, create agents or expand the test scope.

## Teardown

Independent core state uses [its own teardown procedure](independent-lifecycle.md#separately-approved-teardown), with fresh approval and no successful-test prerequisite. The customer workflow below supports existing minimal state and its foundation-bound expansion without changing the original state.

Removal is a separate request for the exact lab. Use [Remove-CustomerLab.ps1](../scripts/Remove-CustomerLab.ps1) and a cleanup manifest outside both the package and the original run directory. If that manifest already exists, resume Status rather than Plan.

```powershell
$cleanup = Read-Host 'Absolute path to the separate private cleanup manifest'
./scripts/Remove-CustomerLab.ps1 -StatePath $state -CleanupPath $cleanup -Action Plan
./scripts/Remove-CustomerLab.ps1 -StatePath $state -CleanupPath $cleanup -Action Status
```

Review the captured inventory, exact groups and next target. Plan is not deletion approval. Confirm the lab identifier from the original state, then authorize only the reviewed destructive step:

```powershell
$confirmedLabId = Read-Host 'Exact lab identifier confirmed from the original state'
./scripts/Remove-CustomerLab.ps1 -StatePath $state -CleanupPath $cleanup -Action Step -ConfirmLabId $confirmedLabId -ApproveDestroy
./scripts/Remove-CustomerLab.ps1 -StatePath $state -CleanupPath $cleanup -Action Status
```

Ready means review and authorize the next target; Pending means observe, not resubmit. Continue only within the explicit removal approval until Complete. Each Step rechecks context, ownership, inventory and dependencies and submits at most one destructive operation.

Monitoring links precede their targets, project capability hosts precede projects, and projects precede accounts. Keep integration last, with both agent subnets free of service-association links. Unknown resources, external targets, ownership changes, incomplete inventories and active deployments stop the procedure. Do not delete service-managed account hosts manually or change inherited policies to bypass a blocker.

Complete establishes absence of the owned groups and inventoried ARM resources. Private evidence and soft-deleted service records remain; purge, provider unregistration and final billing are outside this workflow.
