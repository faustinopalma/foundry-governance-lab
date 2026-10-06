# Governance Test Plan

Every governance claim needs an operation that should work and a corresponding operation that should be refused. The purpose is to establish access boundaries, not measure throughput or model latency.

This is the acceptance catalog, not a list of completed tests. See [tested flows and results](lab-summary.md) for observed behavior. Case identifiers remain stable so evidence can reference a criterion without duplicating it.

## Result Rules

| Verdict | Meaning |
| --- | --- |
| PASS | The stated criterion is supported by the required positive controls, expected denials and evidence. |
| FAIL | An established boundary or invariant is violated, or an authorized operation fails after its prerequisites are established. |
| BLOCKED | A required capability, fixture, permission or approved execution context is missing. |
| INCONCLUSIVE | The request ran, but its outcome cannot establish the criterion. |

Use the actual low-privilege identity for permitted and forbidden operations. First establish that the target exists, the request is valid and an authorized caller can use it. Owner credentials cannot demonstrate developer permissions. A generic authentication error, missing target or timeout is not an authorization pass.

For network tests, use a known listening target and an allowed source, then establish why the restricted path fails. Runner traffic cannot substitute for traffic from an actual project or hosted runtime. Review inherited permissions; a project-scoped role does not cancel a broader assignment.

## Local And Execution Safety

| ID | Required behavior | Evidence |
| --- | --- | --- |
| L01 | Infrastructure compiles and scripts parse. | Reviewed source/artifact bindings; schema suppressions assessed separately. Compilation is not runtime qualification. |
| L02 | Valid owned targets are accepted; wrong context, ownership and external targets are rejected. | Synthetic guard fixtures fail before mutation. Never issue an out-of-scope cloud write to test the guard. |
| L03 | Reviewed changes can proceed; stale, changed, incomplete or out-of-scope previews cannot. | Executable rejection fixtures and unchanged reviewed inputs. Reject deletions and unexplained scope. |
| L04 | Reviewed source can be exported; credentials and private execution material cannot. | Allowlist, confidentiality fixtures, matching export hashes and manual review. |

## Core Governance

| ID | Flow that must work | Flow or condition that must be blocked |
| --- | --- | --- |
| C01 | Operate on the exact owned resource set. | Adoption or modification of unrelated resources; incomplete attribution cannot establish noninterference. |
| C02 | APIM invokes the approved centrally hosted model. | Case-local model or key fallback; assess effective inherited grants, not only lab-created roles. |
| C03 | Service names resolve to their owned endpoints and permitted private operations work. | Unexpected addresses, missing endpoint approvals or unverified paths block dependent tests. Include registry data and monitoring paths. |
| C04 | The authorized operation works privately. | The corresponding public path refuses access. Check settings and actual service responses, not a client-side timeout alone. |
| C05 | An approved identity obtains a valid model response through APIM. | Require evidence associating caller, gateway and backend; response success alone is not complete attribution. |
| C06 | A valid approved caller reaches the gateway route. | Anonymous, invalid-token, wrong-audience and unapproved callers are denied. Wrong-tenant tests need a separately approved tenant. |
| C07 | The approved route and valid request reach the fixed backend. | Alternate deployments, unsupported operations, malformed or oversized requests and backend overrides are refused. Verify rejected requests do not invoke the model. |
| C08 | The gateway identity can invoke the central deployment. | Developer, consumer, actual project and hosted-runtime identities cannot bypass the gateway with otherwise valid requests. |
| C09 | Developers manage their own permitted project. | Sibling-project, cross-case, connection, model, gateway-policy and RBAC modifications or privilege escalation are denied. Use disposable owned fixtures. |
| C10 | Each publisher pushes and retrieves its permitted image. | Cross-case and out-of-condition repository reads and writes are denied against existing targets. No admin or catalog-wide fallback. |
| C11 | Valid requests within policy limits work. | Requests exceeding policy limits are refused. Use an approved mock backend for quota tests, then restore and verify the policy. This is enforcement testing, not benchmarking. |
| C12 | Authorized management-plane administration reaches the private runner. | No public VM address or inbound SSH. The trusted runner deliberately does not isolate its attached identities from each other. |

## Agent And End-To-End Governance

| ID | Flow that must work | Flow or condition that must be blocked |
| --- | --- | --- |
| A01 | A developer creates, versions, invokes and deletes a disposable own-project agent. | The same mutations on existing sibling and cross-case fixtures are denied. Test each operation separately. |
| A02 | A consumer invokes its assigned agent. | Agent mutations, connection changes and cross-case invocation are denied. |
| A03 | A real prompt agent uses the intended gateway connection and completes a request. | No local-model or direct-inference fallback. Correlate the actual caller and backend; an unsupported protocol remains blocked. |
| A04 | A hosted agent starts from its approved private-registry image. | An otherwise valid fixture without repository permission cannot start; restoring permission restores startup. Observe the actual pull identity. |
| A05 | A hosted agent reaches APIM as its runtime identity. | That identity cannot invoke the model directly or use an unauthorized gateway route. Keep runtime and image-pull identities distinct. |
| A06 | Actual runtimes reach their own dependencies and APIM. | Protected cross-case and direct-model network paths are blocked from the actual injected network. |
| A07 | Authorized operators correlate requests and read the intended telemetry. | Other-case log access is denied; inspect for unintended synthetic payload and token capture. Missing telemetry is not proof of no leakage. |
| A08 | A temporary permission works before revocation and after restoration. | Fresh requests stop succeeding after that permission is revoked. Account for propagation and cached tokens without unbounded retries. |

Dev/test projects share their case's subnet and repository by design. Do not claim isolation at a boundary the lab does not implement. Human group lifecycle, privileged-access management, hostile workloads sharing a host and general outbound exfiltration protection require separate qualification.

## Lifecycle And Repeatability

| ID | Required behavior | Evidence boundary |
| --- | --- | --- |
| R01 | Provision forward through bootstrap, lock and activation; reject skipped or backward transitions. | New independent creation uses fresh management-plane privacy gates without running tests. Historical profiles retain their own recorded gates. |
| R02 | Reapplying identical reviewed inputs does not replace resources, duplicate access or lose private settings. | A recovered failed deployment is not an idempotency test. |
| R03 | Interrupted work resumes by observing actual state and preserving pending intent. | No blind resubmission, reset to bootstrap or clearing state to bypass reconciliation. |
| R04 | Evidence remains available after lab removal. | Export complete private reports before deletion; missing tests retain their verdicts. |
| R05 | Separately authorized teardown removes only owned resources in dependency order. | Monitoring links precede targets, project children precede accounts, integration remains last. Verify absence; submission alone is insufficient. |
| R06 | Lab activity does not modify unrelated resources. | Inventory membership and complete attributable activity are different evidence. Incomplete collection cannot prove noninterference. |
| R07 | A fresh reviewed deployment reproduces the selected profile after teardown. | Requires another verified deploy/test/remove cycle, not merely reusable scripts. |

## Run Procedure

Choose only the requested test groups and approved fixtures through the [independent lifecycle](independent-lifecycle.md). Creation does not run tests; test approval does not permit infrastructure repair or teardown. Existing minimal and expanded states use their matching [advanced procedures](runbook.md).

Establish prerequisites, run permitted controls, then corresponding negative controls. Perform destructive fixture or revocation tests only when explicitly selected and restore their original configuration. Stop dependent cases when prerequisites fail; never broaden roles, enable public access or substitute credentials to obtain a pass.

Preserve actor, target, operation, positive-control reference, observed response, verdict and source/configuration binding in private evidence. Keep execution metadata there for diagnosis, without turning it into a public performance score. Publish only the governance finding and its limitations.
