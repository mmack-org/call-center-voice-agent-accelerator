param location string
param tags object
param aiServicesName string
param aiServicesId string
param projectName string
param projectEndpoint string
param projectPrincipalId string
param deploymentPrincipalId string
param deploymentPrincipalType string
param storageAccountName string
param storageContainerName string
param agentModelName string
param agentModelVersion string
param agentModelDeploymentName string
param agentModelSkuName string
param agentModelCapacity int
param ingestionChatModelName string
param ingestionChatModelDeploymentName string
param ingestionChatModelCapacity int
param ingestionEmbeddingModelName string
param ingestionEmbeddingModelDeploymentName string
param ingestionEmbeddingModelCapacity int
param searchServiceName string
param knowledgeBaseName string
param agentName string

var knowledgeSourceName = knowledgeBaseName
var connectionName = '${knowledgeBaseName}-connection'
var searchEndpoint = 'https://${searchService.name}.search.windows.net'
var mcpEndpoint = '${searchEndpoint}/knowledgebases/${knowledgeBaseName}/mcp?api-version=2026-08-01-preview'

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
    disableLocalAuth: true
    hostingMode: 'Default'
    publicNetworkAccess: 'enabled'
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'free'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource contentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: storageContainerName
  properties: {
    publicAccess: 'None'
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

resource ingestionChatModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: ingestionChatModelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: ingestionChatModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: ingestionChatModelName
    }
    raiPolicyName: 'Microsoft.Default'
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
  dependsOn: [
    agentModelDeployment
  ]
}

resource ingestionEmbeddingModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: ingestionEmbeddingModelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: ingestionEmbeddingModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: ingestionEmbeddingModelName
    }
    raiPolicyName: 'Microsoft.Default'
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
  dependsOn: [
    ingestionChatModelDeployment
  ]
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

resource searchStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, searchService.id, 'Storage Blob Data Reader')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource searchOpenAIUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServices.id, searchService.id, 'Cognitive Services OpenAI User')
  scope: aiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource searchFoundryToolsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServices.id, searchService.id, 'Cognitive Services User')
  scope: aiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
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

resource deploymentPrincipalStorageContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, deploymentPrincipalId, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: deploymentPrincipalId
    principalType: deploymentPrincipalType
  }
}

resource deploymentPrincipalSearchServiceContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, deploymentPrincipalId, 'Search Service Contributor')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    principalId: deploymentPrincipalId
    principalType: deploymentPrincipalType
  }
}

resource deploymentPrincipalSearchDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, deploymentPrincipalId, 'Search Index Data Contributor')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
    principalId: deploymentPrincipalId
    principalType: deploymentPrincipalType
  }
}

resource deploymentPrincipalFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServicesId, deploymentPrincipalId, 'Foundry User')
  scope: aiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')
    principalId: deploymentPrincipalId
    principalType: deploymentPrincipalType
  }
}

output searchServiceName string = searchService.name
output searchEndpoint string = searchEndpoint
output storageAccountName string = storageAccount.name
output storageContainerName string = contentContainer.name
output knowledgeBaseName string = knowledgeBaseName
output knowledgeSourceName string = knowledgeSourceName
output projectConnectionName string = projectConnection.name
output agentName string = agentName
output agentModelDeploymentName string = agentModelDeployment.name
output ingestionChatModelDeploymentName string = ingestionChatModelDeployment.name
output ingestionEmbeddingModelDeploymentName string = ingestionEmbeddingModelDeployment.name
