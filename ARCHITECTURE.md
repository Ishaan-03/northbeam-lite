# Architecture — Northbeam Lite

Diagrams are written in Mermaid and rendered natively by GitHub.

## Overall architecture

```mermaid
graph TB
    subgraph human["Human access path"]
        ROOT["Root user<br/>MFA-locked, near-zero use"]
        USER["IAM user: Ishaan-admin<br/>sts:AssumeRole only"]
        ADMIN["Role: NorthbeamAdmin<br/>AdministratorAccess<br/>MFA-conditioned trust"]
    end

    subgraph scoped["Scoped identities"]
        TEST["TestRole<br/>NorthbeamS3ReadOnly"]
        ALPHA["NorthbeamDeveloper-Alpha<br/>tag: Project=Alpha"]
        BETA["NorthbeamDeveloper-Beta<br/>tag: Project=Beta"]
        SELF["NorthbeamDevSelfService<br/>delegated role creation"]
    end

    subgraph machine["Machine identities — no stored credentials"]
        EC2["NorthbeamEC2InstanceRole<br/>IMDSv2 enforced"]
        OIDC["GitHubActionsDeploy<br/>OIDC federated"]
    end

    subgraph data["Resources"]
        B1["S3: northbeam-dev-data"]
        B2["S3: northbeam-shared<br/>Alpha/ and Beta/ prefixes"]
        LOGS["CloudWatch<br//northbeam/api-lite"]
    end

    ROOT -.->|bootstrap only| USER
    USER -->|AssumeRole + MFA| ADMIN
    ADMIN -->|role chaining| TEST
    ADMIN -->|role chaining| ALPHA
    ADMIN -->|role chaining| BETA
    ADMIN -->|role chaining| SELF
    TEST --> B1
    ALPHA -->|Alpha/* only| B2
    BETA -->|Beta/* only| B2
    EC2 --> LOGS
```

## Milestone 1 — MFA-gated assumption

```mermaid
sequenceDiagram
    participant U as Ishaan-admin
    participant STS as AWS STS
    participant R as NorthbeamAdmin

    U->>STS: AssumeRole (no MFA in session)
    STS->>R: check trust policy condition
    R-->>STS: aws:MultiFactorAuthPresent = false
    STS-->>U: ❌ Denied

    Note over U: user enables MFA, re-authenticates

    U->>STS: AssumeRole (MFA present)
    STS->>R: check trust policy condition
    R-->>STS: condition satisfied
    STS-->>U: ✅ Temporary credentials (1h max)
```

## Milestone 2 — policy evaluation order

```mermaid
graph TD
    REQ["API request"] --> DD["Default deny<br/>baseline"]
    DD --> ED{"Explicit<br/>Deny?"}
    ED -->|Yes| DENY["❌ DENIED<br/>always wins"]
    ED -->|No| EA{"Explicit<br/>Allow?"}
    EA -->|Yes| ALLOW["✅ ALLOWED"]
    EA -->|No| DENY2["❌ DENIED<br/>default"]
```

## Milestone 3 — ABAC resolution

```mermaid
graph LR
    subgraph roles["Two roles, permanent admin-set tags"]
        A["NorthbeamDeveloper-Alpha<br/>Project=Alpha"]
        B["NorthbeamDeveloper-Beta<br/>Project=Beta"]
    end

    P["Shared policy<br/>NorthbeamProjectABAC<br/><br/>Resource:<br/>bucket/${aws:PrincipalTag/Project}/*"]

    A --> P
    B --> P

    P -->|resolves to Alpha/*| RA["✅ Alpha/alpha-secret.txt"]
    P -->|resolves to Beta/*| RB["✅ Beta/beta-secret.txt"]
    P -.->|Alpha session| XB["❌ Beta/* — 403"]
```

## Milestone 4a — IMDSv2 flow

```mermaid
sequenceDiagram
    participant APP as App / SDK on EC2
    participant IMDS as IMDS 169.254.169.254
    participant ROLE as NorthbeamEC2InstanceRole

    APP->>IMDS: GET /meta-data/ (no token)
    IMDS-->>APP: ❌ 401 Unauthorized

    APP->>IMDS: PUT /latest/api/token
    IMDS-->>APP: session token (TTL 21600s)
    APP->>IMDS: GET /iam/security-credentials/ + token
    IMDS->>ROLE: fetch temporary credentials
    ROLE-->>IMDS: short-lived creds
    IMDS-->>APP: ✅ 200 OK + credentials
```

## Milestone 4b — GitHub OIDC exchange

```mermaid
sequenceDiagram
    participant GH as GitHub Actions runner
    participant ISS as GitHub OIDC issuer
    participant STS as AWS STS
    participant ROLE as GitHubActionsDeploy

    GH->>ISS: request ID token (id-token: write)
    ISS-->>GH: signed JWT<br/>sub = repo:owner@ID/repo@ID:ref:refs/heads/main
    GH->>STS: AssumeRoleWithWebIdentity + JWT
    STS->>STS: verify signature vs GitHub public keys
    STS->>ROLE: check sub + aud conditions
    ROLE-->>STS: match
    STS-->>GH: ✅ temporary credentials
```

## Milestone 5 — permissions boundary intersection

```mermaid
graph TB
    SELF["NorthbeamDevSelfService<br/>(no boundary of its own)"]
    SELF -->|"iam:CreateRole<br/>CONDITION: boundary must be attached"| CHECK{"Boundary<br/>specified?"}
    CHECK -->|No| FAIL["❌ AccessDenied<br/>condition unmatched"]
    CHECK -->|Yes| CREATED["northbeam-dev-test created"]

    CREATED --> POL["Identity policy:<br/>AdministratorAccess<br/>(everything)"]
    CREATED --> BOUND["Boundary:<br/>NorthbeamDevBoundary<br/>(8 actions, iam:* denied)"]

    POL --> INT["EFFECTIVE PERMISSIONS<br/>= intersection"]
    BOUND --> INT

    INT --> R1["❌ s3:ListAllMyBuckets<br/>not in boundary allow list"]
    INT --> R2["❌ iam:ListUsers<br/>explicit deny in boundary"]
    INT --> R3["✅ s3:GetObject<br/>allowed by both"]
```

## Milestone 6 — two audit lenses

```mermaid
graph TB
    subgraph dormant["Lens 1 — dormant risk (static)"]
        S1["keyaudit.sh<br/>access keys > 90 days"]
        S2["roleaudit.sh<br/>RoleLastUsed = NEVER"]
    end

    subgraph behavior["Lens 2 — behavioral risk (CloudTrail)"]
        S3["cloudtrailaudit.sh<br/>AccessDenied events"]
    end

    S1 --> F1["Finds: credentials that<br/>could be abused but<br/>generate no logs"]
    S2 --> F1
    S3 --> F2["Finds: what was<br/>actually attempted"]

    F1 --> WHY["Neither lens alone is sufficient:<br/>an unused admin role produces<br/>zero CloudTrail events"]
    F2 --> WHY
```
