# Foundry IQ knowledge for voice calls

Foundry IQ is deployed by default. All browser and telephony calls use a
Foundry prompt agent whose MCP tool retrieves grounded content from Azure AI
Search. The agent also receives a Fabric Data Agent retrieval tool and a
separate confirmed support-ticket function. Calls answer in French by default
and use the `fr-FR-DeniseNeural` voice.

## Architecture

```text
Browser or phone provider
  -> Container App
  -> Voice Live
  -> Foundry prompt agent
  -> Foundry IQ knowledge base MCP tool
  -> Azure AI Search index
  -> concise spoken response
```

The deployment creates a Basic Search service with local authentication
disabled, a Storage account and private Blob container, a Blob knowledge
source, a knowledge base, a `ProjectManagedIdentity` project connection, and
a prompt agent. The Blob knowledge source automatically creates and owns its
Search data source, skillset, index, and indexer. The indexer runs every five
minutes to incrementally ingest new or changed blobs.

The deployment also creates `text-embedding-3-large` and `gpt-5.2`
deployments for ingestion and answer synthesis, plus `gpt-4.1-mini` for the
prompt agent. Access between Storage, Search, Foundry, and the project uses
managed identities and RBAC; no storage key or Search key is used.

## Prerequisites and regions

The deploying principal needs Contributor and Role Based Access Control
Administrator permissions. The subscription must have quota for all model
deployments. Select a region that supports Voice Live, Azure AI Search,
Foundry Agent Service, Foundry IQ, `gpt-realtime-2.1`, `gpt-4.1-mini`,
`gpt-5.2`, and `text-embedding-3-large`.
Service and preview API availability can differ by region; verify the current
[Voice Live regions](https://learn.microsoft.com/azure/ai-services/speech-service/regions?tabs=voice-live),
[Foundry model availability](https://learn.microsoft.com/azure/ai-foundry/foundry-models/concepts/models-sold-directly-by-azure),
and [Foundry IQ documentation](https://learn.microsoft.com/azure/foundry/agents/concepts/what-is-foundry-iq)
before deployment.

Foundry IQ MCP integration currently uses the `2026-08-01-preview` Search API.
Review preview terms and compliance requirements before production use.

## Deploy

```shell
azd up
```

Optional settings:

| Setting | Default |
|---|---|
| `AZURE_AI_SEARCH_SERVICE_NAME` | Generated from the azd environment |
| `AZURE_STORAGE_ACCOUNT_NAME` | Generated from the azd environment |
| `AZURE_STORAGE_CONTAINER_NAME` | `aisindexer` |
| `AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME` | `call-center-knowledge` |
| `AZURE_FOUNDRY_IQ_CHAT_MODEL_NAME` | `gpt-5.2` |
| `AZURE_FOUNDRY_IQ_CHAT_MODEL_DEPLOYMENT` | `gpt-5.2` |
| `AZURE_FOUNDRY_IQ_CHAT_MODEL_CAPACITY` | `1000` (thousands of tokens/minute) |
| `AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_NAME` | `text-embedding-3-large` |
| `AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_DEPLOYMENT` | `text-embedding-3-large` |
| `AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_CAPACITY` | `3000` (thousands of tokens/minute) |
| `AZURE_AI_FOUNDRY_AGENT_ID` | `call-center-knowledge-agent` |
| `AZURE_AI_AGENT_MODEL_NAME` | `gpt-4.1-mini` |
| `AZURE_AI_AGENT_MODEL_VERSION` | `2025-04-14` |
| `AZURE_AI_AGENT_MODEL_DEPLOYMENT` | `gpt-4.1-mini` |
| `AZURE_AI_AGENT_MODEL_CAPACITY` | `15000` (thousands of tokens/minute) |
| `AZURE_VOICE_LIVE_VOICE` | `fr-FR-DeniseNeural` |

`azd up` grants the deploying user or workload identity the required Storage,
Search, and Foundry data-plane roles. The first post-provision hook creates
the Blob knowledge source and knowledge base. The second creates or updates
the Foundry agent that uses the Bicep-provisioned MCP project connection.
Repeated deployments reconcile the same named resources and create a new
agent version only when its definition changes. The generated managed Search
index name is saved as `AZURE_AI_SEARCH_INDEX_NAME` in the azd environment.

## Content ingestion

Upload supported documents to the provisioned container:

```shell
STORAGE_ACCOUNT=$(azd env get-value AZURE_STORAGE_ACCOUNT_NAME)
CONTAINER=$(azd env get-value AZURE_STORAGE_CONTAINER_NAME)

az storage blob upload-batch \
  --account-name "$STORAGE_ACCOUNT" \
  --destination "$CONTAINER" \
  --source ./content \
  --auth-mode login
```

The Search-managed indexer detects changes on its five-minute schedule,
extracts and chunks content, generates embeddings, and updates the managed
index. The deploying principal receives Storage Blob Data Contributor for
uploads. The Search managed identity receives Storage Blob Data Reader and
Cognitive Services User for ingestion.

## Validate independently

Get the deployed values:

```shell
SEARCH_ENDPOINT=$(azd env get-value AZURE_AI_SEARCH_ENDPOINT)
INDEX_NAME=$(azd env get-value AZURE_AI_SEARCH_INDEX_NAME)
KB_NAME=$(azd env get-value AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME)
STORAGE_ACCOUNT=$(azd env get-value AZURE_STORAGE_ACCOUNT_NAME)
CONTAINER=$(azd env get-value AZURE_STORAGE_CONTAINER_NAME)
PROJECT_ENDPOINT=$(azd env get-value AZURE_AI_FOUNDRY_PROJECT_ENDPOINT)
AGENT_NAME=$(azd env get-value AZURE_AI_FOUNDRY_AGENT_ID)
```

Check the index and knowledge base using Entra authentication:

```shell
az rest --method get \
  --url "$SEARCH_ENDPOINT/indexes/$INDEX_NAME?api-version=2024-07-01" \
  --resource https://search.azure.com

az rest --method get \
  --url "$SEARCH_ENDPOINT/knowledgebases/$KB_NAME?api-version=2026-08-01-preview" \
  --resource https://search.azure.com
```

In the Foundry portal, open the project, select the named agent, and ask
a question answered by one of your uploaded documents. Verify that the tool
trace contains `knowledge_base_retrieve`, that the answer is grounded in the
document, and that the answer is in French. Then ask an unrelated question
and verify that the agent says the knowledge base doesn't contain enough
information.

## Browser and phone validation

Open the Container App URL, start the browser call, and ask the two validation
questions above. For a real call, configure one supported provider using the
main README, dial its number, and repeat the questions. Both paths share the
same Voice Live handler and therefore the same Foundry agent selection.

Use `azd monitor --logs` and filter on `cid=` to correlate one call. Logs record
agent connection status, MCP/tool event type, latency, result count when the
service supplies it, empty-result status, and response latency. Application
Insights receives these structured logs. Audio, transcripts, retrieved text,
Search tokens, and document contents aren't logged by default.

## Troubleshooting

| Symptom | Action |
|---|---|
| Post-provision hook returns 401/403 | Confirm the identity running both `azd` and `az` has Search Service Contributor, Search Index Data Contributor, and Foundry User; allow time for RBAC propagation. |
| Hook cannot obtain an access token | Run `az login` with the same identity used by `azd`. In CI, authenticate both Azure CLI and `azd` with the workload identity. |
| Knowledge base is empty | Confirm blobs exist in `AZURE_STORAGE_CONTAINER_NAME`, wait for the five-minute schedule, and inspect the managed indexer execution history. |
| Blob/indexer ingestion fails | Check the knowledge-source status, indexer execution history, source firewall, and Search identity's source read role. |
| Agent tool returns 401/403 | Confirm the project identity has Search Index Data Reader and the connection uses `ProjectManagedIdentity` with the Search audience. |
| Agent doesn't call Foundry IQ | Confirm the `ENABLE_FOUNDRY_IQ` deployment output is `true`, the Container App agent/project settings, MCP URL, connection name, and `knowledge_base_retrieve` tool. |
| Model or API is unavailable | Choose a region and model version supported by Voice Live, Foundry Agent Service, Search, and the pinned APIs. |
| No answer for an uploaded document | Wait for Search RBAC propagation and the next indexer run, verify the managed index contains chunks, then rerun `azd provision` if the knowledge source is missing. |

## Authorization and cleanup

The included sample is shared organizational content. For user-specific
sources, don't rely only on agent instructions. Apply Search filters or
security trimming and pass a caller-scoped authorization token through
Foundry structured inputs after implementing an authenticated caller identity.
Never expose private indexed content to anonymous browser or PSTN callers.

`azd down` deletes the resource group, including Storage content, Search and
its managed ingestion objects, the Foundry connection and models, managed
identities, Container App, and monitoring resources.
