# Earlier Experiments: Findings And Limits

The lab tests a simple proposition: authorized applications should reach their models and projects, while unauthorized callers and alternate routes should be blocked.

The results below come from historical experiments, not tests of a newly created environment. The original core and the later Standard-expanded experiment used different connection configurations. Their results must not be combined into a claim that every flow passed in the same deployment.

For the expanded reference suite and its paired controls, start with [tested governance flows](Tests.md). This page provides the additional findings and limitations of the earlier experiments.

## Flows That Worked

| Tested flow | Observed result | Governance meaning |
| --- | --- | --- |
| Approved client to APIM to central model | A valid model response was returned. | The intended gateway route worked for the approved client. |
| Developer to its own project | Agent listing and, in the original experiment, disposable-agent creation, modification and deletion succeeded. | Project access supports the developer's permitted work. |
| Agent to the model through the configured project connection | The Standard-expanded experiment completed an invocation of the retained agent version. | That agent and connection configuration supported inference. Independent agent/gateway/backend correlation was not established. |
| Publisher to its own registry | Image upload, manifest retrieval and configuration-blob integrity checks succeeded in the original experiment. | The publisher could use its authorized repository. This does not prove platform image pulls or hosted startup. |
| Runner to private service endpoints | Private DNS and connectivity checks succeeded for the tested endpoints. | Those services were reachable from the runner. Agent-runtime connectivity is a separate claim. |

## Flows That Were Blocked

| Tested flow | Observed result | Governance meaning |
| --- | --- | --- |
| Anonymous client to APIM | Authentication rejected, paired with a successful authorized call. | The gateway required authentication on the tested route. |
| Valid but unapproved identity to APIM | Explicit caller rejection. | A valid token alone did not authorize model access. |
| Wrong-audience token to APIM | Authentication rejected. | Tokens issued for another API were not accepted on the tested route. |
| Client to an unconfigured model route | Route rejected while the approved route worked. | The gateway did not expose arbitrary deployment routes. |
| Developer to a sibling project | The same identity could list its own project's agents but received a typed authorization denial on the sibling project. | The tested project-list boundary held; this does not cover every mutation or escalation path. |
| Consumer attempts to create, modify or delete an agent | Explicit authorization denials in the original experiment. | The tested consumer identity lacked developer mutation permissions. Successful consumer invocation was not established there. |
| Runner test identities directly to the central model | Explicit permission denials, paired with working gateway-to-backend inference in the original experiment. | Those identities could not bypass the gateway through direct inference. Actual project and hosted-runtime identities were not tested by substitution. |
| External client to private APIM and registries | Explicit network-access denials in the original experiment. | The observed public paths were refused. Ambiguous Foundry responses did not establish the equivalent network claim. |

## What Remains Unproven

Cross-registry denials were inconclusive. Actual hosted image pulls, hosted runtime identity, runtime cross-case network isolation, complete inherited-permission isolation, end-to-end telemetry attribution, service-side retention and clean rebuild qualification remain unproven. A successful deployment or prompt response does not fill these gaps.

The first agent configuration could not resolve its account-level model connection. A later project-scoped connection with Standard dependencies supported invocation. This demonstrates why connection existence in ARM is not runtime evidence; it does not isolate which individual change caused the successful result.

## Reproduce The Checks

For a new core environment, use [the independent lifecycle](independent-lifecycle.md) to select test groups explicitly. It separates deployment, testing and teardown; it does not run the historical expanded smoke workflow automatically.

The [test plan](test-plan.md) describes required positive controls, expected denials and evidence limits. The [original execution report](execution-report.md) and [expanded execution report](retained-execution-report.md) keep the experiments distinct. Raw requests, source bindings and execution metadata belong in private evidence, not this overview.
