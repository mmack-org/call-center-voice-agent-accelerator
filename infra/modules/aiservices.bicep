param environmentName string
param uniqueSuffix string
param identityId string
param tags object
param disableLocalAuth bool = true
param modelName string
param modelVersion string
param modelDeploymentName string
param modelSkuName string = 'GlobalStandard'
param modelCapacity int = 10

@description('Voice Live API supported regions. See: https://learn.microsoft.com/azure/ai-services/speech-service/regions?tabs=voice-live')
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
param location string = 'eastus2'
var aiServicesName = 'aiServices-${environmentName}-${uniqueSuffix}'
var projectName = 'project-${environmentName}-${uniqueSuffix}'
var customSubDomainName = 'domain-${environmentName}-${uniqueSuffix}'

@allowed([
  'S0'
])
param sku string = 'S0'

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: aiServicesName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  sku: {
    name: sku
  }
  kind: 'AIServices'
  tags: tags
  properties: {
    allowProjectManagement: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
    disableLocalAuth: disableLocalAuth
    customSubDomainName: customSubDomainName
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: aiServices
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Call Center Voice Agent'
    description: 'Foundry project for the call center realtime voice agent.'
  }
  dependsOn: [
    realtimeDeployment
  ]
}

resource projectConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: project
  name: 'realtime-models'
  properties: {
    authType: 'AAD'
    category: 'AzureOpenAI'
    target: aiServices.properties.endpoint
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: aiServices.id
    }
  }
}

resource realtimeDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: modelDeploymentName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: 'Microsoft.Default'
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

output aiServicesEndpoint string = aiServices.properties.endpoint
output aiServicesId string = aiServices.id
output aiServicesName string = aiServices.name
output projectId string = project.id
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
output projectConnectionName string = projectConnection.name
output modelDeploymentName string = realtimeDeployment.name
output projectEndpoint string = 'https://${customSubDomainName}.services.ai.azure.com/api/projects/${project.name}'
