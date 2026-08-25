# Northbeam Lite — Hands-On AWS IAM Security Project

A single-account AWS environment built from scratch to learn and demonstrate IAM security engineering: identity federation, policy evaluation logic, attribute-based access control, machine identities, permissions boundaries, and audit automation.

## ⚠️ Scope and honesty statement — read this first

This is a learning project, deliberately optimized for cost, not a reference architecture.

The scenario it models — a fictional SaaS startup called Northbeam — would in reality be built as a multi-account AWS Organization with Service Control Policies, a dedicated centralized logging account, IAM Identity Center for human access, and Control Tower guardrails. This project implements none of those, on purpose.

The reason is specific and worth stating: as of July 2025, AWS's free plan grants new accounts up to $200 in credits, but those credits expire immediately the moment the account joins an AWS Organization, and the account is force-upgraded to a paid plan. Building the "correct" multi-account version on day one would have destroyed the entire budget for the later, genuinely expensive phases of learning (Terraform, EKS, CloudGoat).

So the deliberate tradeoff was: build every IAM control that can be built inside one account, correctly and provably, and defer the account-boundary controls to a later phase where they belong.

### What this means for a reader evaluating this repo

| Built and proven here | Deliberately deferred |
| --- | --- |
| MFA-gated role assumption via STS | Multi-account isolation (AWS Organizations) |
| Least-privilege policy authoring | Service Control Policies (SCPs) |
| Policy evaluation logic (explicit deny) | Centralized, tamper-proof logging account |
| ABAC with principal/resource tags | IAM Identity Center / SSO federation |
| EC2 instance profiles with IMDSv2 | Control Tower guardrails |
| GitHub Actions OIDC federation | Cross-account role assumption |
| Permissions boundaries | CloudTrail data events (cost) |
| CLI-based audit scripting | Infrastructure as Code (Terraform — Phase 6) |

Every control in the left column was built by hand, deliberately broken to prove it worked, and verified with real evidence from a live AWS account.

## The scenario

Northbeam is a fictional two-person SaaS startup. Its founder did what most early-stage companies do: logged in as root, created IAM users for both engineers, and attached `AdministratorAccess` to each because figuring out real permissions felt like a waste of time.

That setup works fine — right up until it doesn't. Permanent credentials that never expire. Two people who can each delete production. Dev experiments sharing an account with customer data. Nothing technically preventing disaster, only carefulness, which is not a security control.

This project rebuilds that account properly, one control at a time, with each milestone solving a specific problem created by the previous state.

## Method

Every milestone followed the same loop:

1. **Understand the problem first** — what specific failure makes this control necessary?
2. **Predict before building** — write down what the policy should look like and what should happen, before touching AWS.
3. **Build it.**
4. **Deliberately break it** — prove the control actually fires, rather than assuming it does.
5. **Read the real evidence** — CLI output, HTTP status codes, CloudTrail entries. Not "it seemed to work."

Step 4 is the one most tutorials skip, and it's where most of the actual learning happened.

## Milestones

| # | Milestone | Core concept | Status |
| --- | --- | --- | --- |
| 0 | Account foundations | Root hardening, MFA, budget alarm | ✅ |
| 1 | Trust & STS | MFA-conditioned role assumption | ✅ |
| 2 | Policy evaluation logic | ARN granularity, explicit deny precedence | ✅ |
| 3 | ABAC | Tag-driven access, one policy serving many projects | ✅ |
| 4 | Machine identities | EC2 instance profile + IMDSv2, GitHub OIDC | ✅ |
| 5 | Permissions boundaries | Delegated role creation with a hard ceiling | ✅ |
| 6 | Audit toolkit | Dormant-risk and behavioral-risk scripting | ✅ |
| 7 | Documentation | This repository | ✅ |

## Environment

- Single AWS account, free plan
- Regions used: `eu-north-1` (Stockholm) primarily, with some resources in `us-east-1`. (Note: region sprawl was itself an unintentional lesson — see [DECISION-LOG.md](DECISION-LOG.md))
- Resources: 7 IAM roles, 1 IAM user, 2 S3 buckets, 1 EC2 t3.micro, 1 CloudWatch log group, 1 OIDC identity provider
- Total cost: under €2

## Companion documents

- [ARCHITECTURE.md](ARCHITECTURE.md) — all diagrams
- [DECISION-LOG.md](DECISION-LOG.md) — engineering decisions and tradeoffs
- [THREAT-MODEL.md](THREAT-MODEL.md) — what this defends against, and what it does not
- [LIMITATIONS.md](LIMITATIONS.md) — honest gaps
- [policies/](policies) — every policy document used
- [scripts/](scripts) — the audit toolkit

---

# Milestone detail

## Milestone 0 — Account foundations

**Problem:** Nothing exists yet. The root user is the only identity, and it has absolute, unrestrictable power that no policy can ever limit — because every policy is created by root's authority in the first place.

**Built:**

- Root user secured with MFA (authenticator app), then deliberately set aside for emergency use only
- AWS Budgets zero-spend alarm — alerts on any charge at all
- Free plan selected over paid plan (see scope statement for the credit-expiry reasoning)

**Challenge encountered:** After signup, the IAM console redirected to an "account setup incomplete" page. Diagnosis: payment verification had not finished — AWS requires a valid payment method on file even for free-plan accounts, with a temporary ~$1 authorization hold as identity verification. Not a free-plan service restriction, which is what the page's wording implied.

**Second challenge — the credit trap:** Clicking into IAM Identity Center presented an "enable" flow that would have created an AWS Organization. Per AWS's own documentation, this would have expired all free-tier credits immediately and force-upgraded the account to paid. Avoided deliberately. This is the single most expensive mistake a new AWS learner can make in the first hour, and it is presented in the console as a normal setup step.

**Learning:** Read what a console button actually does before clicking it. The cost of a wrong click here was ~$200 of learning budget.

## Milestone 1 — Trust & STS: eliminating the standing admin credential

**Problem:** The naive pattern is "root creates an IAM user, attaches `AdministratorAccess`." That user's password and any access keys it generates are long-lived — they don't expire. If leaked, an attacker has full access indefinitely, with no clock running against them. This is the pattern behind the Uber 2022 breach class of incident.

**Design:** Separate the identity that logs in from the identity that has power.

- `Ishaan-admin` (IAM user) — a human login with exactly one permission: `sts:AssumeRole` on one specific role ARN. Nothing else. No S3, no EC2, no IAM read access.
- `NorthbeamAdmin` (IAM role) — holds `AdministratorAccess`, but is unreachable except through STS, and only when the calling session proves MFA.

Trust policy on `NorthbeamAdmin` — [`policies/northbeam-admin-trust.json`](policies/northbeam-admin-trust.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<ACCOUNT_ID>:user/Ishaan-admin" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool": { "aws:MultiFactorAuthPresent": "true" }
      }
    }
  ]
}
```

Permissions policy on `Ishaan-admin` (inline, `AssumeNorthbeamAdminOnly`) — [`policies/assume-northbeam-admin-only.json`](policies/assume-northbeam-admin-only.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/NorthbeamAdmin"
    }
  ]
}
```

**Two gates, both required:** The trust policy answers "who may become this role?" The permissions policy answers "is this user even allowed to try?" Both must open. A role with a wide-open trust policy but no user permitted to call it is unreachable; a user with `sts:AssumeRole` but no matching trust policy is refused.

**Challenges encountered:**

1. **An identity with zero permissions cannot bootstrap itself.** `Ishaan-admin` could not attach its own policy, and could not enable its own MFA device. Both required logging back in as root. This is correct behavior — self-granting permissions would be a privilege-escalation hole — but it means root genuinely must exist and must be used for exactly this kind of bootstrap.
2. **Confusing `iam:ListRoles` denials with the actual test.** Browsing IAM → Roles as `Ishaan-admin` fails, and looks like a problem. It isn't — that user was never meant to browse IAM. Role assumption happens through Switch Role, which requires knowing the role's name, not seeing it in a list.

**Proof:** Role assumption without MFA on the session → refused. Same attempt with MFA present → succeeded, returning temporary credentials with a 1-hour max session duration.

**Learning:** Blast radius shrinks in two dimensions, not one. Scoping what a credential can do is only half of it; capping how long it stays valid is the other half, and it's the one that makes a stolen session token a bounded problem instead of an unbounded one.


## Milestone 2 — Policy evaluation logic

**Problem:** Writing a policy that "looks right" and one that is right are different things. This milestone builds the ability to predict a policy's real behavior before deploying it.

**Built:** `NorthbeamS3ReadOnly` — read-only access to exactly one S3 bucket and nothing else. See [`policies/northbeam-s3-readonly.json`](policies/northbeam-s3-readonly.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowListBucketItself",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::northbeam-dev-data-ishaan-<ACCOUNT_ID>-eu-north-1-an"
    },
    {
      "Sid": "AllowGetObjectsInside",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::northbeam-dev-data-ishaan-<ACCOUNT_ID>-eu-north-1-an/*"
    }
  ]
}
```

**Key insight — ARN granularity:** `s3:ListBucket` operates on the bucket (no trailing slash). `s3:GetObject` operates on objects inside it (`/*`). These are different resources to IAM's evaluation engine even though they're conceptually "the same bucket." Listing only one ARN silently breaks the other action.

**Verified behavior** (assumed via a dedicated `TestRole` carrying only this policy, so nothing else could mask the result):

| Command | Result | Why |
| --- | --- | --- |
| `aws s3 cp s3://bucket/showtext -` | ✅ Succeeded | GetObject granted on `/*` |
| `aws s3 cp file s3://bucket/upload-test.txt` | ❌ AccessDenied | PutObject never granted — default deny |
| `aws s3 ls` | ❌ AccessDenied | Calls `s3:ListAllMyBuckets`, a different action from ListBucket — never granted |

That third row is the subtle one: "list" means two entirely different IAM actions depending on whether you're listing buckets in an account or objects in a bucket.

**Explicit deny test:** An inline Deny on `s3:GetObject` was attached alongside the still-active Allow. The read then failed — proving explicit deny wins over explicit allow, on real infrastructure rather than as a diagram.

**Challenge encountered — a real AWS console bug:** Role switching via the console's Switch Role page failed repeatedly with a generic "Invalid information in one or more fields." Diagnosis required checking CloudTrail (no AssumeRole events were reaching AWS at all) and the browser console (`TypeError: Cannot read properties of undefined (reading 'text')` inside AWS's own switchrole page script). The same assume-role call succeeded immediately via CloudShell CLI.

**Learning from that bug:** The security boundary and the client that talks to it are different things. A broken UI does not mean a broken policy. CloudShell CLI became the canonical verification environment for the rest of the project — evidence over interface.

## Milestone 3 — ABAC: one policy, many projects

**Problem:** RBAC doesn't scale. A role per project (`ProjectAlphaDev`, `ProjectBetaDev`, …) means every new project creates a new role and policy that someone must keep consistent. At 40 engineers across 6 clients, nobody audits 40 near-identical policies carefully.

**Design:** One shared policy that never mentions a project name. Access is computed at request time by comparing a tag on the principal against the path being accessed.

**Critical design decision — role tags, not session tags:** If the project identity were passed as a session tag at assume-time, the caller could simply assert `Project=Alpha` and read another team's data. Instead, each role carries a permanent tag set by an administrator, which populates `aws:PrincipalTag/Project` automatically on assumption. Nobody self-asserts anything.

- `NorthbeamDeveloper-Alpha` → role tag `Project = Alpha`
- `NorthbeamDeveloper-Beta` → role tag `Project = Beta`

Shared policy `NorthbeamProjectABAC`, attached identically to both — [`policies/northbeam-project-abac.json`](policies/northbeam-project-abac.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOnlyOwnProjectPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::northbeam-shared-<ACCOUNT_ID>",
      "Condition": {
        "StringLike": { "s3:prefix": "${aws:PrincipalTag/Project}/*" }
      }
    },
    {
      "Sid": "GetOnlyOwnProjectObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::northbeam-shared-<ACCOUNT_ID>/${aws:PrincipalTag/Project}/*"
    }
  ]
}
```

The `${aws:PrincipalTag/Project}` variable resolves per-session. For an Alpha session the resource path becomes `.../Alpha/*`; for Beta, `.../Beta/*`. Same JSON, different real access.

**Verified:**

| Session | Target | Result |
| --- | --- | --- |
| NorthbeamDeveloper-Alpha | `Alpha/alpha-secret.txt` | ✅ Read succeeded |
| NorthbeamDeveloper-Alpha | `Beta/beta-secret.txt` | ❌ 403 Forbidden |
| NorthbeamDeveloper-Beta | `Beta/beta-secret.txt` | ✅ Read succeeded |

**Accidental finding:** An attempt to re-assume a role while holding Alpha's credentials failed with AccessDenied on `sts:AssumeRole`. This was unintended but correct — the developer role's only permissions are the S3 ABAC policy; nothing grants it role-assumption rights. A developer identity that cannot chain into other roles is exactly the intended least-privilege outcome.

**Correction to a common misconception** (documented because it was gotten wrong first): A bare 403 Forbidden is not a reliable signature of "explicit deny beat an allow." `aws s3 cp` for downloads calls HeadObject first, and S3's HeadObject returns an unexplained 403 regardless of why access was refused. Error verbosity depends on which API the CLI invokes under the hood, not on which flavor of deny occurred.


## Milestone 4 — Machine identities

Two distinct patterns, both eliminating stored credentials.

### 4a — EC2 instance profile with IMDSv2

**Problem:** An application on EC2 needs AWS access. The lazy fix — an IAM user's access key pasted into config — recreates the permanent-leakable-credential problem, now baked into a server.

**Fix:** Attach a role directly to the instance. The AWS SDK fetches short-lived, auto-rotating credentials from the instance metadata service at `169.254.169.254`. No key exists on disk.

Trust policy — note the third principal type used in this project (`Service`, not `AWS` or `Federated`) — [`policies/ec2-instance-role-trust.json`](policies/ec2-instance-role-trust.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Permissions — scoped to one log group and nothing else — [`policies/northbeam-ec2-logs-only.json`](policies/northbeam-ec2-logs-only.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOwnLogGroupOnly",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:<ACCOUNT_ID>:log-group:/northbeam/api-lite:*"
    }
  ]
}
```

**Why IMDSv2 matters — the Capital One mechanism:** The metadata endpoint is reachable by anything running on the instance, including a bug. An SSRF vulnerability lets an attacker coerce the application into requesting `169.254.169.254` on their behalf; the metadata service, unable to distinguish that from legitimate code, returns valid role credentials. IMDSv1 answers a single unauthenticated GET. IMDSv2 requires a PUT to obtain a session token first, then a GET carrying that token — a meaningfully harder shape for a typical SSRF flaw to forge.

**Verified with HTTP status codes, not assumptions:**

```console
$ curl -i http://169.254.169.254/latest/meta-data/
HTTP/1.1 401 Unauthorized          ← IMDSv1-style request refused

$ TOKEN=$(curl -s -X PUT ".../latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -i -H "X-aws-ec2-metadata-token: $TOKEN" .../iam/security-credentials/
HTTP/1.1 200 OK
NorthbeamEC2InstanceRole           ← token-authenticated path works

$ aws sts get-caller-identity
"Arn": "arn:aws:sts::<ACCOUNT_ID>:assumed-role/NorthbeamEC2InstanceRole/i-0fdfd137d8a831b22"
```

Note the session name: the instance ID, auto-generated by EC2. Nothing was configured or typed.

**Process note:** The first verification attempt used bare `curl` with no `-i` flag and returned empty output. Empty output is ambiguous — it could mean rejection or a silent failure. Re-running with `-i` to expose status codes turned an assumption into evidence.

### 4b — GitHub Actions OIDC federation

**Problem:** CI/CD needs to deploy to AWS. Storing an access key in GitHub Secrets moves the permanent-credential problem to a third location.

**Fix:** GitHub mints a short-lived, cryptographically signed JWT per workflow run, asserting which repo, branch, and job is running. AWS verifies the signature against GitHub's published public keys — no pre-shared secret ever exists. STS exchanges a valid token for temporary credentials.

Trust policy (third principal type: `Federated`; and note the different STS action) — [`policies/github-oidc-trust.json`](policies/github-oidc-trust.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:sub": "repo:Ishaan-03@166810647/Github-OIDC-Test-Repo@1343165551:ref:refs/heads/main",
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
```

**Two independent conditions:** `sub` scopes to one repo and one branch; `aud` confirms the token was minted for STS specifically, so a token issued for another purpose can't be replayed here.

**The most instructive debugging episode in the project:**

The first run failed with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. A quick suggested fix was to replace `StringEquals` with a `StringLike` wildcard — which would have worked, by loosening a security condition without knowing why it failed. That was rejected as a fix-by-weakening.

Instead, a temporary workflow step decoded the actual OIDC token GitHub was sending:

```yaml
- name: Decode OIDC token claims
  run: |
    curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
      | jq -r '.value' | cut -d '.' -f2 | base64 -d 2>/dev/null | jq .
```

The real claim was:

```json
"sub": "repo:Ishaan-03@166810647/Github-OIDC-Test-Repo@1343165551:ref:refs/heads/main"
```

Not the documented-everywhere format `repo:owner/name:ref:refs/heads/main`. GitHub now embeds numeric owner and repository IDs — because usernames and repo names can be renamed and re-registered by someone else, while numeric IDs are immutable. It's a genuine supply-chain hardening measure, not a quirk.

The fix kept `StringEquals` and simply used the correct value — just as narrow as originally designed, only accurate.

**Learning:** When a security control refuses a request, the correct first move is to read what the control actually saw — not to widen the control until it stops objecting.


## Milestone 5 — Permissions boundaries

**Problem:** An admin hand-creating every role is a bottleneck. Letting developers create roles freely means any one of them can create a role with `AdministratorAccess`. Neither is acceptable.

**Fix:** A ceiling. A second policy attached to whatever gets created, capping effective permissions to the intersection of (the role's own policy) AND (the boundary) — regardless of how generous the first one is.

The ceiling — `NorthbeamDevBoundary` — [`policies/northbeam-dev-boundary.json`](policies/northbeam-dev-boundary.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DevBoundaryAllowedActions",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:ListBucket",
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query",
        "logs:CreateLogStream", "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DevBoundaryDenyEverythingElse",
      "Effect": "Deny",
      "Action": ["iam:*", "organizations:*", "account:*"],
      "Resource": "*"
    }
  ]
}
```

**Why the explicit Deny isn't redundant:** omitting an action from the Allow list gives you default deny, which holds only as long as nothing anywhere grants it. An explicit Deny is absolute — it overrides any future Allow from any policy, forever. Defense in depth against a mistake nobody has made yet.

**Note on scope:** an earlier draft of this boundary used `s3:*` / `dynamodb:*` / `lambda:*`. It was tightened to specific actions after reasoning that a boundary only limits maximum damage — it is not a substitute for writing the underlying policy narrowly, and a wide ceiling combined with a careless policy provides no protection at all.

The delegated creator — `NorthbeamDevSelfService` — [`policies/northbeam-dev-selfservice.json`](policies/northbeam-dev-selfservice.json):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateDevRolesOnlyWithBoundary",
      "Effect": "Allow",
      "Action": "iam:CreateRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/northbeam-dev-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::<ACCOUNT_ID>:policy/NorthbeamDevBoundary"
        }
      }
    },
    {
      "Sid": "AttachPoliciesToOwnDevRoles",
      "Effect": "Allow",
      "Action": ["iam:AttachRolePolicy", "iam:PutRolePolicy"],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/northbeam-dev-*"
    },
    {
      "Sid": "BlockRemovingOrSwappingBoundary",
      "Effect": "Deny",
      "Action": ["iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary"],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::<ACCOUNT_ID>:policy/NorthbeamDevBoundary"
        }
      }
    }
  ]
}
```

**Three rules:** create only this name shape, and only with the ceiling attached; configure only what you created; never remove or swap the ceiling afterward.

**How the enforcement actually works** (a point that is easy to get wrong): nothing auto-attaches the boundary. The creator must pass `--permissions-boundary <arn>` explicitly on every `create-role` call. The condition's job is to refuse the entire action when that value is absent or different — so in practice the only role creation that can succeed is one carrying the correct ceiling.

**Verified — the payoff test:**

```console
# Checkpoint 1 — create without boundary
$ aws iam create-role --role-name northbeam-dev-test --assume-role-policy-document file://trust.json
AccessDenied ... because no identity-based policy allows the iam:CreateRole action
   ↑ condition didn't match, so the Allow statement never applied → default deny

# Checkpoint 2 — same command, boundary specified
$ aws iam create-role ... --permissions-boundary arn:aws:iam::<ACCOUNT_ID>:policy/NorthbeamDevBoundary
✅ Role created, with PermissionsBoundary attached

# Checkpoint 3 — attach AdministratorAccess to the boundary-capped role, then test it
$ aws s3 ls
AccessDenied ... because no permissions boundary allows the s3:ListAllMyBuckets action

$ aws iam list-users
AccessDenied ... with an explicit deny in a permissions boundary
```

A role holding `AdministratorAccess` could do neither. Two different mechanisms fired, and AWS's error messages name them distinctly:

1. **Ceiling by omission** — `ListAllMyBuckets` was never in the boundary's Allow list, so the intersection excluded it.
2. **Ceiling by explicit deny** — `iam:*` is actively forbidden, overriding the Allow regardless.

**Clarification worth recording** (this was initially confusing): the boundary is attached to the child role, never to the delegated creator. `NorthbeamDevSelfService` has no boundary of its own — which is why it can call `iam:CreateRole` at all despite the boundary's `iam:*` deny. The boundary governs what gets created, not the creator.


## Milestone 6 — Audit toolkit

**Problem:** Everything up to here was built deliberately, one control at a time, with full knowledge of what changed. Real accounts drift. The toolkit answers two structurally different questions:

- **Dormant risk** — what exists that could be abused, but hasn't been? (Static inspection)
- **Behavioral risk** — what did someone actually attempt? (CloudTrail)

Neither lens alone is sufficient. A role with `AdministratorAccess` that nobody has touched in six months produces zero CloudTrail events — perfect silence, and a live risk.

### Script 1 — access key age scanner

[`scripts/keyaudit.sh`](scripts/keyaudit.sh) loops every IAM user, finds access keys, computes age in days, flags anything over the 90-day rotation threshold.

**Validation methodology — the important part:** the script initially reported nothing, which was correct (no keys existed by design). But a detector that has never caught anything is indistinguishable from a broken one. So a deliberate violation was created (`aws iam create-access-key`), the script re-run to confirm detection, the threshold temporarily lowered to `-ge 0` to confirm the flagging logic fires independently of the detection logic, then the test key deleted and a final clean run confirmed return to zero findings.

### Script 2 — unused role detector

[`scripts/roleaudit.sh`](scripts/roleaudit.sh) queries `RoleLastUsed.LastUsedDate` on every role.

**Findings and what they proved:**

| Role | Last used | Significance |
| --- | --- | --- |
| GitHubActionsDeploy | Real timestamp | AssumeRoleWithWebIdentity is tracked — federated assumption counts |
| NorthbeamEC2InstanceRole | Recent timestamp | Never assumed by a human — IMDS credential refresh is an AssumeRole under the hood |
| AWSServiceRoleForSupport | NEVER | AWS-created service-linked role, genuinely unused |
| AWSServiceRoleForTrustedAdvisor | NEVER | Same |

The NEVER entries are benign here, but they are exactly the shape of finding this script exists to surface: in a real account, that same line next to a role a departed engineer built two years ago is the actual discovery.

**Secondary value:** the role list was short and every entry was explainable. In a real audit, a long list of unrecognized roles is itself the red flag.

### Script 3 — CloudTrail AccessDenied hunter

Three real limitations of [`scripts/cloudtrailaudit.sh`](scripts/cloudtrailaudit.sh) discovered by running it, all worth knowing before relying on this in production:

1. `lookup-events` retains only 90 days, and is a separate, smaller window from a full S3-backed CloudTrail trail (which this project never configured, deliberately — cost).
2. **Data events aren't logged by default.** The S3 `PutObject` / `ListAllMyBuckets` denials from Milestones 2–3 do not appear, because object-level actions require a paid data-event trail. Only management-plane events (IAM, STS, EC2, etc.) are captured for free.
3. **The time window silently hides findings.** A `2 days ago` start time excluded the Milestone 5 boundary denials by a matter of hours. They were still in CloudTrail — just outside the slice requested. A CloudTrail query is only as good as the window you deliberately choose.

**Signal-vs-noise finding:** most returned denials were background chatter — the AWS Console itself probing `GetAccountColor`, `ListNotificationHubs`, `DescribeEventAggregates` while rendering widgets, and the internal `resource-explorer-2` service scanning unsubscribed services (Partner Central, IoT FleetWise, Route53 Domains). None of it security-relevant. Learning to filter this automatic self-noise from genuine probing is a core part of reading CloudTrail at scale.

**Bonus observation:** hundreds of AssumeRole events with `Username: None`, every 15–60 minutes for days, turned out to be the EC2 instance's credentials silently refreshing. `Username: None` is a usable fingerprint for "automated infrastructure activity" versus "a human did this."

**Also discovered by failure:** the original script used a JMESPath `--query` with backticks, which the shell mangled into `Bad jmespath expression: Bad token "erro"`. Replaced with a simpler `grep` over raw JSON output — a reminder that shell quoting is its own failure surface, independent of AWS.

---

# Reproduction steps

For anyone (including the author, later) who wants to rebuild this from an empty account.

**Prerequisites:** a fresh AWS account on the free plan, an authenticator app, a GitHub account.

**Milestone 0** — Enable MFA on root. Create a zero-spend AWS Budget. Do not click into IAM Identity Center. Pick one region and stay in it.

**Milestone 1** — As root: create IAM user `Ishaan-admin` with console access, no permissions. Create role `NorthbeamAdmin` with the MFA-conditioned custom trust policy and `AdministratorAccess`; set max session duration to 1 hour. As root, attach the `AssumeNorthbeamAdminOnly` inline policy to the user and enable the user's MFA device. Test assumption both without and with MFA.

**Milestone 2** — As `NorthbeamAdmin`: create an S3 bucket, upload a test object. Create `NorthbeamS3ReadOnly` with the split bucket/object ARNs. Create `TestRole` trusting `NorthbeamAdmin`, attach only that policy. Via CloudShell, assume it and run the read / write / list-buckets triad. Attach a temporary explicit-deny inline policy, re-test the read, then delete it.

**Milestone 3** — Create bucket `northbeam-shared-<ACCOUNT_ID>` with `Alpha/` and `Beta/` prefixes, one object in each. Create both developer roles trusting `NorthbeamAdmin`, tag each with `Project`. Create `NorthbeamProjectABAC` and attach it to both unchanged. Assume each and cross-test both prefixes.

**Milestone 4a** — Create CloudWatch log group `/northbeam/api-lite` first, copy its real ARN. Create `NorthbeamEC2InstanceRole` (service principal `ec2.amazonaws.com`) with the log-scoped policy. Launch a t3.micro with SSH restricted to My IP, the instance profile attached, and metadata version set to V2 only (token required). SSH in and verify with `curl -i` (expect 401, then 200) and `aws sts get-caller-identity`.

**Milestone 4b** — Register the OIDC identity provider (`https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`). Create `GitHubActionsDeploy` with the federated trust policy — decode a real token first to get the current `sub` format rather than copying any documented example. Add the workflow file, push to `main`.

**Milestone 5** — Create `NorthbeamDevBoundary` (managed policy). Create `NorthbeamDevSelfService` trusting `NorthbeamAdmin` with the three-statement policy. Run the three checkpoints: create without boundary (fails), with boundary (succeeds), then attach `AdministratorAccess` to the child and prove both denial mechanisms.

**Milestone 6** — Write and run all three scripts. Validate each by creating a deliberate violation, confirming detection, then cleaning up.

**Cleanup when finished:** terminate the EC2 instance (it generates continuous IMDS credential-refresh events and consumes free-tier hours), delete test roles and buckets, remove any test access keys.
