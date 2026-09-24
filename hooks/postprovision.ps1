$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-AzdEnvironmentValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [switch] $Required
    )

    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            throw "Required azd environment value '$Name' is not set."
        }
        return ""
    }

    return $value.Trim()
}

function Get-AzureAccessToken {
    param(
        [Parameter(Mandatory)]
        [string] $Resource
    )

    $token = az account get-access-token --resource $Resource --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Unable to obtain an Azure access token for '$Resource'. Run 'az login' and retry."
    }

    return $token.Trim()
}

function Invoke-AzureRequest {
    param(
        [Parameter(Mandatory)]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [string] $Token,
        [string] $Body = ""
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ Authorization = "Bearer $Token" }
        SkipHttpErrorCheck = $true
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $parameters.ContentType = "application/json"
        $parameters.Body = $Body
    }

    return Invoke-WebRequest @parameters
}

function Invoke-AzureRequestWithRetry {
    param(
        [Parameter(Mandatory)]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter(Mandatory)]
        [string] $Token,
        [string] $Body = "",
        [int] $Attempts = 12
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $response = $null
        try {
            $response = Invoke-AzureRequest -Method $Method -Uri $Uri -Token $Token -Body $Body
        }
        catch {
            $failure = $_.Exception.Message
        }

        if ($null -ne $response) {
            $statusCode = [int]$response.StatusCode
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                return $response
            }

            $failure = "HTTP ${statusCode}: $($response.Content)"
            $retryable = $statusCode -in 401, 403, 408, 409, 429 -or $statusCode -ge 500
            if (-not $retryable) {
                throw "$Method $Uri failed: $failure"
            }
        }

        if ($attempt -eq $Attempts) {
            throw "$Method $Uri failed after $Attempts attempts: $failure"
        }
        Start-Sleep -Seconds 10
    }
}

$searchEndpoint = Get-AzdEnvironmentValue -Name "AZURE_AI_SEARCH_ENDPOINT" -Required
$knowledgeBaseName = Get-AzdEnvironmentValue -Name "AZURE_FOUNDRY_IQ_KNOWLEDGE_BASE_NAME" -Required
$projectEndpoint = Get-AzdEnvironmentValue -Name "AZURE_AI_FOUNDRY_PROJECT_ENDPOINT" -Required
$projectConnectionName = Get-AzdEnvironmentValue -Name "AZURE_FOUNDRY_IQ_CONNECTION_NAME" -Required
$agentName = Get-AzdEnvironmentValue -Name "AZURE_AI_FOUNDRY_AGENT_ID" -Required
$agentModelDeployment = Get-AzdEnvironmentValue -Name "AZURE_AI_AGENT_MODEL_DEPLOYMENT" -Required

$searchApiVersion = "2026-08-01-preview"
$mcpEndpoint = "$searchEndpoint/knowledgebases/$knowledgeBaseName/mcp?api-version=$searchApiVersion"
$foundryToken = Get-AzureAccessToken -Resource "https://ai.azure.com"

$agentInstructions = @"
Vous êtes un agent de support de centre d'appels. Vous aidez les utilisateurs à
résoudre leurs demandes en vous appuyant sur la base de connaissances mise à
votre disposition.

Répondez en français par défaut, avec un ton professionnel, empathique et
naturel adapté à une conversation téléphonique. Utilisez l'outil de base de
connaissances pour toute question de support ou demande factuelle. Fondez chaque
réponse factuelle sur le contenu récupéré et n'inventez jamais d'information.
Utilisez l'outil Fabric uniquement en lecture pour les clients, produits installés
et tickets. Limitez chaque recherche au client authentifié et ne révélez jamais
les coordonnées, le corps des messages ou les commentaires CSAT.
Si la base ne contient pas assez d'éléments, dites-le clairement et proposez
une clarification. Si le problème reste sans solution, proposez de créer un ticket,
recueillez les informations minimales, résumez-les, puis demandez une confirmation
explicite. N'appelez create_support_ticket qu'après un oui non ambigu, une seule fois
avec une clé d'idempotence, puis lisez la référence retournée. N'appelez jamais cet
outil si l'utilisateur refuse. Donnez des réponses
courtes et directement actionnables. Ne lisez jamais à voix haute les URL, les
identifiants de source ni la syntaxe des citations.
"@.Trim()

$agentDefinition = @{
    kind = "prompt"
    model = $agentModelDeployment
    instructions = $agentInstructions
    tools = @(
        @{
            type = "mcp"
            server_label = "knowledge-base"
            server_url = $mcpEndpoint
            project_connection_id = $projectConnectionName
            require_approval = "never"
            allowed_tools = @("knowledge_base_retrieve")
        }
        @{
            type = "function"
            name = "fabric_retrieve_business_data"
            description = "Retrieve authorized customer, product, installed-base, or support-ticket information from Microsoft Fabric."
            strict = $true
            parameters = @{
                type = "object"
                additionalProperties = $false
                required = @("intent", "customer_key", "product_key", "ticket_id", "query")
                properties = @{
                    intent = @{
                        type = "string"
                        enum = @("customer", "installed_products", "product", "ticket", "similar_cases")
                    }
                    customer_key = @{ type = @("string", "null") }
                    product_key = @{ type = @("string", "null") }
                    ticket_id = @{ type = @("string", "null") }
                    query = @{ type = @("string", "null") }
                }
            }
        }
        @{
            type = "function"
            name = "create_support_ticket"
            description = "Create one support ticket only after explicit user confirmation."
            strict = $true
            parameters = @{
                type = "object"
                additionalProperties = $false
                required = @(
                    "customer_key", "contact_key", "product_key", "subject",
                    "description", "category", "priority", "user_confirmed",
                    "conversation_id", "idempotency_key"
                )
                properties = @{
                    customer_key = @{ type = "string" }
                    contact_key = @{ type = @("string", "null") }
                    product_key = @{ type = @("string", "null") }
                    subject = @{ type = "string"; minLength = 5; maxLength = 120 }
                    description = @{ type = "string"; minLength = 10; maxLength = 4000 }
                    category = @{ type = @("string", "null") }
                    priority = @{ type = "string"; enum = @("P1", "P2", "P3", "P4") }
                    user_confirmed = @{ type = "boolean"; const = $true }
                    conversation_id = @{ type = "string" }
                    idempotency_key = @{ type = "string" }
                }
            }
        }
    )
}

$agentUri = "$projectEndpoint/agents/$agentName`?api-version=v1"
$agentResponse = $null
for ($attempt = 1; $attempt -le 18; $attempt++) {
    $agentResponse = Invoke-AzureRequest -Method "GET" -Uri $agentUri -Token $foundryToken
    if ([int]$agentResponse.StatusCode -in 200, 404) {
        break
    }
    if ([int]$agentResponse.StatusCode -notin 401, 403) {
        break
    }
    Start-Sleep -Seconds 10
}

if ([int]$agentResponse.StatusCode -eq 404) {
    $agentBody = @{
        name = $agentName
        definition = $agentDefinition
    } | ConvertTo-Json -Depth 20 -Compress

    Invoke-AzureRequestWithRetry `
        -Method "POST" `
        -Uri "$projectEndpoint/agents?api-version=v1" `
        -Token $foundryToken `
        -Body $agentBody `
        -Attempts 18 | Out-Null
}
elseif ([int]$agentResponse.StatusCode -eq 200) {
    $existingAgent = $agentResponse.Content | ConvertFrom-Json
    if (
        $null -eq $existingAgent.PSObject.Properties["versions"] -or
        $null -eq $existingAgent.versions.PSObject.Properties["latest"] -or
        $null -eq $existingAgent.versions.latest.PSObject.Properties["definition"]
    ) {
        throw "Foundry returned an unexpected response shape for agent '$agentName'."
    }
    $existingDefinition = $existingAgent.versions.latest.definition
    $existingTool = @($existingDefinition.tools) |
        Where-Object { $_.type -eq "mcp" -and $_.server_label -eq "knowledge-base" } |
        Select-Object -First 1
    $existingFabricTool = @($existingDefinition.tools) |
        Where-Object { $_.type -eq "function" -and $_.name -eq "fabric_retrieve_business_data" } |
        Select-Object -First 1
    $existingTicketTool = @($existingDefinition.tools) |
        Where-Object { $_.type -eq "function" -and $_.name -eq "create_support_ticket" } |
        Select-Object -First 1
    $existingAllowedTools = @()
    if ($null -ne $existingTool -and $null -ne $existingTool.PSObject.Properties["allowed_tools"]) {
        $allowedTools = $existingTool.allowed_tools
        $existingAllowedTools = if (
            $null -ne $allowedTools -and
            $null -ne $allowedTools.PSObject.Properties["tool_names"]
        ) {
            @($allowedTools.tool_names)
        } else {
            @($allowedTools)
        }
    }
    $definitionChanged = (
        $existingDefinition.kind -ne $agentDefinition.kind -or
        $existingDefinition.model -ne $agentDefinition.model -or
        $existingDefinition.instructions -ne $agentDefinition.instructions -or
        $null -eq $existingTool -or
        $null -eq $existingFabricTool -or
        $null -eq $existingTicketTool -or
        $existingTool.server_url -ne $mcpEndpoint -or
        $existingTool.project_connection_id -ne $projectConnectionName -or
        $existingTool.require_approval -ne "never" -or
        @($existingAllowedTools).Count -ne 1 -or
        @($existingAllowedTools)[0] -ne "knowledge_base_retrieve"
    )

    if ($definitionChanged) {
        $agentVersionBody = @{
            definition = $agentDefinition
        } | ConvertTo-Json -Depth 20 -Compress

        Invoke-AzureRequestWithRetry `
            -Method "POST" `
            -Uri "$projectEndpoint/agents/$agentName/versions?api-version=v1" `
            -Token $foundryToken `
            -Body $agentVersionBody `
            -Attempts 18 | Out-Null
    }
}
else {
    throw "Unable to query Foundry agent '$agentName' (HTTP $([int]$agentResponse.StatusCode)): $($agentResponse.Content)"
}

Write-Host "Foundry IQ project connection and agent configuration completed."
