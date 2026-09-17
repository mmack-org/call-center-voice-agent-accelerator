# Foundry IQ knowledge for voice calls

Foundry IQ is optional. When enabled, all browser and telephony calls use a
Foundry prompt agent whose MCP tool retrieves grounded content from Azure AI
Search. When disabled (the default), calls continue to use the GPT Realtime
deployment directly.

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
disabled, a sample index and knowledge source, a knowledge base, a
`ProjectManagedIdentity` project connection, and a prompt agent. It also
deploys `gpt-4.1-mini` for the prompt agent. The sample uses direct document
upload, so it doesn't need a data source, indexer, or skillset. Source types
such as Blob Storage can create and manage those ingestion resources through
their Foundry IQ knowledge-source definition.

## Prerequisites and regions

The deploying principal needs Contributor and Role Based Access Control
Administrator permissions. The subscription must have quota for both model
deployments. Select a region that supports Voice Live, Azure AI Search,
Foundry Agent Service, Foundry IQ, `gpt-realtime-2.1`, and `gpt-4.1-mini`.
Service and preview API availability can differ by region; verify the current
[Voice Live regions](https://learn.microsoft.com/azure/ai-services/speech-service/regions?tabs=voice-live),
[Foundry model availability](https://learn.microsoft.com/azure/ai-foundry/foundry-models/concepts/models-sold-directly-by-azure),
and [Foundry IQ documentation](https://learn.microsoft.com/azure/foundry/agents/concepts/what-is-foundry-iq)
before deployment.

Foundry IQ MCP integration currently uses the `2026-08-01-preview` Search API.
Review preview terms and compliance requirements before production use.

## Deploy

```shell
azd env set ENABLE_FOUNDRY_IQ true
azd up
```

Optional settings:

| Setting | Default |
|---|---|
| `AZURE_AI_SEARCH_SERVICE_NAME` | Generated from the azd environment |
| `AZURE_AI_SEARCH_INDEX_NAME` | `call-center-content` |
| `AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME` | `call-center-knowledge` |
| `AZURE_AI_FOUNDRY_AGENT_ID` | `call-center-knowledge-agent` |
| `AZURE_AI_AGENT_MODEL_NAME` | `gpt-4.1-mini` |
| `AZURE_AI_AGENT_MODEL_VERSION` | `2025-04-14` |
| `AZURE_AI_AGENT_MODEL_DEPLOYMENT` | `gpt-4.1-mini` |

`azd up` uses an isolated deployment identity to create or update the index,
sample documents, knowledge source, knowledge base, connection, and agent.
Repeated deployments merge the same sample document IDs and reuse the named
agent. Stable names and endpoints are saved in the azd environment. No Search
keys or other secrets are used or written to Container App settings.

To return to direct-model mode:

```shell
azd env set ENABLE_FOUNDRY_IQ false
azd provision
azd deploy
```

## Sample content and ingestion

The sample index contains:

- support hours: Monday-Friday, 8:00 AM-6:00 PM Eastern Time
- return policy: unused products with a receipt can be returned within 30 days

For production content, replace the sample index upload and `searchIndex`
knowledge source in `infra/scripts/provision-foundry-iq.sh` with a supported
Foundry IQ source. Use managed-identity resource IDs for Blob Storage or other
Azure sources, grant only the source read role to the Search identity, and
monitor generated indexer status. Don't place connection strings or keys in
the script.

## Validate independently

Get the deployed values:

```shell
SEARCH_ENDPOINT=$(azd env get-value AZURE_AI_SEARCH_ENDPOINT)
INDEX_NAME=$(azd env get-value AZURE_AI_SEARCH_INDEX_NAME)
KB_NAME=$(azd env get-value AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME)
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
“When is customer support available?” Verify that the tool trace contains
`knowledge_base_retrieve`. Then ask an unrelated question and verify that the
agent says the knowledge base doesn't contain enough information.

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
| Deployment script returns 401/403 | Confirm its managed identity has Search Service Contributor, Search Index Data Contributor, and Foundry User; allow time for RBAC propagation. |
| Knowledge base is empty | Check that the two sample documents exist in the index and that `call-center-content` is referenced by the knowledge source. |
| Blob/indexer ingestion fails | Check the knowledge-source status, indexer execution history, source firewall, and Search identity's source read role. |
| Agent tool returns 401/403 | Confirm the project identity has Search Index Data Reader and the connection uses `ProjectManagedIdentity` with the Search audience. |
| Agent doesn't call Foundry IQ | Confirm `ENABLE_FOUNDRY_IQ=true`, the Container App agent/project settings, MCP URL, connection name, and `knowledge_base_retrieve` tool. |
| Model or API is unavailable | Choose a region and model version supported by Voice Live, Foundry Agent Service, Search, and the pinned APIs. |
| No answer for sample question | Wait for Search RBAC propagation, verify the index documents, then recreate the knowledge source/base by running `azd provision`. |

## Authorization and cleanup

The included sample is shared organizational content. For user-specific
sources, don't rely only on agent instructions. Apply Search filters or
security trimming and pass a caller-scoped authorization token through
Foundry structured inputs after implementing an authenticated caller identity.
Never expose private indexed content to anonymous browser or PSTN callers.

`azd down` deletes the resource group, including Search, its indexes and
knowledge objects, the Foundry connection and models, managed identities,
Container App, monitoring resources, and sample data.
