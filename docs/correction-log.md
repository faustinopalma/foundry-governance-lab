# Lessons From Implementation

These lessons explain corrections that changed the interpretation or reliability of governance checks. They are not a sequence of operational decisions. The [results summary](lab-summary.md) describes observed flows; detailed execution records remain private.

## Configuration Is Not Runtime Evidence

A model connection can exist in ARM and still be unresolved by the agent runtime. The original account-level connection failed during invocation; a later Standard-expanded configuration with a project-scoped connection supported a real response. Connection scope, authentication, audience and supported protocol must be tested together.

Private configuration also does not prove a private runtime route. An early agent request reached APIM through a public path and was rejected, while runner-origin gateway inference worked. Opening the gateway would have hidden the failure of the intended boundary. The later successful configuration does not retrospectively qualify the earlier one.

## Test The Actual Protocol

The agent's outer response protocol and its model-backend protocol can use different streaming settings. Forcing the backend to be non-streaming broke the agent contract. The gateway now preserves explicit backend streaming while applying the same authentication, routing and generation controls.

Cosmos DB Direct connectivity requires more than a successful HTTPS probe. Its additional TCP path is scoped to verified private endpoint addresses. Opening an entire destination subnet would have broadened access without demonstrating that the actual runtime flow was correct.

A registry manifest is not the complete image. The publisher checks follow the permitted data-endpoint redirect and validate the downloaded configuration blob. They still do not prove that the managed hosting platform can pull or start that image.

## Classify Denials By Cause

A generic authentication error cannot establish an authorization boundary. Direct-model denials were qualified only when token context, explicit service permission errors and a working backend positive control supported that conclusion. Other ambiguous denials remain inconclusive.

Likewise, a timeout is not a network-isolation pass, and a successful management operation is not a successful data-plane request. A missing response field must be interpreted according to the actual API contract: absence of a retention flag in a response is neither proof of retention nor proof of deletion.

## Bind Checks To The Intended Target

Validate the owned agent and expected version before invoking it, not only when reviewing the result afterward. A mismatch must stop the request without updating, recreating or deleting the agent to make the test pass.

Discover service-created workspace containers under the exact owned account before granting access. Deriving names from an assumed identifier representation can select the wrong target. Provisioning roles and runtime container/database roles must remain separate.

Private DNS checks compare the queried name with its matching endpoint NIC configuration. Combining every address from an endpoint can falsely reject a correct service-specific mapping or accept an unrelated address.

## Observe Pending Work Instead Of Replaying It

A successful submission, CLI wait or activity-log event can precede actual service readiness. Completion requires fresh ARM state and resource postconditions. A local timeout stops observation, not the cloud operation; it does not justify a second submission or clearing pending state.

Read-only verification can itself dominate an operation when each request starts a new CLI process. Reusing a bounded authenticated HTTP session reduced that overhead without removing ownership checks or preservation reads. This is an orchestration lesson, not a model-performance result.

## Accept Equivalent Responses Without Relaxing Boundaries

ARM may return equivalent region names, capitalization, qualified child names or sparse what-if metadata. Normalize only verified equivalent representations. Keep the reviewed template and live ownership, identity, private-access and scope checks strict.

Generated NICs, policy-created extensions and inherited assignments require explicit classification. Their presence is not permission to adopt unrelated resources or broadly ignore changes. Failed policy automation remains a recorded environmental failure, not a successful deployment or authorization to change organizational policy.

Source hashes protect the connection between a reviewed change and its execution. When a read-only validator needs correction after submission, preserve the original reviewed source and record the revision separately. Replacing old hashes with new ones would erase the distinction between the submitted artifact and the later verifier.

## Remove Dependencies In Their Actual Order

Resource-group ordering alone did not handle cross-group monitoring links. Azure Monitor Private Link Scope links must be removed before their workspace and Application Insights targets. Foundry projects must finish deletion before the account, and the account must be absent before group removal proceeds.

Keep integration networking and the runner until their dependents are gone. A successful deletion response is not absence, and absence is not purge, name reusability or a clean rebuild.

## Keep Evidence Independent Of The Lab

Run Command extension success does not guarantee that a test produced a complete report. Require the expected framed result, retain request-to-report bindings and verify exported evidence. Public harnesses and private state belong in separate locations; operator credentials must not be copied to the runner.

Inventory equality shows membership, not attribution of all changes. Incomplete activity-log coverage cannot prove that no outside write occurred, even when no such write appears in the collected events. Missing coverage stays explicit instead of being converted into a pass.
