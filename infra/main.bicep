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
@description('Foundry catalog model name. Override together with modelVersion when selecting another release.')
param modelName string = 'gpt-realtime-2.1'
@description('Foundry catalog model version.')
param modelVersion string = '2026-07-07'
@minLength(1)
@maxLength(64)
@description('Deployment name passed to the Voice Live realtime API.')
param modelDeploymentName string = 'gpt-realtime'
@description('Foundry deployment SKU.')
param modelSkuName string = 'GlobalStandard'
@minValue(1)
@description('Deployment capacity in thousands of tokens per minute.')
param modelCapacity int = 1
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
@description('Provision Azure AI Search, Foundry IQ sample knowledge, and a grounded Foundry agent.')
param enableFoundryIq bool = false
@description('Azure AI Search service name. Leave empty to generate a deterministic name.')
param searchServiceName string = ''
@description('Search index used by the sample Foundry IQ knowledge source.')
param searchIndexName string = 'call-center-content'
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
param agentModelCapacity int = 10

var uniqueSuffix = substring(uniqueString(subscription().id, environmentName), 0, 5)
var tags = {'azd-env-name': environmentName }
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
module foundryIq 'modules/foundryiq.bicep' = if (enableFoundryIq) {
  name: 'foundry-iq'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    uniqueSuffix: uniqueSuffix
    tags: tags
    aiServicesName: aiServices.outputs.aiServicesName
    aiServicesId: aiServices.outputs.aiServicesId
    projectName: aiServices.outputs.projectName
    projectEndpoint: aiServices.outputs.projectEndpoint
    projectPrincipalId: aiServices.outputs.projectPrincipalId
    agentModelName: agentModelName
    agentModelVersion: agentModelVersion
    agentModelDeploymentName: agentModelDeploymentName
    agentModelSkuName: agentModelSkuName
    agentModelCapacity: agentModelCapacity
    searchServiceName: empty(searchServiceName) ? generatedSearchServiceName : searchServiceName
    searchIndexName: searchIndexName
    knowledgeBaseName: foundryIqKnowledgeBaseName
    agentName: foundryAgentName
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
    containerRegistryName: registry.outputs.name
    aiServicesEndpoint: aiServices.outputs.aiServicesEndpoint
    modelDeploymentName: aiServices.outputs.modelDeploymentName
    enableFoundryAgent: enableFoundryIq
    foundryProjectName: aiServices.outputs.projectName
    foundryAgentName: enableFoundryIq ? foundryIq.outputs.agentName : ''
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

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.loginServer

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
output AZURE_AI_FOUNDRY_PROJECT_ID string = aiServices.outputs.projectId
output AZURE_AI_FOUNDRY_PROJECT_NAME string = aiServices.outputs.projectName
output AZURE_AI_FOUNDRY_CONNECTION_NAME string = aiServices.outputs.projectConnectionName
output ENABLE_FOUNDRY_IQ bool = enableFoundryIq
output AZURE_AI_SEARCH_SERVICE_NAME string = enableFoundryIq ? foundryIq.outputs.searchServiceName : ''
output AZURE_AI_SEARCH_ENDPOINT string = enableFoundryIq ? foundryIq.outputs.searchEndpoint : ''
output AZURE_AI_SEARCH_INDEX_NAME string = enableFoundryIq ? foundryIq.outputs.searchIndexName : ''
output AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME string = enableFoundryIq ? foundryIq.outputs.knowledgeBaseName : ''
output AZURE_FOUNDRY_IQ_CONNECTION_NAME string = enableFoundryIq ? foundryIq.outputs.projectConnectionName : ''
output AZURE_AI_FOUNDRY_AGENT_ID string = enableFoundryIq ? foundryIq.outputs.agentName : ''
output AZURE_VOICE_LIVE_MODEL_NAME string = modelName
output AZURE_VOICE_LIVE_MODEL_VERSION string = modelVersion
