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
# northbeam-lite
Hands-on AWS IAM security project — MFA-gated STS, ABAC, OIDC federation, permissions boundaries, and audit automation. Single-account, cost-optimized learning build.
