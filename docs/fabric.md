# Microsoft Fabric operations

Every `azd up` deploys an F2 Microsoft Fabric capacity and idempotently creates
a workspace, workspace identity, schema-enabled Lakehouse, ingestion notebook,
Fabric Data Agent, and Foundry project connection. Fabric and Foundry IQ are
both mandatory deployment components.

## Prerequisites

- The subscription must be allowed to create `Microsoft.Fabric/capacities`.
- The tenant administrator must enable service principals and workspace
  identities for Fabric APIs.
- The deploying identity needs Azure Contributor/RBAC permissions, Fabric
  workspace creation permission, and capacity administrator permission.
- `FABRIC_LOCATION` must support the selected SKU and Fabric Data Agent preview.
  Fabric IQ, ontology, and Data Agent availability and APIs vary by region.
- The deployment identity's UPN is used as `FABRIC_CAPACITY_ADMIN` unless it is
  set explicitly. Workload identities must set it explicitly.

These tenant settings and preview/region constraints cannot be automated by the
template.

## Configuration

| azd setting | Default | Purpose |
|---|---|---|
| `FABRIC_LOCATION` | `AZURE_LOCATION` | Capacity region |
| `FABRIC_CAPACITY_SKU` | `F2` | Capacity SKU |
| `FABRIC_CAPACITY_ADMIN` | Current Azure user | Capacity administrator UPN |
| `FABRIC_WORKSPACE_NAME` | Deterministic | Workspace display name |
| `FABRIC_LAKEHOUSE_NAME` | `call_center` | Lakehouse display name |
| `FABRIC_DATA_AGENT_NAME` | `call-center-data-agent` | Read-only retrieval agent |
| `FABRIC_TICKET_WRITE_ENDPOINT` | none | Approved Fabric User Data Function or transactional ticket API |

The deployment writes workspace, Lakehouse, notebook, Data Agent, and connection
IDs back to the azd environment. No passwords, keys, or Fabric tokens are stored.

## Load data

Place the supplied SAVOYE-IQ files under the Lakehouse `Files/raw/` directory:

- `products.csv`, `ranges.csv`, `customers.csv`, `contacts.csv`, `agents.csv`
- `documents.csv`, `installed-base.csv`, and `tickets-savoye.jsonl`
- referenced Markdown documents

Run the `ingest-call-center-data` notebook. It uses explicit schemas and casts,
Delta/V-Order, and creates Bronze, Silver, and Gold tables. The Gold model
contains products, ranges, customers, agents, dates, documents, installed base,
tickets, ticket tags, parts, and escalations. Contact details and free-form
messages remain in Silver and must not be added to shared semantic models.

The notebook fails on foreign-key, installed-base, cost, SLA, chronology,
message-count, and equipment-count violations. It also validates the supplied
mock baseline (2,851 tickets, 12,675 messages, 1,675 parts, 357 escalations, and
2,035 CSAT ratings). `is_mock_data` is retained on every ticket.

## Semantic model and ontology

Create a Direct Lake semantic model over the `gold` schema. Apply customer-level
RLS to every customer-related table. Exclude `silver.dim_customer_contact`,
`silver.fact_ticket_message`, `csat_comment`, email, and phone from shared
models. Create these relationships:

- Customer to installed products and tickets
- Product to range, documentation, installed base, tickets, and parts
- Ticket to customer, product, requester, assigned agent, tags, parts, messages,
  and escalation
- Agent to assigned tickets

Build and publish an ontology from that semantic model, then verify the
provisioned Data Agent uses it. Semantic-model and ontology definition APIs are
preview features and their serialized definitions are tenant-generated; the
deployment intentionally does not overwrite unrelated or tenant-authored
definitions.

## Retrieval and ticket creation

The Foundry agent has a `fabric_dataagent_preview` read tool. Agent instructions
require exact customer scope and prohibit email, phone, message bodies, and CSAT
comments. Application-side `FabricToolService` independently validates keys,
removes protected fields, rejects cross-customer records, and logs only tool
name, outcome, latency, result count, and correlation ID.

Ticket creation is a separate function. Configure
`FABRIC_TICKET_WRITE_ENDPOINT` with a managed-identity protected Fabric User
Data Function or transactional API that:

1. revalidates the customer and installed-product relationship;
2. rejects `user_confirmed=false`;
3. atomically enforces a unique idempotency key;
4. generates the ticket ID, timestamps, status, and audit identity server-side;
5. appends the ticket and an audit event without storing conversation content.

The application rejects arbitrary fields, SQL, invalid priorities, ambiguous
confirmation, cross-customer requests, and malformed references before calling
that endpoint. Separate the Data Agent read identity from the function's write
identity and grant each only the required Fabric item permissions.

## Validation and smoke test

```bash
bicep build infra/main.bicep
pwsh ./hooks/deploy-fabric.ps1
cd server
uv run python -m unittest discover -s tests
```

In Fabric, run the ingestion notebook and verify all checks pass. Then test:
customer/SLA retrieval, installed products, a customer-scoped ticket, similar
resolved cases, a no-result query, refusal before confirmation, one confirmed
creation, and an idempotent retry.

## Operations, rollback, and cleanup

Monitor Fabric capacity utilization, notebook runs, Data Agent failures, tool
latency, empty results, ticket-write failures, and duplicate attempts. Pause the
capacity to stop compute charges. Roll back notebook or model definitions
through source control; Delta time travel can recover tables. For cleanup, use
`azd down` for ARM resources, then delete the Fabric workspace only after
retention/export review because workspace artifacts are data-plane resources.
