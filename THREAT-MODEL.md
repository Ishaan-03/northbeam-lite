# Threat Model — Northbeam Lite

## Threats this project defends against

| Threat | Control | Evidence |
| --- | --- | --- |
| Leaked long-lived admin credential | No standing admin credential exists; admin only reachable via MFA-gated STS with 1h sessions | M1 — assumption without MFA refused |
| Stolen session token | Bounded by MaxSessionDuration (1 hour), expires without human intervention | M1 |
| Over-broad S3 grant | Explicitly scoped bucket + object ARNs; verified that adjacent actions fail | M2 — PutObject and ListAllMyBuckets both denied |
| Policy conflict / accidental grant | Explicit deny precedence verified on live infrastructure | M2 |
| Cross-project data access | ABAC tags set by admin, not self-asserted; enforced per-request | M3 — Alpha session denied on Beta prefix |
| Credential theft via SSRF (Capital One pattern) | IMDSv2 required; unauthenticated GET refused | M4a — 401 vs 200 |
| CI/CD secret compromise | Zero secrets stored in GitHub; per-run signed tokens scoped to one repo + branch | M4b |
| Repo/username hijack after rename | `sub` bound to immutable numeric owner and repo IDs | M4b |
| Developer privilege escalation via self-created roles | Permissions boundary enforced at creation, cannot be removed or swapped | M5 — AdministratorAccess neutralized |
| Credential and permission drift over time | Scripted detection of stale keys, unused roles, denied-action patterns | M6 |

## Threats this project explicitly does NOT defend against

| Threat | Why not | Where it belongs |
| --- | --- | --- |
| Account-level compromise (root) | Root is unrestrictable by design | Multi-account isolation |
| An admin disabling CloudTrail | No SCP layer exists in a standalone account | Organizations + SCP |
| Attacker deleting audit logs | Logs live in the same account they record | Dedicated logging account |
| Blast radius across environments | Dev and prod share one account | Account separation |
| Region-based abuse (e.g. crypto mining in unused regions) | No region restriction enforced | SCP |
| Object-level exfiltration detection | CloudTrail data events not enabled (cost) | Paid data-event trail |

Being explicit about the second table is deliberate. A threat model that only lists wins is marketing, not engineering.
