$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-AzdValue {
    param([Parameter(Mandatory)][string] $Name)
    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "Required azd environment value '$Name' is not set."
    }
    return $value.Trim()
}

function Invoke-Fabric {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Token,
        [object] $Body = $null
    )
    $parameters = @{
        Method = $Method
        Uri = "https://api.fabric.microsoft.com/v1/$Path"
        Headers = @{ Authorization = "******" }
        ContentType = "application/json"
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress
    }
    $response = Invoke-WebRequest @parameters
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "$Method $Path failed with HTTP $([int]$response.StatusCode): $($response.Content)"
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }
    return $response.Content | ConvertFrom-Json
}

function Get-OrCreateItem {
    param(
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $Collection,
        [Parameter(Mandatory)][string] $DisplayName,
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][hashtable] $CreateBody
    )
    $items = Invoke-Fabric -Method "GET" -Path "workspaces/$WorkspaceId/$Collection" -Token $Token
    $existing = @($items.value) | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1
    if ($existing) {
        return $existing
    }
    return Invoke-Fabric -Method "POST" -Path "workspaces/$WorkspaceId/$Collection" -Token $Token -Body $CreateBody
}

$workspaceName = Get-AzdValue "FABRIC_WORKSPACE_NAME"
$lakehouseName = Get-AzdValue "FABRIC_LAKEHOUSE_NAME"
$dataAgentName = Get-AzdValue "FABRIC_DATA_AGENT_NAME"
$capacityName = Get-AzdValue "FABRIC_CAPACITY_NAME"
$token = az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Unable to obtain a Microsoft Fabric access token."
}

$workspaces = Invoke-Fabric -Method "GET" -Path "workspaces" -Token $token
$workspace = @($workspaces.value) | Where-Object { $_.displayName -eq $workspaceName } | Select-Object -First 1
if (-not $workspace) {
    $workspace = Invoke-Fabric -Method "POST" -Path "workspaces" -Token $token -Body @{
        displayName = $workspaceName
        description = "Call center operational data managed by azd."
    }
}

$capacities = Invoke-Fabric -Method "GET" -Path "capacities" -Token $token
$capacity = @($capacities.value) |
    Where-Object { $_.displayName -eq $capacityName -or $_.name -eq $capacityName } |
    Select-Object -First 1
if (-not $capacity) {
    throw "Fabric capacity '$capacityName' is not visible to the deployment identity."
}

Invoke-Fabric -Method "POST" -Path "workspaces/$($workspace.id)/assignToCapacity" -Token $token -Body @{
    capacityId = $capacity.id
} | Out-Null
Invoke-Fabric -Method "POST" -Path "workspaces/$($workspace.id)/provisionIdentity" -Token $token | Out-Null

$lakehouse = Get-OrCreateItem `
    -WorkspaceId $workspace.id `
    -Collection "lakehouses" `
    -DisplayName $lakehouseName `
    -Token $token `
    -CreateBody @{
        displayName = $lakehouseName
        description = "Bronze, Silver, and Gold call-center operational data."
        creationPayload = @{ enableSchemas = $true }
    }

$notebookSource = Get-Content (Join-Path $PSScriptRoot "../fabric/notebooks/ingest.py") -Raw
$notebookPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($notebookSource))
$notebook = Get-OrCreateItem `
    -WorkspaceId $workspace.id `
    -Collection "notebooks" `
    -DisplayName "ingest-call-center-data" `
    -Token $token `
    -CreateBody @{
        displayName = "ingest-call-center-data"
        description = "Idempotent SAVOYE-IQ Bronze, Silver, and Gold ingestion."
        definition = @{
            format = "ipynb"
            parts = @(
                @{
                    path = "notebook-content.py"
                    payload = $notebookPayload
                    payloadType = "InlineBase64"
                }
            )
        }
    }

$dataAgent = Get-OrCreateItem `
    -WorkspaceId $workspace.id `
    -Collection "dataAgents" `
    -DisplayName $dataAgentName `
    -Token $token `
    -CreateBody @{
        displayName = $dataAgentName
        description = "Read-only, customer-scoped operational support retrieval."
        definition = @{
            dataSources = @(
                @{
                    type = "Lakehouse"
                    id = $lakehouse.id
                    name = $lakehouse.displayName
                }
            )
        }
    }

azd env set FABRIC_WORKSPACE_ID $workspace.id
azd env set FABRIC_LAKEHOUSE_ID $lakehouse.id
azd env set FABRIC_INGESTION_NOTEBOOK_ID $notebook.id
azd env set FABRIC_DATA_AGENT_ID $dataAgent.id

$fabricConnectionName = "call-center-fabric-data"
$projectId = Get-AzdValue "AZURE_AI_FOUNDRY_PROJECT_ID"
$subscriptionId = Get-AzdValue "AZURE_SUBSCRIPTION_ID"
$managementToken = az account get-access-token --resource "https://management.azure.com" --query accessToken -o tsv
$connectionBody = @{
    properties = @{
        category = "CustomKeys"
        authType = "CustomKeys"
        target = "-"
        isSharedToAll = $true
        credentials = @{
            keys = @{
                "workspace-id" = $workspace.id
                "artifact-id" = $dataAgent.id
            }
        }
        metadata = @{ type = "fabric_dataagent_preview" }
    }
} | ConvertTo-Json -Depth 20 -Compress
$connectionUri = "https://management.azure.com$projectId/connections/$fabricConnectionName`?api-version=2025-10-01-preview"
$connectionResponse = Invoke-WebRequest `
    -Method Put `
    -Uri $connectionUri `
    -Headers @{ Authorization = "******" } `
    -ContentType "application/json" `
    -Body $connectionBody `
    -SkipHttpErrorCheck
if ([int]$connectionResponse.StatusCode -lt 200 -or [int]$connectionResponse.StatusCode -ge 300) {
    throw "Creating the Foundry Fabric connection failed with HTTP $([int]$connectionResponse.StatusCode)."
}
azd env set AZURE_FABRIC_DATA_AGENT_CONNECTION_NAME $fabricConnectionName

$resourceGroup = Get-AzdValue "AZURE_RESOURCE_GROUP"
$containerAppName = Get-AzdValue "AZURE_CONTAINER_APP_NAME"
$containerEnvironment = @(
    "FABRIC_WORKSPACE_ID=$($workspace.id)",
    "FABRIC_DATA_AGENT_ID=$($dataAgent.id)"
)
$ticketWriteEndpoint = azd env get-value FABRIC_TICKET_WRITE_ENDPOINT 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ticketWriteEndpoint)) {
    $containerEnvironment += "FABRIC_TICKET_WRITE_ENDPOINT=$ticketWriteEndpoint"
}
az containerapp update `
    --resource-group $resourceGroup `
    --name $containerAppName `
    --set-env-vars $containerEnvironment `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Unable to configure Fabric settings on Container App '$containerAppName'."
}
Write-Host "Fabric workspace, Lakehouse, ingestion notebook, and Data Agent are configured." -ForegroundColor Green
