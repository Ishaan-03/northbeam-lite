# Limitations — what a reviewer should know before evaluating this repository

This is Phase 1 of a longer roadmap. It covers IAM specifically. Networking (VPC), data protection (KMS, Secrets Manager), detection (GuardDuty, Security Hub, Config), IaC (Terraform), and containers are separate later phases and are intentionally absent.

## Known gaps, stated plainly

- **No multi-account isolation.** Everything shares one account and one blast radius.
- **No SCPs.** The organization-wide ceiling layer does not exist here.
- **Logs are not tamper-proof.** CloudTrail records into the same account it monitors. A sufficiently privileged compromise could alter or stop it.
- **AdministratorAccess in use.** NorthbeamAdmin is intentionally broad; the compensating controls are MFA and short sessions, not least privilege on actions.
- **One inline policy that should be managed** (NorthbeamEC2InstanceRole) — see decision log #9.
- **Region sprawl** — see decision log #11.
- **Nothing is Infrastructure as Code.** Every resource was created by hand, deliberately, to build console and CLI fluency first. Terraform is Phase 6, and re-implementing this project as IaC is the planned follow-up.
- **The audit scripts are demonstrations, not production tooling.** No error handling, no pagination handling for large accounts, no scheduled execution, no alerting integration.
- **Positive-path logging was never exercised.** The EC2 role has `logs:PutLogEvents` permission, but no log event was ever actually written — only the permission and credential path were verified.

## What the author would do differently with a real budget

Build it as a three-account Organization (management / logging / workload) with Control Tower, Identity Center for human access, an SCP denying CloudTrail modification and restricting regions to eu-west-1 and eu-west-3, and provision the whole thing with Terraform scanned by tfsec and checkov in CI.
