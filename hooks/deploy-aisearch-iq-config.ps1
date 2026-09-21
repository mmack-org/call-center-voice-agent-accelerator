#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# This solution is provided for testing, learning, and evaluation purposes only.
# It is not intended for production use. Microsoft provides no support or guarantees.
# Use at your own risk.

<#
.SYNOPSIS
    Deploys an Azure AI Search IQ knowledge source and knowledge base backed
    by an automatically indexed Azure Blob Storage container.

.DESCRIPTION
    The knowledge source owns the generated Search data source, skillset, index,
    and indexer. The script discovers those managed resources without assuming
    their names, configures the indexer to surface blob metadata, and stores the
    generated index name in the azd environment.

    Configuration applied (idempotent):
       - Source   : Azure Blob Storage with managed-identity authentication,
                    content extraction, embeddings, and a five-minute schedule.
       - Base     : Answer synthesis over the managed Blob knowledge source.
       - Indexer  : dataToExtract = 'contentAndMetadata',
                    allowSkillsetToReadFileData = true (when a skillset is attached).

.NOTES
    References: https://learn.microsoft.com/en-us/azure/search/
#>

param(
    [string]$SearchEndpoint       = $env:AZURE_SEARCH_ENDPOINT,
    [string]$FoundryEndpoint      = $env:AZURE_FOUNDRY_ENDPOINT,
    [string]$StorageAccountName   = $env:AZURE_STORAGE_ACCOUNT_NAME,
    [string]$SubscriptionId       = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroupName    = $env:AZURE_RESOURCE_GROUP,
    [string]$EmbeddingModelName        = $env:AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_NAME,
    [string]$EmbeddingDeployment       = $env:AZURE_FOUNDRY_IQ_EMBEDDING_MODEL_DEPLOYMENT,
    [string]$ChatCompletionModelName   = $env:AZURE_FOUNDRY_IQ_CHAT_MODEL_NAME,
    [string]$ChatCompletionDeployment  = $env:AZURE_FOUNDRY_IQ_CHAT_MODEL_DEPLOYMENT,
    [string]$AnswerSynthesisDeployment = $env:AZURE_FOUNDRY_IQ_CHAT_MODEL_DEPLOYMENT,
    [string]$KnowledgeBaseName    = $env:AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME,
    [string]$StorageContainerName = $env:AZURE_STORAGE_CONTAINER_NAME,
    [string]$ApiVersion           = '2026-08-01-preview',
    [int]   $IndexerWaitSeconds   = 180    # how long to wait for the managed indexer to appear
)

$ErrorActionPreference = 'Stop'

if ($env:ENABLE_FOUNDRY_IQ -ne 'true') {
    Write-Host "Foundry IQ is disabled; skipping Azure AI Search IQ configuration."
    exit 0
}

$EmbeddingDeployment = [string]::IsNullOrWhiteSpace($EmbeddingDeployment) ? 'text-embedding-3-large' : $EmbeddingDeployment
$EmbeddingModelName = [string]::IsNullOrWhiteSpace($EmbeddingModelName) ? 'text-embedding-3-large' : $EmbeddingModelName
$ChatCompletionDeployment = [string]::IsNullOrWhiteSpace($ChatCompletionDeployment) ? 'gpt-5.2' : $ChatCompletionDeployment
$ChatCompletionModelName = [string]::IsNullOrWhiteSpace($ChatCompletionModelName) ? 'gpt-5.2' : $ChatCompletionModelName
$AnswerSynthesisDeployment = [string]::IsNullOrWhiteSpace($AnswerSynthesisDeployment) ? $ChatCompletionDeployment : $AnswerSynthesisDeployment
$KnowledgeBaseName = [string]::IsNullOrWhiteSpace($KnowledgeBaseName) ? 'call-center-knowledge' : $KnowledgeBaseName
$StorageContainerName = [string]::IsNullOrWhiteSpace($StorageContainerName) ? 'aisindexer' : $StorageContainerName

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Azure AI Search - IQ Configuration Deployment    " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Validate required parameters
# ---------------------------------------------------------------------------
$missingParams = @()
if ([string]::IsNullOrEmpty($SearchEndpoint))     { $missingParams += 'AZURE_SEARCH_ENDPOINT' }
if ([string]::IsNullOrEmpty($FoundryEndpoint))    { $missingParams += 'AZURE_FOUNDRY_ENDPOINT' }
if ([string]::IsNullOrEmpty($StorageAccountName)) { $missingParams += 'AZURE_STORAGE_ACCOUNT_NAME' }
if ([string]::IsNullOrEmpty($SubscriptionId))     { $missingParams += 'AZURE_SUBSCRIPTION_ID' }
if ([string]::IsNullOrEmpty($ResourceGroupName))  { $missingParams += 'AZURE_RESOURCE_GROUP' }

if ($missingParams.Count -gt 0) {
    Write-Error ("Missing required environment variables: {0}. Run 'azd provision' first." -f ($missingParams -join ', '))
    exit 1
}

$SearchEndpoint  = $SearchEndpoint.TrimEnd('/')
$FoundryEndpoint = $FoundryEndpoint.TrimEnd('/')

# Derive the Azure OpenAI endpoint from the Foundry/AI Services endpoint.
if ($FoundryEndpoint -match 'https://([^./]+)\.') {
    $resourceName       = $Matches[1]
    $OpenAIEndpoint     = "https://${resourceName}.openai.azure.com"
    $AIServicesEndpoint = "${FoundryEndpoint}/"
} else {
    $OpenAIEndpoint     = $FoundryEndpoint
    $AIServicesEndpoint = "${FoundryEndpoint}/"
}

$KnowledgeSourceName     = $KnowledgeBaseName
$StorageResourceId       = "/subscriptions/${SubscriptionId}/resourceGroups/${ResourceGroupName}/providers/Microsoft.Storage/storageAccounts/${StorageAccountName}"
$StorageConnectionString = "ResourceId=${StorageResourceId}"

Write-Host ""
Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Search Endpoint     : $SearchEndpoint"        -ForegroundColor Gray
Write-Host "  OpenAI Endpoint     : $OpenAIEndpoint"        -ForegroundColor Gray
Write-Host "  AI Services Endpoint: $AIServicesEndpoint"    -ForegroundColor Gray
Write-Host "  Storage Account     : $StorageAccountName"    -ForegroundColor Gray
Write-Host "  Storage Container   : $StorageContainerName"  -ForegroundColor Gray
Write-Host "  Knowledge Base Name : $KnowledgeBaseName"     -ForegroundColor Gray
Write-Host "  API Version         : $ApiVersion"            -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# Acquire an access token for Azure AI Search
# ---------------------------------------------------------------------------
Write-Host "Acquiring Azure access token for AI Search..." -ForegroundColor Yellow
try {
    $tenantId     = $env:AZURE_TENANT_ID
    $getTokenArgs = @('account','get-access-token','--resource','https://search.azure.com',
                      '--query','{token:accessToken}','--output','json')
    if (-not [string]::IsNullOrEmpty($tenantId)) { $getTokenArgs += @('--tenant', $tenantId) }

    $tokenJson = & az @getTokenArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to acquire access token. Run 'az login' / 'azd auth login'."
        exit 1
    }
    $token = ($tokenJson | ConvertFrom-Json).token
    Write-Host "Access token acquired." -ForegroundColor Green
}
catch {
    Write-Error "Error acquiring access token: $_"
    exit 1
}

$authHeaders = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }

# ---------------------------------------------------------------------------
# REST helpers
# ---------------------------------------------------------------------------
function Invoke-Search {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [int]$Attempts = 18,
        [string]$RetryErrorPattern = ""
    )
    $uri = "${SearchEndpoint}/${Path}"
    $uri += ($Path -match '\?') ? "&api-version=${ApiVersion}" : "?api-version=${ApiVersion}"
    $req = @{ Method = $Method; Uri = $uri; Headers = $authHeaders; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $req.Body = ($Body | ConvertTo-Json -Depth 30) }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return Invoke-RestMethod @req
        }
        catch {
            $statusCode = if ($null -ne $_.Exception.Response) {
                [int]$_.Exception.Response.StatusCode
            } else {
                $null
            }
            $errorDetail = if ($_.ErrorDetails) {
                $_.ErrorDetails.Message
            } else {
                $_.Exception.Message
            }
            $retryableBadRequest = (
                $statusCode -eq 400 -and
                -not [string]::IsNullOrWhiteSpace($RetryErrorPattern) -and
                $errorDetail -match $RetryErrorPattern
            )
            $retryable = $statusCode -in 401, 403, 408, 409, 429 -or $statusCode -ge 500 -or $retryableBadRequest
            if (-not $retryable -or $attempt -eq $Attempts) {
                throw
            }
            Write-Host "  Search request returned HTTP $statusCode; retrying after RBAC/service propagation ($attempt/$Attempts)." -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
    }
}

function Remove-ReadOnly {
    param($Obj)
    foreach ($p in @('@odata.etag')) {
        if ($Obj.PSObject.Properties[$p]) { $Obj.PSObject.Properties.Remove($p) }
    }
    return $Obj
}

function Test-ResourceExists {
    param([string]$Path)
    try { $null = Invoke-Search -Method Get -Path $Path; return $true }
    catch {
        $statusCode = if ($null -ne $_.Exception.Response) {
            $_.Exception.Response.StatusCode.value__
        } else {
            $null
        }
        if ($statusCode -eq 404) { return $false }
        throw
    }
}

# ===========================================================================
# Phase 1 — Ensure the Knowledge Source exists
# (The Knowledge Source provisions and OWNS the index, skillset, indexer and
#  data source. Pre-creating an index/skillset here is pointless — the original
#  script created them and then deleted them — so we skip straight to the KS.)
# ===========================================================================
Write-Host "Phase 1/4: Knowledge Source" -ForegroundColor White

$knowledgeSourceExists = Test-ResourceExists -Path "knowledgesources/${KnowledgeSourceName}"
if ($knowledgeSourceExists) {
    Write-Host "  Knowledge Source '${KnowledgeSourceName}' already exists - updating its configuration." -ForegroundColor Yellow
}
else {
    # The KS requires the managed index/skillset to NOT pre-exist. Remove orphans
    # left by an earlier partial run before creating it.
    foreach ($orphan in @("skillsets/${KnowledgeBaseName}-skillset", "indexes/${KnowledgeBaseName}-index")) {
        if (Test-ResourceExists -Path $orphan) {
            $null = Invoke-Search -Method Delete -Path $orphan
            Write-Host "  Removed orphan $orphan." -ForegroundColor Gray
        }
    }
}

$knowledgeSourceBody = @{
    name          = $KnowledgeSourceName
    kind          = "azureBlob"
    description   = $null
    encryptionKey = $null
    azureBlobParameters = @{
        connectionString = $StorageConnectionString
        containerName    = $StorageContainerName
        folderPath       = $null
        isADLSGen2       = $false
        ingestionParameters = @{
            networkAccessMode          = "public"
            disableImageVerbalization  = $false
            ingestionPermissionOptions = @()
            contentExtractionMode      = "standard"
            identity                   = $null
            embeddingModel             = @{
                kind = "azureOpenAI"
                azureOpenAIParameters = @{
                    resourceUri = $OpenAIEndpoint; deploymentId = $EmbeddingDeployment
                    apiKey = $null; modelName = $EmbeddingModelName; authIdentity = $null
                }
            }
            chatCompletionModel        = @{
                kind = "azureOpenAI"
                azureOpenAIParameters = @{
                    resourceUri = $OpenAIEndpoint; deploymentId = $ChatCompletionDeployment
                    apiKey = $null; modelName = $ChatCompletionModelName; authIdentity = $null
                }
            }
            ingestionSchedule          = @{ interval = "PT5M"; startTime = $null }
            assetStore                 = $null
            aiServices                 = @{ uri = $AIServicesEndpoint; apiKey = $null }
        }
    }
}
try {
    $null = Invoke-Search `
        -Method Put `
        -Path "knowledgesources/${KnowledgeSourceName}" `
        -Body $knowledgeSourceBody `
        -RetryErrorPattern "Credentials provided in the connection string are invalid or have expired"
    $action = $knowledgeSourceExists ? "updated" : "created"
    Write-Host "  Knowledge Source '${KnowledgeSourceName}' ${action}." -ForegroundColor Green
}
catch {
    $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw "Failed to deploy Knowledge Source '${KnowledgeSourceName}': $detail"
}

# ===========================================================================
# Phase 2 — Ensure the Knowledge Base exists (query/answer layer)
# ===========================================================================
Write-Host ""
Write-Host "Phase 2/4: Knowledge Base" -ForegroundColor White

$knowledgeBaseBody = @{
    name                     = $KnowledgeBaseName
    description              = ""
    retrievalInstructions    = ""
    answerInstructions       = $null
    outputMode               = "answerSynthesis"
    knowledgeSources         = @(@{ name = $KnowledgeSourceName })
    models                   = @(@{
        kind = "azureOpenAI"
        azureOpenAIParameters = @{
            resourceUri = $OpenAIEndpoint; deploymentId = $AnswerSynthesisDeployment
            apiKey = $null; modelName = $ChatCompletionModelName; authIdentity = $null
        }
    })
    encryptionKey            = $null
    retrievalReasoningEffort = @{ kind = "medium" }
}
try {
    $null = Invoke-Search -Method Put -Path "knowledgebases/${KnowledgeBaseName}" -Body $knowledgeBaseBody
    Write-Host "  Knowledge Base '${KnowledgeBaseName}' deployed." -ForegroundColor Green
}
catch {
    $detail = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw "Failed to deploy Knowledge Base '${KnowledgeBaseName}': $detail"
}

# ===========================================================================
# Phase 3 — Discover the managed indexer(s) ROBUSTLY (fail loudly)
# ===========================================================================
Write-Host ""
Write-Host "Phase 3/4: Discovering managed indexer(s)" -ForegroundColor White

function Find-KbIndexers {
    $all = (Invoke-Search -Method Get -Path "indexers").value
    # Match on any signal that ties an indexer to this Knowledge Base.
    $hits = $all | Where-Object {
        $_.name            -like "*$KnowledgeBaseName*" -or
        $_.dataSourceName  -like "*$KnowledgeBaseName*" -or
        $_.skillsetName    -like "*$KnowledgeBaseName*" -or
        $_.targetIndexName -like "*$KnowledgeBaseName*"
    }
    return @($hits)
}

# The KS provisions its indexer asynchronously — poll until it appears.
$kbIndexers = @()
$waited = 0
do {
    $kbIndexers = Find-KbIndexers
    if ($kbIndexers.Count -gt 0) { break }
    Start-Sleep -Seconds 10; $waited += 10
    Write-Host "  Waiting for managed indexer to appear... (${waited}s)" -ForegroundColor Gray
} while ($waited -lt $IndexerWaitSeconds)

if ($kbIndexers.Count -eq 0) {
    $allNames = (Invoke-Search -Method Get -Path "indexers").value |
        ForEach-Object { "    - name='$($_.name)' datasource='$($_.dataSourceName)' index='$($_.targetIndexName)' skillset='$($_.skillsetName)'" }
    throw @"
No managed indexer found for Knowledge Base '${KnowledgeBaseName}' after ${IndexerWaitSeconds}s.
This is exactly the condition the original script hid behind Write-Warning.
Indexers currently present on the service:
$([string]::Join([Environment]::NewLine, $allNames))
Adjust -KnowledgeBaseName, or inspect the names above to confirm the KS provisioned correctly.
"@
}

# Derive the REAL index and skillset names from the indexer itself — no guessing.
$primary      = $kbIndexers[0]
$IndexName    = $primary.targetIndexName
$SkillsetName = $primary.skillsetName
Write-Host "  Found $($kbIndexers.Count) indexer(s). Using index '$IndexName', skillset '$SkillsetName'." -ForegroundColor Green

& azd env set AZURE_AI_SEARCH_INDEX_NAME $IndexName
if ($LASTEXITCODE -ne 0) {
    throw "Failed to save the managed index name in the azd environment."
}

# ===========================================================================
# Phase 4 — Configure indexer settings
# ===========================================================================
Write-Host ""
Write-Host "Phase 4/4: Configure indexer settings" -ForegroundColor White

# Ensure content and metadata extraction and allow the skillset to access file data.
foreach ($ix in $kbIndexers) {
    $n  = $ix.name
    $iz = Invoke-Search -Method Get -Path "indexers/${n}"
    $changed = $false

    if ($null -eq $iz.parameters) {
        $iz | Add-Member -NotePropertyName parameters -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if ($null -eq $iz.parameters.configuration) {
        $iz.parameters | Add-Member -NotePropertyName configuration -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    $cur = $iz.parameters.configuration.dataToExtract
    if ($cur -ne 'contentAndMetadata') {
        Write-Host "  Indexer '$n': dataToExtract '$cur' -> 'contentAndMetadata'." -ForegroundColor Yellow
        $iz.parameters.configuration | Add-Member -NotePropertyName dataToExtract -NotePropertyValue 'contentAndMetadata' -Force
        $changed = $true
    }
    if (-not [string]::IsNullOrEmpty($iz.skillsetName)) {
        $p = $iz.parameters.configuration.PSObject.Properties['allowSkillsetToReadFileData']
        if ($null -eq $p -or $p.Value -ne $true) {
            Write-Host "  Indexer '$n': allowSkillsetToReadFileData -> true." -ForegroundColor Yellow
            $iz.parameters.configuration | Add-Member -NotePropertyName allowSkillsetToReadFileData -NotePropertyValue $true -Force
            $changed = $true
        }
    }
    if ($changed) {
        $null = Invoke-Search -Method Put -Path "indexers/${n}" -Body (Remove-ReadOnly $iz)
        Write-Host "  Indexer '$n': updated." -ForegroundColor Green
    } else {
        Write-Host "  Indexer '$n': already correct." -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " SUCCESS — Configuration deployed successfully.   " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Cyan
exit 0
