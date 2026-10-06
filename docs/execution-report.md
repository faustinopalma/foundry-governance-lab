# Original Core Experiment: Governance Results

The original experiment verified selected gateway, project, registry and lifecycle boundaries. It did not establish full governance acceptance: no agent completed inference and no hosted workload ran. Its owned resources were removed and its evidence retained privately. This is a historical result, not current Azure inventory.

## Tested Architecture

The deployment separated a central model Foundry resource from case A and case B Foundry resources and their dev/test projects. Private APIM mediated model access. Each case had a private registry; integration supplied private networking, monitoring and a trusted runner with synthetic identities.

APIM had the lab's central-model inference grant. Developers, consumers, publishers and project identities had different scoped roles. Effective inherited access was not fully assessed. Dev/test shared their case's subnet and repository; the shared runner did not isolate its attached identities from each other.

## Permitted And Denied Flows

| Boundary | Permitted control observed | Restricted control observed | Conclusion |
| --- | --- | --- | --- |
| Gateway | Approved client obtained a valid model response. | Anonymous, invalid-token, wrong-audience and unapproved callers were refused. | The tested authentication and caller controls held. |
| Model route and request policy | Valid requests reached the configured model. | Selected alternate-route, malformed-body and oversized-request probes were refused; rate rejection was observed. | Full override coverage, backend non-invocation and quota enforcement remained unqualified. |
| Direct model access | APIM reached the central backend. | Runner test identities received explicit service permission denials with validated token context. | These identities could not invoke the model directly. Actual project/runtime identities were not substituted by runner identities. |
| Project access | Developers listed and managed disposable agents in their own projects. | Cross-case agent lists and consumer agent mutations received explicit denials. | These operation-specific authorization boundaries held. |
| Registry | Each publisher uploaded and retrieved a complete synthetic image with integrity validation. | Cross-case responses were ambiguous. | Publishing worked; complete repository isolation and hosted image pulls were not established. |
| Public network access | Runner private-path checks succeeded. | Public APIM and registry requests returned explicit network denials; Foundry responses were ambiguous. | Only the supported denial claims were qualified. Monitoring and runtime-origin paths remained unproven. |

## Agent Inference Was Blocked

The account-level `governed-models` connections existed in ARM, but developer invocation failed with `Connection governed-models not found`. Consumer invocation also lacked qualifying success or denial evidence. Agent creation and mutation restrictions did not establish that an agent could call the model.

The later [Standard-expanded experiment](retained-execution-report.md) used a different project-scoped connection contract and completed an invocation. That result does not change this experiment's verdict or prove that all other governance requirements passed.

## Acceptance Status

The following preserves the original whole-case verdicts. Case IDs refer to the [test plan](test-plan.md); a successful subcheck is not a whole-case pass.

| Cases | Original verdict | Reason |
| --- | --- | --- |
| L01, L02 | PASS | Compilation, parsing and tested context/ownership rejection fixtures passed. |
| L03 | INCONCLUSIVE | Changed-artifact and stale-preview deployment rejection were not covered by executable fixtures in that reviewed snapshot. |
| L04 | PASS | The reviewed source export passed the applicable scan, fixture and copy-integrity checks. |
| C01, C02 | INCONCLUSIVE | Ownership/configuration evidence did not complete activity attribution or inherited-permission assessment. |
| C03, C04, C05 | INCONCLUSIVE | Selected private paths, network denials and gateway inference worked; complete endpoint coverage and request attribution were missing. |
| C06, C07 | BLOCKED | Wrong-tenant context and full route/request-policy qualification were missing. |
| C08, C09, C10, C11 | BLOCKED | Actual runtime bypass, administrative separation, repository negatives and full limit enforcement remained incomplete. |
| C12 | INCONCLUSIVE | Private runner administration worked; complete effective-network evidence remained incomplete. |
| A01, A02, A03 | BLOCKED | Agent invocation and remaining lifecycle/consumer controls were not established. |
| A04, A05, A06, A07, A08 | BLOCKED | Hosted startup, runtime identity/network controls, telemetry correlation and revocation were not qualified. |
| R01 | PASS | Ordered provisioning and the historical private-access activation gate were exercised. |
| R02, R03 | BLOCKED | Same-input idempotency and controlled interruption/recovery were not qualified. |
| R04, R05 | PASS | Evidence survived and the deployed non-hosted resource set was removed in dependency order. |
| R06 | INCONCLUSIVE | Unchanged baseline membership did not overcome incomplete activity-log coverage. |
| R07 | BLOCKED | A clean rebuild cycle was not performed. |

## Lifecycle Findings

Teardown required removing monitoring private-link associations before their targets and Foundry projects before their parent accounts. Integration remained available until dependent groups were removed. Final observations confirmed absence of the owned groups and their active resources.

Pre-existing resource ID membership was unchanged, but this does not prove unchanged configuration, data-plane noninterference or absence of every outside write. Activity collection was incomplete. Retained service records were observed separately; no purge, recoverability, name-reuse or final-billing guarantee follows.

The original inventory's integrity was verified after removal. Private reports also survived, but their newly recorded post-removal hashes were not compared with pre-removal report hashes. Source export was a separate reviewed artifact, not a private evidence backup.

Use the [independent lifecycle](independent-lifecycle.md) for new core runs. Do not replay historical commands, transfer these verdicts to another deployment or infer operational approval from this report.
