param location string
param environmentName string
param uniqueSuffix string
param tags object
param aiServicesName string
param aiServicesId string
param projectName string
param projectEndpoint string
param projectPrincipalId string
param agentModelName string
param agentModelVersion string
param agentModelDeploymentName string
param agentModelSkuName string
param agentModelCapacity int
param searchServiceName string
param searchIndexName string
param knowledgeBaseName string
param agentName string

var knowledgeSourceName = '${knowledgeBaseName}-source'
var connectionName = '${knowledgeBaseName}-connection'
var searchEndpoint = 'https://${searchService.name}.search.windows.net'
var mcpEndpoint = '${searchEndpoint}/knowledgebases/${knowledgeBaseName}/mcp?api-version=2026-08-01-preview'
var provisioningIdentityName = take('id-iq-${environmentName}-${uniqueSuffix}', 128)

resource searchService 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchServiceName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'basic'
  }
  properties: {
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    disableLocalAuth: true
    hostingMode: 'Default'
    publicNetworkAccess: 'enabled'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'free'
  }
}

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: aiServicesName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: aiServices
  name: projectName
}

resource agentModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: agentModelDeploymentName
  sku: {
    name: agentModelSkuName
    capacity: agentModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: agentModelName
      version: agentModelVersion
    }
    raiPolicyName: 'Microsoft.Default'
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource projectConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-10-01-preview' = {
  parent: project
  name: connectionName
  properties: {
    #disable-next-line BCP036
    authType: 'ProjectManagedIdentity'
    category: 'RemoteTool'
    target: mcpEndpoint
    isSharedToAll: true
    audience: 'https://search.azure.com/'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchService.id
    }
  }
}

resource provisioningIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: provisioningIdentityName
  location: location
  tags: tags
}

resource projectSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, projectPrincipalId, 'Search Index Data Reader')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
    principalId: projectPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource provisionerSearchServiceContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, provisioningIdentity.id, 'Search Service Contributor')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    principalId: provisioningIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource provisionerSearchDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, provisioningIdentity.id, 'Search Index Data Contributor')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
    principalId: provisioningIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource provisionerFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesId, provisioningIdentity.id, 'Cognitive Services User')
  scope: aiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: provisioningIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource provisionFoundryIq 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'provision-foundry-iq-${uniqueSuffix}'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${provisioningIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.76.0'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT30M'
    forceUpdateTag: uniqueString(loadTextContent('../scripts/provision-foundry-iq.sh'))
    environmentVariables: [
      {
        name: 'SEARCH_ENDPOINT'
        value: searchEndpoint
      }
      {
        name: 'SEARCH_INDEX_NAME'
        value: searchIndexName
      }
      {
        name: 'KNOWLEDGE_SOURCE_NAME'
        value: knowledgeSourceName
      }
      {
        name: 'KNOWLEDGE_BASE_NAME'
        value: knowledgeBaseName
      }
      {
        name: 'PROJECT_ENDPOINT'
        value: projectEndpoint
      }
      {
        name: 'PROJECT_CONNECTION_NAME'
        value: projectConnection.name
      }
      {
        name: 'AGENT_NAME'
        value: agentName
      }
      {
        name: 'AGENT_MODEL_DEPLOYMENT'
        value: agentModelDeployment.name
      }
    ]
    scriptContent: loadTextContent('../scripts/provision-foundry-iq.sh')
  }
  dependsOn: [
    projectSearchReader
    provisionerSearchServiceContributor
    provisionerSearchDataContributor
    provisionerFoundryUser
  ]
}

output searchServiceName string = searchService.name
output searchEndpoint string = searchEndpoint
output searchIndexName string = searchIndexName
output knowledgeBaseName string = knowledgeBaseName
output knowledgeSourceName string = knowledgeSourceName
output projectConnectionName string = projectConnection.name
output agentName string = agentName
output agentModelDeploymentName string = agentModelDeployment.name
