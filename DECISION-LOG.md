# Decision Log — Northbeam Lite

| # | Decision | Alternative rejected | Reasoning / cost |
| --- | --- | --- | --- |
| 1 | Single AWS account | Multi-account Organization (faithful to the Northbeam case study) | Joining an Organization expires all free-tier credits immediately and forces a paid plan. Cost: no SCPs, no account isolation — deferred to a later phase. |
| 2 | Free plan over paid plan | Paid plan with budget alarm | Learner budget; no charges possible. Cost: account auto-closes at 6 months or credit exhaustion. |
| 3 | Break-glass IAM user + MFA-gated role | IAM Identity Center | Identity Center's default setup path creates an Organization (see #1). Cost: less realistic for a real company; more instructive for learning trust policies by hand. |
| 4 | AdministratorAccess on NorthbeamAdmin | Narrowly scoped admin role | For a solo operator, the safety comes from the two trust gates and short sessions, not from action scoping. Cost: broad blast radius if MFA is ever compromised. |
| 5 | CloudShell CLI as canonical test environment | AWS Console | The console's Switch Role page had a reproducible JS bug (`TypeError: reading 'text'`) that never reached the STS API. Cost: none; the CLI is more evidence-rich anyway. |
| 6 | Role tags for ABAC, not session tags | Session tags passed at assume-time | Session tags can be self-asserted by the caller, defeating isolation. Role tags are admin-set and immutable to the assumer. |
| 7 | StringEquals on OIDC `sub`, corrected value | StringLike wildcard | The wildcard would have "fixed" the failure by weakening the condition without diagnosing it. Decoding the real token preserved the original tightness. |
| 8 | Tightened permissions boundary to specific actions | `s3:*` / `dynamodb:*` / `lambda:*` | A wide ceiling gives no protection if the underlying policy is also careless — the intersection is only as narrow as the narrower of the two. Cost: boundary needs editing when genuinely new actions are required. |
| 9 | Inline policy on NorthbeamEC2InstanceRole | Customer-managed policy | Expedient during the build; acknowledged as the wrong choice — a managed policy is reusable and versioned. Flagged for correction in the Terraform phase. |
| 10 | No S3-backed CloudTrail trail | Full trail with data events | Cost. Consequence: 90-day retention limit and no object-level visibility, both of which were then discovered empirically in M6. |
| 11 | Region sprawl (eu-north-1, us-east-1) | One consistent region | Unintentional — a genuine mistake. Resources ended up split across regions during the build. In a real environment this fragments logging, complicates cost attribution, and is exactly what an SCP region restriction exists to prevent. |
| 12 | Validated audit scripts by creating deliberate violations | Trusting a clean scan result | A detector that has never fired is indistinguishable from a broken detector. |
