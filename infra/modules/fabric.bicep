param capacityName string
param location string
param skuName string
param administrator string
param tags object

resource capacity 'Microsoft.Fabric/capacities@2025-01-15-preview' = {
  name: capacityName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'Fabric'
  }
  properties: {
    administration: {
      members: [
        administrator
      ]
    }
  }
}

output capacityId string = capacity.id
output capacityName string = capacity.name
