# Standard-Expanded Experiment: Governance Results

This experiment established a completed prompt-agent response through its configured project connection after adding Standard agent-service dependencies. It was a bounded functional result, not full governance qualification. The lab and agent were retained at the recorded checkpoint; this report is not a current resource inventory or a standing operational instruction.

## What Changed From The Core Experiment

The experiment used central model hosting, private APIM and a case A development project. It added private Storage, Search and Cosmos DB dependencies, project connections, capability-host configuration and scoped access. Registries, case B and hosted workloads were outside this checkpoint.

The model connection was project-scoped and used `ProjectManagedIdentity`, the Cognitive Services audience and an `/openai` target. The existing resource-level Agents host was verified and reused without recreation; a project host bound the project's own dependencies.

Provisioning and data permissions were distinct. Storage access targeted discovered workspace containers; Cosmos data access used its native role at the application database. No broad role or local-key fallback was introduced.

## Flows And Evidence

| Tested flow or control | Observation | Meaning |
| --- | --- | --- |
| Runner to private dependencies | Owned endpoint mappings and DNS/TLS checks passed. | The tested runner path was ready, not every agent-runtime data operation. |
| Existing agent invocation | A fresh ownership/version check preceded a completed response from the pinned agent. | The tested version and connection configuration supported inference without recreating the agent. |
| Developer directly to central model | A denial was observed without the required same-target positive control in this attempt. | INCONCLUSIVE; the original experiment's qualified bypass checks cannot be borrowed to complete this one. |
| Exported attempt evidence | Export completion, file integrity and request/version/source bindings were verified. | The retained result belongs to that attempt and configuration, not a later changed deployment. |

## Why The Protocol Details Matter

An earlier invocation reached APIM through a public path and was refused. Runner connectivity had not proved the agent's runtime route. Standard dependencies and subsequent network/protocol corrections preceded success; the experiment did not isolate each change's causal contribution.

Cosmos Direct mode needed a rule to the verified private endpoint addresses beyond the HTTPS probe. The rule did not open the entire endpoint subnet. The gateway also needed to preserve explicit backend streaming, independently of the non-streaming outer agent request. Authentication, caller restrictions and the fixed private backend remained in place.

The request disabled response storage, background execution and truncation. The successful response did not echo the storage flag. Accepting an absent echo according to the response contract does not prove service-side retention behavior.

## What This Does Not Prove

Independent caller/gateway/backend correlation, actual runtime identity, full inherited permissions, connection-write governance, cross-case isolation, telemetry separation, hosted execution and retention remain unqualified. Neither local regression checks nor infrastructure completion supplies those missing results.

A later expansion added projects and dependency sets. Its targeted checks are summarized in [tested flows](lab-summary.md), but they do not turn this earlier case A experiment into qualification of the whole expanded environment. In particular, targeted readback of runtime grants is distinct from completion of the corresponding coordinator receipt and from actual data access.

## Repeat Tests Without Recreating Infrastructure

Existing minimal/expanded runs retain their own state and [advanced procedures](runbook.md). Inspect the recorded phase, pending work, private prerequisite evidence and intended agent version before requesting a new bounded attempt. Preserve preceding evidence and bind each export to its own request; do not select files by recency alone.

Testing does not authorize repair, teardown or a new initialization. New core runs instead use the [independent lifecycle](independent-lifecycle.md), whose creation, testing and removal are separate operations.
