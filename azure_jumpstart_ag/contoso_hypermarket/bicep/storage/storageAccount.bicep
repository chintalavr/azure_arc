@description('Storage account name')
param storageAccountName string

@description('Storage account location')
param location string = resourceGroup().location

@description('Storage account kind')
param kind string = 'StorageV2'

@description('Storage account sku')
param skuName string = 'Standard_LRS'

param storageQueueName string = 'aioQueue'

@description('The name of ESA container in Storage Account')
param stcontainerName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: kind
  sku: {
    name: skuName
  }
  properties: {
    supportsHttpsTrafficOnly: true
  }
}

resource storageQueueServices 'Microsoft.Storage/storageAccounts/queueServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource storageQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-01-01' = {
  parent: storageQueueServices
  name: storageQueueName
}

resource storageAccountName_default_container 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  name: '${storageAccountName}/default/${stcontainerName}'
  dependsOn: [
    storageAccount
  ]
}

output queueName string = storageQueueName
output storageAccountResourceId string = storageAccount.id