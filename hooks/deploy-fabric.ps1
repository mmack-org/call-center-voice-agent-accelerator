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
    if ([int]$response.StatusCode -eq 202) {
        $operationUri = [string]$response.Headers.Location
        if ([string]::IsNullOrWhiteSpace($operationUri)) {
            $operationUri = [string]$response.Headers["Operation-Location"]
        }
        if ([string]::IsNullOrWhiteSpace($operationUri)) {
            throw "$Method $Path returned HTTP 202 without an operation URL."
        }
        for ($attempt = 1; $attempt -le 60; $attempt++) {
            Start-Sleep -Seconds 5
            $response = Invoke-WebRequest `
                -Method Get `
                -Uri $operationUri `
                -Headers @{ Authorization = "******" } `
                -SkipHttpErrorCheck
            if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
                throw "Fabric operation failed with HTTP $([int]$response.StatusCode)."
            }
            $operation = if ([string]::IsNullOrWhiteSpace($response.Content)) {
                $null
            } else {
                $response.Content | ConvertFrom-Json
            }
            if ($null -ne $operation -and $operation.status -eq "Failed") {
                throw "Fabric operation failed: $($response.Content)"
            }
            if (
                [int]$response.StatusCode -ne 202 -and
                ($null -eq $operation -or $operation.status -notin @("NotStarted", "Running"))
            ) {
                if ($null -ne $operation -and $operation.resourceLocation) {
                    $response = Invoke-WebRequest `
                        -Method Get `
                        -Uri $operation.resourceLocation `
                        -Headers @{ Authorization = "******" } `
                        -SkipHttpErrorCheck
                }
                break
            }
            if ($attempt -eq 60) {
                throw "Fabric operation did not complete within five minutes."
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }
    $result = $response.Content | ConvertFrom-Json
    if ($null -ne $result -and $result.PSObject.Properties["resourceLocation"]) {
        $resourceResponse = Invoke-WebRequest `
            -Method Get `
            -Uri $result.resourceLocation `
            -Headers @{ Authorization = "******" } `
            -SkipHttpErrorCheck
        if ([int]$resourceResponse.StatusCode -ge 200 -and [int]$resourceResponse.StatusCode -lt 300) {
            return $resourceResponse.Content | ConvertFrom-Json
        }
    }
    return $result
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
    Invoke-Fabric -Method "POST" -Path "workspaces/$WorkspaceId/$Collection" -Token $Token -Body $CreateBody | Out-Null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $items = Invoke-Fabric -Method "GET" -Path "workspaces/$WorkspaceId/$Collection" -Token $Token
        $created = @($items.value) |
            Where-Object { $_.displayName -eq $DisplayName } |
            Select-Object -First 1
        if ($created) {
            return $created
        }
        Start-Sleep -Seconds 5
    }
    throw "Fabric item '$DisplayName' was not visible after creation."
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
    Invoke-Fabric -Method "POST" -Path "workspaces" -Token $token -Body @{
        displayName = $workspaceName
        description = "Call center operational data managed by azd."
    } | Out-Null
    $workspaces = Invoke-Fabric -Method "GET" -Path "workspaces" -Token $token
    $workspace = @($workspaces.value) |
        Where-Object { $_.displayName -eq $workspaceName } |
        Select-Object -First 1
    if (-not $workspace) {
        throw "Fabric workspace '$workspaceName' was not visible after creation."
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

$roleAssignments = Invoke-Fabric -Method "GET" -Path "workspaces/$($workspace.id)/roleAssignments" -Token $token
$readPrincipalId = Get-AzdValue "FABRIC_READ_IDENTITY_PRINCIPAL_ID"
$writePrincipalId = Get-AzdValue "FABRIC_WRITE_IDENTITY_PRINCIPAL_ID"
foreach ($assignment in @(
    @{ PrincipalId = $readPrincipalId; Role = "Viewer" },
    @{ PrincipalId = $writePrincipalId; Role = "Contributor" }
)) {
    $existingAssignment = @($roleAssignments.value) |
        Where-Object { $_.principal.id -eq $assignment.PrincipalId } |
        Select-Object -First 1
    if ($existingAssignment -and $existingAssignment.role -ne $assignment.Role) {
        Invoke-Fabric `
            -Method "PATCH" `
            -Path "workspaces/$($workspace.id)/roleAssignments/$($existingAssignment.id)" `
            -Token $token `
            -Body @{ role = $assignment.Role } | Out-Null
    }
    elseif (-not $existingAssignment) {
        Invoke-Fabric `
            -Method "POST" `
            -Path "workspaces/$($workspace.id)/roleAssignments" `
            -Token $token `
            -Body @{
                principal = @{
                    id = $assignment.PrincipalId
                    type = "ServicePrincipal"
                }
                role = $assignment.Role
            } | Out-Null
    }
}

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
$notebookSource = $notebookSource.Replace("__WORKSPACE_ID__", $workspace.id).Replace("__LAKEHOUSE_ID__", $lakehouse.id).Replace("__LAKEHOUSE_NAME__", $lakehouse.displayName)
$notebookPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($notebookSource))
$notebookDefinition = @{
    format = "fabricGitSource"
    parts = @(
        @{
            path = "notebook-content.py"
            payload = $notebookPayload
            payloadType = "InlineBase64"
        }
    )
}
$notebook = Get-OrCreateItem `
    -WorkspaceId $workspace.id `
    -Collection "notebooks" `
    -DisplayName "ingest-call-center-data" `
    -Token $token `
    -CreateBody @{
        displayName = "ingest-call-center-data"
        description = "Idempotent SAVOYE-IQ Bronze, Silver, and Gold ingestion."
        definition = $notebookDefinition
    }
Invoke-Fabric `
    -Method "POST" `
    -Path "workspaces/$($workspace.id)/notebooks/$($notebook.id)/updateDefinition" `
    -Token $token `
    -Body @{ definition = $notebookDefinition } | Out-Null

$rawSource = Join-Path $PSScriptRoot "../fabric/data/raw"
$rawFiles = if (Test-Path $rawSource) {
    @(Get-ChildItem $rawSource -File -Recurse)
} else {
    @()
}
if ($rawFiles.Count -gt 0) {
    $schedulePath = "workspaces/$($workspace.id)/items/$($notebook.id)/jobs/RunNotebook/schedules"
    $schedules = Invoke-Fabric -Method "GET" -Path $schedulePath -Token $token
    $dailySchedule = @($schedules.value) |
        Where-Object {
            $_.configuration.type -eq "Daily" -and
            $_.configuration.localTimeZoneId -eq "UTC" -and
            $_.configuration.times -contains "00:15"
        } |
        Select-Object -First 1
    if (-not $dailySchedule) {
        Invoke-Fabric -Method "POST" -Path $schedulePath -Token $token -Body @{
            enabled = $true
            configuration = @{
                startDateTime = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                endDateTime = [DateTime]::UtcNow.AddYears(10).ToString("yyyy-MM-ddTHH:mm:ssZ")
                localTimeZoneId = "UTC"
                type = "Daily"
                times = @("00:15")
            }
        } | Out-Null
    }
    $storageToken = az account get-access-token --resource "https://storage.azure.com" --query accessToken -o tsv
    foreach ($file in $rawFiles) {
        $relativePath = [IO.Path]::GetRelativePath($rawSource, $file.FullName).Replace("\", "/")
        $encodedPath = ($relativePath.Split("/") | ForEach-Object {
            [Uri]::EscapeDataString($_)
        }) -join "/"
        $oneLakeUrl = "https://onelake.dfs.fabric.microsoft.com/$($workspace.id)/$($lakehouse.id)/Files/raw/$encodedPath"
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Invoke-WebRequest `
            -Method Put `
            -Uri "$oneLakeUrl`?resource=file" `
            -Headers @{ Authorization = "******" } | Out-Null
        Invoke-WebRequest `
            -Method Patch `
            -Uri "$oneLakeUrl`?action=append&position=0" `
            -Headers @{ Authorization = "******" } `
            -ContentType "application/octet-stream" `
            -Body $bytes | Out-Null
        Invoke-WebRequest `
            -Method Patch `
            -Uri "$oneLakeUrl`?action=flush&position=$($bytes.Length)" `
            -Headers @{ Authorization = "******" } | Out-Null
    }
    Invoke-Fabric `
        -Method "POST" `
        -Path "workspaces/$($workspace.id)/items/$($notebook.id)/jobs/instances?jobType=RunNotebook" `
        -Token $token | Out-Null
    Write-Host "Uploaded $($rawFiles.Count) raw files and started the ingestion notebook." -ForegroundColor Green
} else {
    Write-Warning "No files found under fabric/data/raw; provisioned Fabric artifacts without running ingestion."
}

$safeTables = @(
    "dim_product", "dim_range", "dim_customer", "dim_agent", "dim_date",
    "dim_document", "bridge_installed_base", "bridge_ticket_tag",
    "fact_ticket", "fact_part_consumption", "fact_ticket_escalation"
)
$tableElements = @($safeTables | ForEach-Object {
    @{
        id = [guid]::NewGuid().ToString()
        display_name = $_
        type = "lakehouse_tables.table"
        is_selected = $true
        description = $null
        children = @()
    }
})
$dataAgentSourceName = "lakehouse-$lakehouseName"
$dataAgentRoot = @{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/dataAgent/2.1.0/schema.json"
}
$stageConfig = @{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/stageConfiguration/1.0.0/schema.json"
    aiInstructions = "Use only selected Gold tables. Every customer query must filter customer_key exactly. Never return email, phone, message_body, or csat_comment. Return source table and entity identifiers. If no authorized row matches, return no result."
}
$dataSource = @{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/dataSource/1.0.0/schema.json"
    artifactId = $lakehouse.id
    workspaceId = $workspace.id
    dataSourceInstructions = "Read-only operational support data. Enforce customer_key on every customer-specific request."
    displayName = $lakehouse.displayName
    type = "lakehouse_tables"
    userDescription = "Curated, PII-safe Gold support tables."
    metadata = @{}
    elements = @(
        @{
            id = [guid]::NewGuid().ToString()
            display_name = "Schemas"
            type = "schema_grouping"
            is_selected = $false
            description = $null
            children = @(
                @{
                    id = [guid]::NewGuid().ToString()
                    display_name = "gold"
                    type = "lakehouse_tables.schema"
                    is_selected = $false
                    description = $null
                    children = @(
                        @{
                            id = [guid]::NewGuid().ToString()
                            display_name = "Tables"
                            type = "table_grouping"
                            is_selected = $false
                            description = $null
                            children = $tableElements
                        }
                    )
                }
            )
        }
    )
}
$publishInfo = @{
    '$schema' = "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/publishInfo/1.0.0/schema.json"
    description = "Published read-only call-center operational data."
}
$definitionParts = @(
    @{ Path = "Files/Config/data_agent.json"; Content = $dataAgentRoot },
    @{ Path = "Files/Config/draft/stage_config.json"; Content = $stageConfig },
    @{ Path = "Files/Config/draft/$dataAgentSourceName/datasource.json"; Content = $dataSource },
    @{ Path = "Files/Config/publish_info.json"; Content = $publishInfo },
    @{ Path = "Files/Config/published/stage_config.json"; Content = $stageConfig },
    @{ Path = "Files/Config/published/$dataAgentSourceName/datasource.json"; Content = $dataSource }
) | ForEach-Object {
    @{
        path = $_.Path
        payload = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($_.Content | ConvertTo-Json -Depth 30 -Compress))
        )
        payloadType = "InlineBase64"
    }
}
$dataAgentDefinition = @{ parts = @($definitionParts) }
$dataAgent = Get-OrCreateItem `
    -WorkspaceId $workspace.id `
    -Collection "dataAgents" `
    -DisplayName $dataAgentName `
    -Token $token `
    -CreateBody @{
        displayName = $dataAgentName
        description = "Read-only, customer-scoped operational support retrieval."
        definition = $dataAgentDefinition
    }
Invoke-Fabric `
    -Method "POST" `
    -Path "workspaces/$($workspace.id)/dataAgents/$($dataAgent.id)/updateDefinition" `
    -Token $token `
    -Body @{ definition = $dataAgentDefinition } | Out-Null

azd env set FABRIC_WORKSPACE_ID $workspace.id
azd env set FABRIC_LAKEHOUSE_ID $lakehouse.id
azd env set FABRIC_INGESTION_NOTEBOOK_ID $notebook.id
azd env set FABRIC_DATA_AGENT_ID $dataAgent.id

$resourceGroup = Get-AzdValue "AZURE_RESOURCE_GROUP"
$containerAppName = Get-AzdValue "AZURE_CONTAINER_APP_NAME"
$containerEnvironment = @(
    "FABRIC_WORKSPACE_ID=$($workspace.id)",
    "FABRIC_LAKEHOUSE_ID=$($lakehouse.id)",
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
