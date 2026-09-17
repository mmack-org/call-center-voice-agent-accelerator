#!/usr/bin/env bash
set -euo pipefail

search_api_version="2026-08-01-preview"
index_api_version="2024-07-01"
mcp_endpoint="${SEARCH_ENDPOINT}/knowledgebases/${KNOWLEDGE_BASE_NAME}/mcp?api-version=${search_api_version}"

search_token="$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)"
foundry_token="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)"

put_search_object() {
  local path="$1"
  local body="$2"
  local attempts=0

  until curl --fail-with-body --silent --show-error \
    --request PUT "${SEARCH_ENDPOINT}/${path}?api-version=${search_api_version}" \
    --oauth2-bearer "${search_token}" \
    --header "Content-Type: application/json" \
    --data "${body}" >/dev/null; do
    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 12 ]]; then
      return 1
    fi
    sleep 10
  done
}

index_body="$(jq -n \
  --arg name "${SEARCH_INDEX_NAME}" \
  '{
    name: $name,
    fields: [
      {name: "id", type: "Edm.String", key: true, filterable: true},
      {name: "title", type: "Edm.String", searchable: true, retrievable: true},
      {name: "content", type: "Edm.String", searchable: true, retrievable: true},
      {name: "source", type: "Edm.String", filterable: true, retrievable: true}
    ],
    semantic: {
      defaultConfiguration: "default",
      configurations: [{
        name: "default",
        prioritizedFields: {
          titleField: {fieldName: "title"},
          prioritizedContentFields: [{fieldName: "content"}],
          prioritizedKeywordsFields: []
        }
      }]
    }
  }')"

put_search_object "indexes/${SEARCH_INDEX_NAME}" "${index_body}"

documents_body='{
  "value": [
    {
      "@search.action": "mergeOrUpload",
      "id": "support-hours",
      "title": "Customer support hours",
      "content": "Customer support is available Monday through Friday from 8:00 AM to 6:00 PM Eastern Time, excluding public holidays.",
      "source": "sample/support-hours"
    },
    {
      "@search.action": "mergeOrUpload",
      "id": "return-policy",
      "title": "Return policy",
      "content": "Unused products can be returned within 30 calendar days of delivery when the original receipt is available.",
      "source": "sample/return-policy"
    }
  ]
}'

curl --fail-with-body --silent --show-error \
  --request POST "${SEARCH_ENDPOINT}/indexes/${SEARCH_INDEX_NAME}/docs/index?api-version=${index_api_version}" \
  --oauth2-bearer "${search_token}" \
  --header "Content-Type: application/json" \
  --data "${documents_body}" >/dev/null

knowledge_source_body="$(jq -n \
  --arg name "${KNOWLEDGE_SOURCE_NAME}" \
  --arg index "${SEARCH_INDEX_NAME}" \
  '{
    name: $name,
    kind: "searchIndex",
    description: "Sample organizational content for the call center voice agent.",
    searchIndexParameters: {
      searchIndexName: $index,
      semanticConfigurationName: "default",
      searchFields: [{name: "title"}, {name: "content"}],
      sourceDataFields: [{name: "title"}, {name: "content"}, {name: "source"}]
    }
  }')"
put_search_object "knowledgesources/${KNOWLEDGE_SOURCE_NAME}" "${knowledge_source_body}"

knowledge_base_body="$(jq -n \
  --arg name "${KNOWLEDGE_BASE_NAME}" \
  --arg source "${KNOWLEDGE_SOURCE_NAME}" \
  '{
    name: $name,
    description: "Grounded knowledge for the call center voice agent.",
    retrievalInstructions: "Retrieve only content relevant to the caller question.",
    outputMode: "extractiveData",
    knowledgeSources: [{name: $source}],
    retrievalReasoningEffort: {kind: "minimal"}
  }')"
put_search_object "knowledgebases/${KNOWLEDGE_BASE_NAME}" "${knowledge_base_body}"

agent_url="${PROJECT_ENDPOINT}/agents/${AGENT_NAME}?api-version=v1"
agent_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --oauth2-bearer "${foundry_token}" "${agent_url}")"

if [[ "${agent_status}" == "404" ]]; then
  agent_body="$(jq -n \
    --arg name "${AGENT_NAME}" \
    --arg model "${AGENT_MODEL_DEPLOYMENT}" \
    --arg server_url "${mcp_endpoint}" \
    --arg connection "${PROJECT_CONNECTION_NAME}" \
    '{
      name: $name,
      definition: {
        kind: "prompt",
        model: $model,
        instructions: "Use the knowledge base tool for every content question. Ground every factual answer in retrieved content and never use unsupported model knowledge. If the knowledge base does not contain enough information, say so explicitly. Keep answers short and natural for a phone conversation. Do not read URLs, source IDs, or citation syntax aloud.",
        tools: [{
          type: "mcp",
          server_label: "knowledge-base",
          server_url: $server_url,
          project_connection_id: $connection,
          require_approval: "never",
          allowed_tools: ["knowledge_base_retrieve"]
        }]
      }
    }')"

  curl --fail-with-body --silent --show-error \
    --request POST "${PROJECT_ENDPOINT}/agents?api-version=v1" \
    --oauth2-bearer "${foundry_token}" \
    --header "Content-Type: application/json" \
    --data "${agent_body}" >/dev/null
elif [[ "${agent_status}" != "200" ]]; then
  echo "Unable to query Foundry agent '${AGENT_NAME}' (HTTP ${agent_status})." >&2
  exit 1
fi

jq -n \
  --arg agentName "${AGENT_NAME}" \
  --arg knowledgeBaseName "${KNOWLEDGE_BASE_NAME}" \
  '{agentName: $agentName, knowledgeBaseName: $knowledgeBaseName}' \
  >"${AZ_SCRIPTS_OUTPUT_PATH}"
