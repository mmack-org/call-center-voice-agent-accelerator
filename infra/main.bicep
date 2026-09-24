targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources. The pre-provision hook validates the selected realtime model and version against the current Azure model inventory.')
@allowed([
  'australiaeast'
  'brazilsouth'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'norwayeast'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'swedencentral'
  'switzerlandnorth'
  'uksouth'
  'westeurope'
  'westus'
  'westus2'
  'westus3'
])
param location string

param appExists bool
@description('Object ID of the user or service principal running azd.')
param principalId string
@description('Microsoft Entra principal type of the identity running azd.')
@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string
@description('Foundry catalog model name. Override together with modelVersion when selecting another release.')
param modelName string = 'gpt-realtime-2.1'
@description('Foundry catalog model version.')
param modelVersion string = '2026-07-07'
@minLength(1)
@maxLength(64)
@description('Deployment name passed to the Voice Live realtime API.')
param modelDeploymentName string = 'gpt-realtime'
@description('Azure Speech voice used by Voice Live. The default voice speaks French.')
param voiceName string = 'fr-FR-DeniseNeural'
@description('Foundry deployment SKU.')
param modelSkuName string = 'GlobalStandard'
@minValue(1)
@description('Deployment capacity in thousands of tokens per minute.')
param modelCapacity int = 10
@description('The selected telephony provider')
@allowed(['acs', 'twilio', 'infobip', 'genesys', 'sinch', 'bandwidth'])
param telephonyProvider string = 'acs'
@secure()
@description('Twilio Auth Token for webhook signature validation')
param twilioAuthToken string = ''
@secure()
@description('Infobip API Key for voice call handling')
param infobipApiKey string = ''
@description('Infobip API Base URL (e.g. https://xxxxx.api.infobip.com)')
param infobipApiBaseUrl string = ''
@secure()
@description('Genesys AudioHook API Key for Audio Connector authentication')
param genesysApiKey string = ''
@secure()
@description('Sinch Application Key for callback signature validation and WebSocket auth')
param sinchApplicationKey string = ''
@secure()
@description('Sinch Application Secret for callback signature validation')
param sinchApplicationSecret string = ''
@secure()
@description('Bandwidth OAuth 2.0 Client ID (used for API auth and webhook Basic Auth)')
param bandwidthClientId string = ''
@secure()
@description('Bandwidth OAuth 2.0 Client Secret (used for API auth and webhook Basic Auth)')
param bandwidthClientSecret string = ''
@description('Bandwidth account ID (required in the API path for all calls)')
param bandwidthAccountId string = ''
@description('Bandwidth Voice Application ID (auto-populated by postdeploy if empty)')
param bandwidthApplicationId string = ''
@description('Enable debug mode for verbose logging in the container app')
param debugMode bool = false
@description('Azure AI Search service name. Leave empty to generate a deterministic name.')
param searchServiceName string = ''
@description('Storage account used as the Foundry IQ content source. Leave empty to generate a deterministic name.')
param foundryIqStorageAccountName string = ''
@description('Blob container automatically indexed by Foundry IQ.')
param foundryIqStorageContainerName string = 'aisindexer'
@description('Foundry IQ knowledge base name.')
param foundryIqKnowledgeBaseName string = 'call-center-knowledge'
@description('Foundry agent name used by Voice Live when Foundry IQ is enabled.')
param foundryAgentName string = 'call-center-knowledge-agent'
@description('Foundry catalog model used by the prompt agent.')
param agentModelName string = 'gpt-4.1-mini'
@description('Foundry prompt-agent model version.')
param agentModelVersion string = '2025-04-14'
@description('Deployment name for the Foundry prompt-agent model.')
param agentModelDeploymentName string = 'gpt-4.1-mini'
@description('Foundry prompt-agent deployment SKU.')
param agentModelSkuName string = 'GlobalStandard'
@minValue(1)
@description('Foundry prompt-agent deployment capacity in thousands of tokens per minute.')
param agentModelCapacity int = 15000
@description('Chat model used for Foundry IQ content extraction and answer synthesis.')
param foundryIqChatModelName string = 'gpt-5.2'
@description('Deployment name of the Foundry IQ content extraction model.')
param foundryIqChatModelDeploymentName string = 'gpt-5.2'
@minValue(10)
@description('Foundry IQ chat deployment capacity in thousands of tokens per minute.')
param foundryIqChatModelCapacity int = 1000
@description('Embedding model used by the Foundry IQ ingestion pipeline.')
param foundryIqEmbeddingModelName string = 'text-embedding-3-large'
@description('Deployment name of the Foundry IQ embedding model.')
param foundryIqEmbeddingModelDeploymentName string = 'text-embedding-3-large'
@minValue(10)
@description('Foundry IQ embedding deployment capacity in thousands of tokens per minute.')
param foundryIqEmbeddingModelCapacity int = 3000
@description('Microsoft Fabric capacity location. It must support the selected Fabric SKU.')
param fabricLocation string = location
@description('Microsoft Fabric capacity SKU.')
param fabricCapacitySku string = 'F2'
@description('Microsoft Fabric capacity administrator UPN.')
param fabricCapacityAdmin string
@description('Microsoft Fabric workspace display name. Leave empty to generate a deterministic name.')
param fabricWorkspaceName string = ''
@description('Microsoft Fabric Lakehouse display name.')
param fabricLakehouseName string = 'call_center'
@description('Microsoft Fabric Data Agent display name.')
param fabricDataAgentName string = 'call-center-data-agent'
@description('Authenticated customer scope for single-tenant demo sessions. Leave empty to disable ticket writes until an identity layer supplies it.')
param authorizedCustomerKey string = ''

var uniqueSuffix = substring(uniqueString(subscription().id, environmentName), 0, 5)
var tags = {
  'azd-env-name': environmentName
  SecurityControl: 'Ignore'
}
var rgName = 'rg-${environmentName}-${uniqueSuffix}'

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: rgName
  location: location
  tags: tags
}

// [ User Assigned Identity for App to avoid circular dependency ]
module appIdentity './modules/identity.bicep' = {
  name: 'uami'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
  }
}

module fabricReadIdentity './modules/identity.bicep' = {
  name: 'fabric-read-uami'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
    purpose: 'fabric-read'
  }
}

module fabricWriteIdentity './modules/identity.bicep' = {
  name: 'fabric-write-uami'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
    purpose: 'fabric-write'
  }
}

var sanitizedEnvName = toLower(replace(replace(replace(environmentName, ' ', '-'), '--', '-'), '_', '-'))
var logAnalyticsName = take('log-${sanitizedEnvName}-${uniqueSuffix}', 63)
var appInsightsName = take('insights-${sanitizedEnvName}-${uniqueSuffix}', 63)
module monitoring 'modules/monitoring/monitor.bicep' = {
  name: 'monitor'
  scope: rg
  params: {
    logAnalyticsName: logAnalyticsName
    appInsightsName: appInsightsName
    tags: tags
  }
}

module registry 'modules/containerregistry.bicep' = {
  name: 'registry'
  scope: rg
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    identityName: appIdentity.outputs.name
    tags: tags
  }
}


module aiServices 'modules/aiservices.bicep' = {
  name: 'ai-foundry-deployment'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
    identityId: appIdentity.outputs.identityId
    modelName: modelName
    modelVersion: modelVersion
    modelDeploymentName: modelDeploymentName
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    tags: tags
  }
}

var generatedSearchServiceName = take(toLower(replace('srch-${environmentName}-${uniqueSuffix}', '_', '-')), 60)
var foundryIqStorageNamePrefix = take(toLower(replace(replace(replace('st${environmentName}', '-', ''), '_', ''), ' ', '')), 24 - length(uniqueSuffix))
var generatedFoundryIqStorageAccountName = '${foundryIqStorageNamePrefix}${uniqueSuffix}'
module foundryIq 'modules/foundryiq.bicep' = {
  name: 'foundry-iq'
  scope: rg
  params: {
    location: location
    tags: tags
    aiServicesName: aiServices.outputs.aiServicesName
    aiServicesId: aiServices.outputs.aiServicesId
    projectName: aiServices.outputs.projectName
    projectEndpoint: aiServices.outputs.projectEndpoint
    projectPrincipalId: aiServices.outputs.projectPrincipalId
    deploymentPrincipalId: principalId
    deploymentPrincipalType: principalType
    storageAccountName: empty(foundryIqStorageAccountName) ? generatedFoundryIqStorageAccountName : foundryIqStorageAccountName
    storageContainerName: foundryIqStorageContainerName
    agentModelName: agentModelName
    agentModelVersion: agentModelVersion
    agentModelDeploymentName: agentModelDeploymentName
    agentModelSkuName: agentModelSkuName
    agentModelCapacity: agentModelCapacity
    ingestionChatModelName: foundryIqChatModelName
    ingestionChatModelDeploymentName: foundryIqChatModelDeploymentName
    ingestionChatModelCapacity: foundryIqChatModelCapacity
    ingestionEmbeddingModelName: foundryIqEmbeddingModelName
    ingestionEmbeddingModelDeploymentName: foundryIqEmbeddingModelDeploymentName
    ingestionEmbeddingModelCapacity: foundryIqEmbeddingModelCapacity
    searchServiceName: empty(searchServiceName) ? generatedSearchServiceName : searchServiceName
    knowledgeBaseName: foundryIqKnowledgeBaseName
    agentName: foundryAgentName
  }
}

var generatedFabricCapacityName = take(toLower(replace('fc-${environmentName}-${uniqueSuffix}', '_', '-')), 63)
var generatedFabricWorkspaceName = take('call-center-${sanitizedEnvName}-${uniqueSuffix}', 256)
module fabric 'modules/fabric.bicep' = {
  name: 'fabric'
  scope: rg
  params: {
    capacityName: generatedFabricCapacityName
    location: fabricLocation
    skuName: fabricCapacitySku
    administrator: fabricCapacityAdmin
    tags: tags
  }
}

module acs 'modules/acs.bicep' = if (telephonyProvider == 'acs') {
  name: 'acs-deployment'
  scope: rg
  params: {
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
    tags: tags
  }
}

var rawKvName = take(toLower(replace(replace(replace(replace('kv-${environmentName}-${uniqueSuffix}', ' ', ''), '.', ''), '--', '-'), '_', '')), 24)
var keyVaultName = endsWith(rawKvName, '-') ? take(rawKvName, length(rawKvName) - 1) : rawKvName
module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault-deployment'
  scope: rg
  params: {
    location: location
    keyVaultName: keyVaultName
    tags: tags
    #disable-next-line BCP327
    acsConnectionString: (telephonyProvider == 'acs') ? acs.outputs.acsConnectionString : ''
    twilioAuthToken: twilioAuthToken
    infobipApiKey: infobipApiKey
    genesysApiKey: genesysApiKey
    sinchApplicationKey: sinchApplicationKey
    sinchApplicationSecret: sinchApplicationSecret
    bandwidthClientId: bandwidthClientId
    bandwidthClientSecret: bandwidthClientSecret
  }
}

// Add role assignments 
module RoleAssignments 'modules/roleassignments.bicep' = {
  scope: rg
  name: 'role-assignments'
  params: {
    identityPrincipalId: appIdentity.outputs.principalId
    projectPrincipalId: aiServices.outputs.projectPrincipalId
    aiServicesId: aiServices.outputs.aiServicesId
    keyVaultName: keyVaultName
  }
  dependsOn: [ keyvault ]
}

module containerapp 'modules/containerapp.bicep' = {
  name: 'containerapp-deployment'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
    tags: tags
    exists: appExists
    identityId: appIdentity.outputs.identityId
    identityClientId: appIdentity.outputs.clientId
    fabricReadIdentityId: fabricReadIdentity.outputs.identityId
    fabricReadIdentityClientId: fabricReadIdentity.outputs.clientId
    fabricWriteIdentityId: fabricWriteIdentity.outputs.identityId
    fabricWriteIdentityClientId: fabricWriteIdentity.outputs.clientId
    authorizedCustomerKey: authorizedCustomerKey
    containerRegistryName: registry.outputs.name
    aiServicesEndpoint: aiServices.outputs.aiServicesEndpoint
    modelDeploymentName: aiServices.outputs.modelDeploymentName
    voiceName: voiceName
    enableFoundryAgent: true
    foundryProjectName: aiServices.outputs.projectName
    foundryAgentName: foundryIq.outputs.agentName
    acsConnectionStringSecretUri: keyvault.outputs.acsConnectionStringUri
    twilioAuthTokenSecretUri: keyvault.outputs.twilioAuthTokenUri
    infobipApiKeySecretUri: keyvault.outputs.infobipApiKeyUri
    infobipApiBaseUrl: infobipApiBaseUrl
    genesysApiKeySecretUri: keyvault.outputs.genesysApiKeyUri
    sinchApplicationKeySecretUri: keyvault.outputs.sinchApplicationKeyUri
    sinchApplicationSecretSecretUri: keyvault.outputs.sinchApplicationSecretUri
    bandwidthClientIdSecretUri: keyvault.outputs.bandwidthClientIdUri
    bandwidthClientSecretSecretUri: keyvault.outputs.bandwidthClientSecretUri
    bandwidthAccountId: bandwidthAccountId
    bandwidthApplicationId: bandwidthApplicationId
    logAnalyticsWorkspaceName: logAnalyticsName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    debugMode: debugMode
    imageName: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
  }
  dependsOn: [RoleAssignments]
}


// OUTPUTS will be saved in azd env for later use
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_USER_ASSIGNED_IDENTITY_ID string = appIdentity.outputs.identityId
output AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID string = appIdentity.outputs.clientId
output AZURE_USER_ASSIGNED_IDENTITY_PRINCIPAL_ID string = appIdentity.outputs.principalId
output FABRIC_READ_IDENTITY_PRINCIPAL_ID string = fabricReadIdentity.outputs.principalId
output FABRIC_WRITE_IDENTITY_PRINCIPAL_ID string = fabricWriteIdentity.outputs.principalId

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.loginServer
output AZURE_CONTAINER_APP_NAME string = containerapp.outputs.containerAppName

// Provider endpoint mapping — add new providers here
var providerEndpoints = {
  acs: 'https://${containerapp.outputs.containerAppFqdn}/acs/incomingcall'
  twilio: 'https://${containerapp.outputs.containerAppFqdn}/voice'
  infobip: 'https://${containerapp.outputs.containerAppFqdn}/infobip/incoming'
  genesys: 'wss://${containerapp.outputs.containerAppFqdn}/audiohook/ws'
  sinch: 'https://${containerapp.outputs.containerAppFqdn}/sinch/callbacks'
  bandwidth: 'https://${containerapp.outputs.containerAppFqdn}/bandwidth/incoming'
}
output SERVICE_API_ENDPOINTS array = [providerEndpoints[telephonyProvider]]
output AZURE_VOICE_LIVE_ENDPOINT string = aiServices.outputs.aiServicesEndpoint
output AZURE_VOICE_LIVE_MODEL string = aiServices.outputs.modelDeploymentName
output AZURE_VOICE_LIVE_VOICE string = voiceName
output AZURE_AI_FOUNDRY_PROJECT_ID string = aiServices.outputs.projectId
output AZURE_AI_FOUNDRY_PROJECT_NAME string = aiServices.outputs.projectName
output AZURE_AI_FOUNDRY_PROJECT_ENDPOINT string = aiServices.outputs.projectEndpoint
output AZURE_AI_FOUNDRY_CONNECTION_NAME string = aiServices.outputs.projectConnectionName
output ENABLE_FOUNDRY_IQ bool = true
output AZURE_AI_SEARCH_SERVICE_NAME string = foundryIq.outputs.searchServiceName
output AZURE_AI_SEARCH_ENDPOINT string = foundryIq.outputs.searchEndpoint
output AZURE_SEARCH_ENDPOINT string = foundryIq.outputs.searchEndpoint
output AZURE_FOUNDRY_ENDPOINT string = aiServices.outputs.aiServicesEndpoint
output AZURE_STORAGE_ACCOUNT_NAME string = foundryIq.outputs.storageAccountName
output AZURE_STORAGE_CONTAINER_NAME string = foundryIq.outputs.storageContainerName
output AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME string = foundryIq.outputs.knowledgeBaseName
output AZURE_FOUNDRY_IQ_CONNECTION_NAME string = foundryIq.outputs.projectConnectionName
output AZURE_FOUNDRY_IQ_CHAT_MODEL_NAME string = foundryIqChatModelName
output AZURE_FOUNDRY_IQ_CHAT_MODEL_DEPLOYMENT string = foundryIq.outputs.ingestionChatModelDeploymentName
output AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_NAME string = foundryIqEmbeddingModelName
output AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_DEPLOYMENT string = foundryIq.outputs.ingestionEmbeddingModelDeploymentName
output AZURE_AI_FOUNDRY_AGENT_ID string = foundryIq.outputs.agentName
output AZURE_AI_AGENT_MODEL_NAME string = agentModelName
output AZURE_AI_AGENT_MODEL_VERSION string = agentModelVersion
output AZURE_AI_AGENT_MODEL_DEPLOYMENT string = agentModelDeploymentName
output AZURE_VOICE_LIVE_MODEL_NAME string = modelName
output AZURE_VOICE_LIVE_MODEL_VERSION string = modelVersion
output FABRIC_CAPACITY_ID string = fabric.outputs.capacityId
output FABRIC_CAPACITY_NAME string = fabric.outputs.capacityName
output FABRIC_WORKSPACE_NAME string = empty(fabricWorkspaceName) ? generatedFabricWorkspaceName : fabricWorkspaceName
output FABRIC_LAKEHOUSE_NAME string = fabricLakehouseName
output FABRIC_DATA_AGENT_NAME string = fabricDataAgentName
