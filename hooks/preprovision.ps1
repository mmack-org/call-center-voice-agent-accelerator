<#
.SYNOPSIS
    Pre-provision hook — validates prerequisites and configures optional telephony provider.
#>

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Voice Agent Accelerator - Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Check required tools ---
$missing = @()
if (-not (Get-Command "azd" -ErrorAction SilentlyContinue)) { $missing += "azd" }
if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) { $missing += "az CLI" }

if ($missing.Count -gt 0) {
    Write-Host "ERROR: Missing required tools: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Install from: https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd"
    exit 1
}

# --- Validate Azure login ---
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "ERROR: Not logged in to Azure. Run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

az provider register --namespace Microsoft.Fabric --wait --output none
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Unable to register the Microsoft.Fabric resource provider." -ForegroundColor Red
    exit 1
}

$fabricAdmin = azd env get-value FABRIC_CAPACITY_ADMIN 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fabricAdmin)) {
    $fabricAdmin = $account.user.name
    if ([string]::IsNullOrWhiteSpace($fabricAdmin)) {
        Write-Host "ERROR: FABRIC_CAPACITY_ADMIN must be set to a Fabric administrator UPN." -ForegroundColor Red
        exit 1
    }
    azd env set FABRIC_CAPACITY_ADMIN $fabricAdmin
}
$fabricLocation = azd env get-value FABRIC_LOCATION 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fabricLocation)) {
    $fabricLocation = azd env get-value AZURE_LOCATION 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fabricLocation)) {
        Write-Host "ERROR: FABRIC_LOCATION or AZURE_LOCATION must be set." -ForegroundColor Red
        exit 1
    }
    azd env set FABRIC_LOCATION $fabricLocation
}

# --- Model selection and availability validation ---
$modelName = azd env get-value AZURE_VOICE_LIVE_MODEL_NAME 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($modelName)) {
    $modelName = "gpt-realtime-2.1"
    azd env set AZURE_VOICE_LIVE_MODEL_NAME $modelName
}
$modelVersion = azd env get-value AZURE_VOICE_LIVE_MODEL_VERSION 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($modelVersion)) {
    $modelVersion = "2026-07-07"
    azd env set AZURE_VOICE_LIVE_MODEL_VERSION $modelVersion
}
$deploymentName = azd env get-value AZURE_VOICE_LIVE_DEPLOYMENT_NAME 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deploymentName)) {
    $deploymentName = "gpt-realtime"
    azd env set AZURE_VOICE_LIVE_DEPLOYMENT_NAME $deploymentName
}
$modelSku = azd env get-value AZURE_VOICE_LIVE_MODEL_SKU 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($modelSku)) {
    $modelSku = "GlobalStandard"
    azd env set AZURE_VOICE_LIVE_MODEL_SKU $modelSku
}
$selectedLocation = azd env get-value AZURE_LOCATION 2>$null
if ($LASTEXITCODE -ne 0) { $selectedLocation = "" }

Write-Host "Foundry model: $modelName ($modelVersion), deployment: $deploymentName, SKU: $modelSku" -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($selectedLocation)) {
    $modelInventory = az cognitiveservices model list --location $selectedLocation --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Unable to query the Foundry model inventory for '$selectedLocation'." -ForegroundColor Red
        Write-Host "Verify Microsoft.CognitiveServices is registered and your account can list models, then retry." -ForegroundColor Yellow
        exit 1
    }

    $matchingModel = @($modelInventory | ConvertFrom-Json | Where-Object {
        $_.model.name -eq $modelName -and $_.model.version -eq $modelVersion
    }) | Select-Object -First 1
    $availableSkus = @($matchingModel.model.skus | ForEach-Object { $_.name })
    if (-not $matchingModel -or $modelSku -notin $availableSkus) {
        Write-Host "ERROR: Foundry model '$modelName' version '$modelVersion' with SKU '$modelSku' is unavailable in '$selectedLocation'." -ForegroundColor Red
        Write-Host "Choose a supported region/model/version/SKU from:" -ForegroundColor Yellow
        Write-Host "  az cognitiveservices model list --location $selectedLocation -o table"
        Write-Host "Then set AZURE_VOICE_LIVE_MODEL_NAME, AZURE_VOICE_LIVE_MODEL_VERSION, and AZURE_VOICE_LIVE_MODEL_SKU with 'azd env set'." -ForegroundColor Yellow
        exit 1
    }
}

# --- Telephony configuration ---
$twilioToken = azd env get-value TWILIO_AUTH_TOKEN 2>$null
if ($LASTEXITCODE -ne 0) { $twilioToken = "" }
$infobipKey = azd env get-value INFOBIP_API_KEY 2>$null
if ($LASTEXITCODE -ne 0) { $infobipKey = "" }
$genesysKey = azd env get-value GENESYS_API_KEY 2>$null
if ($LASTEXITCODE -ne 0) { $genesysKey = "" }
$sinchKey = azd env get-value SINCH_APPLICATION_KEY 2>$null
if ($LASTEXITCODE -ne 0) { $sinchKey = "" }
$bandwidthToken = azd env get-value BANDWIDTH_CLIENT_ID 2>$null
if ($LASTEXITCODE -ne 0) { $bandwidthToken = "" }

if ([string]::IsNullOrWhiteSpace($twilioToken) -and [string]::IsNullOrWhiteSpace($infobipKey) -and [string]::IsNullOrWhiteSpace($genesysKey) -and [string]::IsNullOrWhiteSpace($sinchKey) -and [string]::IsNullOrWhiteSpace($bandwidthToken)) {
    Write-Host ""
    Write-Host "Telephony Provider Selection" -ForegroundColor Yellow
    Write-Host "----------------------------"
    Write-Host "No telephony credentials detected. Choose a provider:"
    Write-Host ""
    Write-Host "  [1] Azure Communication Services (default - no extra credentials needed)"
    Write-Host "  [2] Twilio (requires Auth Token)"
    Write-Host "  [3] Infobip (requires API Key + Base URL)"
    Write-Host "  [4] Genesys AudioHook Audio Connector (requires API Key)"
    Write-Host "  [5] Sinch (requires Application Key + Secret)"
    Write-Host "  [6] Bandwidth Programmable Voice (requires Account ID + Client ID + Secret)"
    Write-Host ""
    $choice = Read-Host "Select provider [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

    switch ($choice) {
        "2" {
            $sid = Read-Host "Enter Twilio Account SID"
            if ($sid -notmatch '^AC[a-f0-9]{32}$') {
                Write-Host "ERROR: Invalid Twilio Account SID format (expected AC + 32 hex characters)." -ForegroundColor Red
                exit 1
            }
            $token = Read-Host "Enter Twilio Auth Token" -AsSecureString
            $tokenPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))
            if ($tokenPlain.Length -ne 32 -or $tokenPlain -notmatch '^[a-f0-9]+$') {
                Write-Host "ERROR: Invalid Twilio Auth Token format (expected 32 hex characters)." -ForegroundColor Red
                exit 1
            }
            # Validate credentials against Twilio API
            Write-Host "Validating Twilio credentials..." -ForegroundColor Gray
            $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${sid}:${tokenPlain}"))
            try {
                $resp = Invoke-RestMethod -Uri "https://api.twilio.com/2010-04-01/Accounts/$sid.json" `
                    -Headers @{ Authorization = "Basic $authHeader" } -Method Get -ErrorAction Stop
                Write-Host "Twilio account verified: $($resp.friendly_name)" -ForegroundColor Green
            }
            catch {
                $status = $_.Exception.Response.StatusCode.value__
                if ($status -eq 401) {
                    Write-Host "ERROR: Twilio credentials are invalid (401 Unauthorized)." -ForegroundColor Red
                }
                else {
                    Write-Host "ERROR: Failed to validate Twilio credentials (HTTP $status)." -ForegroundColor Red
                }
                exit 1
            }
            azd env set TWILIO_ACCOUNT_SID $sid
            azd env set TWILIO_AUTH_TOKEN $tokenPlain
            azd env set TELEPHONY_PROVIDER twilio
            Write-Host "Twilio configured." -ForegroundColor Green
        }
        "3" {
            $key = Read-Host "Enter Infobip API Key" -AsSecureString
            $keyPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($key))
            $baseUrl = Read-Host "Enter Infobip API Base URL (e.g. https://xxxxx.api.infobip.com)"
            $baseUrl = $baseUrl.TrimEnd('/')
            if ($baseUrl -notmatch '^https?://') { $baseUrl = "https://$baseUrl" }
            if ($baseUrl -notmatch '^https://[a-z0-9]+\.api(-[a-z0-9]+)?\.infobip\.com$') {
                Write-Host "ERROR: Invalid Infobip Base URL format." -ForegroundColor Red
                Write-Host "  Expected: https://<id>.api.infobip.com or https://<id>.api-<region>.infobip.com" -ForegroundColor Gray
                exit 1
            }
            # Validate credentials against Infobip API
            try {
                $resp = Invoke-WebRequest -Uri "$baseUrl/settings/1/accounts" `
                    -Headers @{Authorization = "App $keyPlain"} -UseBasicParsing -ErrorAction Stop
                Write-Host "Infobip credentials validated." -ForegroundColor Green
            }
            catch {
                $status = $_.Exception.Response.StatusCode.value__
                if ($status -eq 401) {
                    Write-Host "ERROR: Infobip API key is invalid (401 Unauthorized)." -ForegroundColor Red
                    exit 1
                }
                # 403 means key is recognized but lacks admin scope — still valid for calls
                Write-Host "Infobip API key verified." -ForegroundColor Green
            }
            azd env set INFOBIP_API_KEY $keyPlain
            azd env set INFOBIP_API_BASE_URL $baseUrl
            azd env set TELEPHONY_PROVIDER infobip
            Write-Host "Infobip configured." -ForegroundColor Green
        }
        "4" {
            Write-Host ""
            Write-Host "Genesys AudioHook Audio Connector" -ForegroundColor Yellow
            Write-Host "This key authenticates Genesys Cloud when it connects to your /audiohook/ws endpoint."
            Write-Host "You define this value and configure the same key in Genesys Cloud."
            Write-Host ""
            $gKey = Read-Host "Enter API Key for AudioHook authentication"
            if ([string]::IsNullOrWhiteSpace($gKey)) {
                Write-Host "ERROR: API Key is required." -ForegroundColor Red
                exit 1
            }
            azd env set GENESYS_API_KEY $gKey
            azd env set TELEPHONY_PROVIDER genesys
            Write-Host "Genesys AudioHook configured." -ForegroundColor Green
            Write-Host ""
            Write-Host "After deployment, the post-deploy script will show your WebSocket URL and simulator link." -ForegroundColor Cyan
        }
        "5" {
            Write-Host ""
            Write-Host "Sinch Voice (connectStream)" -ForegroundColor Yellow
            Write-Host "Find these in the Sinch dashboard under Voice > Apps."
            Write-Host ""
            $sKey = Read-Host "Enter Sinch Application Key"
            if ([string]::IsNullOrWhiteSpace($sKey)) {
                Write-Host "ERROR: Application Key is required." -ForegroundColor Red
                exit 1
            }
            $sSecret = Read-Host "Enter Sinch Application Secret" -AsSecureString
            $sSecretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sSecret))
            if ([string]::IsNullOrWhiteSpace($sSecretPlain)) {
                Write-Host "ERROR: Application Secret is required." -ForegroundColor Red
                exit 1
            }
            azd env set SINCH_APPLICATION_KEY $sKey
            azd env set SINCH_APPLICATION_SECRET $sSecretPlain
            azd env set TELEPHONY_PROVIDER sinch
            Write-Host "Sinch configured." -ForegroundColor Green
            Write-Host ""
            Write-Host "After deployment, the post-deploy script will show the callback URL to configure in the Sinch dashboard." -ForegroundColor Cyan
        }
        "6" {
            Write-Host ""
            Write-Host "Bandwidth Programmable Voice" -ForegroundColor Yellow
            Write-Host "Provide your OAuth 2.0 API credentials (Client ID + Client Secret). The Account"
            Write-Host "ID is required in every API path; the Voice Application and callback URL are"
            Write-Host "configured automatically post-deploy."
            Write-Host ""
            $bwAccountId = Read-Host "Enter Bandwidth Account ID"
            if ([string]::IsNullOrWhiteSpace($bwAccountId)) {
                Write-Host "ERROR: Account ID is required." -ForegroundColor Red
                exit 1
            }
            $bwToken = Read-Host "Enter Bandwidth Client ID"
            if ([string]::IsNullOrWhiteSpace($bwToken)) {
                Write-Host "ERROR: Client ID is required." -ForegroundColor Red
                exit 1
            }
            $bwSecret = Read-Host "Enter Bandwidth Client Secret" -AsSecureString
            $bwSecretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($bwSecret))
            if ([string]::IsNullOrWhiteSpace($bwSecretPlain)) {
                Write-Host "ERROR: Client Secret is required." -ForegroundColor Red
                exit 1
            }
            # Validate credentials via the Bandwidth OAuth 2.0 token endpoint
            # (client_credentials grant). The legacy username/password Basic Auth
            # scheme is deprecated and no longer provisionable. The two calls are
            # kept in separate try/catch blocks so we can tell whether the token
            # exchange itself failed (bad Client ID/Secret) or the account access
            # check failed (credential lacks the right roles/accounts).
            Write-Host "Validating Bandwidth credentials..." -ForegroundColor Gray
            $bwAuthHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${bwToken}:${bwSecretPlain}"))

            # --- Step 1: exchange Client ID/Secret for an OAuth bearer token ---
            $bwAccessToken = ""
            try {
                $bwTokenResp = Invoke-RestMethod -Uri "https://api.bandwidth.com/api/v1/oauth2/token" `
                    -Headers @{ Authorization = "Basic $bwAuthHeader" } -Method Post `
                    -ContentType "application/x-www-form-urlencoded" `
                    -Body "grant_type=client_credentials" -ErrorAction Stop
                $bwAccessToken = $bwTokenResp.access_token
            }
            catch {
                $status = $_.Exception.Response.StatusCode.value__
                Write-Host "ERROR: OAuth token exchange failed (HTTP $status) at api.bandwidth.com/api/v1/oauth2/token." -ForegroundColor Red
                if ($status -eq 401) {
                    Write-Host "  The Client ID or Client Secret is incorrect, the credential is inactive," -ForegroundColor Gray
                    Write-Host "  or the secret has expired. Recreate/rotate it under Account > API Credentials." -ForegroundColor Gray
                }
                exit 1
            }
            if ([string]::IsNullOrWhiteSpace($bwAccessToken)) {
                Write-Host "ERROR: Bandwidth token response did not contain an access_token." -ForegroundColor Red
                exit 1
            }
            Write-Host "OAuth token obtained." -ForegroundColor Green

            # --- Step 2: confirm the token can reach the target account ---
            try {
                Invoke-RestMethod -Uri "https://api.bandwidth.com/api/accounts/$bwAccountId/applications" `
                    -Headers @{ Authorization = "Bearer $bwAccessToken" } -Method Get `
                    -ContentType "application/xml" -ErrorAction Stop | Out-Null
                Write-Host "Bandwidth account verified: $bwAccountId" -ForegroundColor Green
            }
            catch {
                $status = $_.Exception.Response.StatusCode.value__
                if ($status -eq 401 -or $status -eq 403) {
                    Write-Host "ERROR: The credential authenticated, but lacks access to account '$bwAccountId' (HTTP $status)." -ForegroundColor Red
                    Write-Host "  Edit the API Credential (Account > API Credentials) and ensure it includes" -ForegroundColor Gray
                    Write-Host "  this account and a role granting Dashboard/Numbers (application) access." -ForegroundColor Gray
                }
                elseif ($status -eq 404) {
                    Write-Host "ERROR: Bandwidth Account ID '$bwAccountId' not found (404)." -ForegroundColor Red
                }
                else {
                    Write-Host "ERROR: Failed to validate Bandwidth account access (HTTP $status)." -ForegroundColor Red
                }
                exit 1
            }
            azd env set BANDWIDTH_ACCOUNT_ID $bwAccountId
            azd env set BANDWIDTH_CLIENT_ID $bwToken
            azd env set BANDWIDTH_CLIENT_SECRET $bwSecretPlain
            azd env set TELEPHONY_PROVIDER bandwidth
            Write-Host "Bandwidth configured." -ForegroundColor Green
            Write-Host ""
            Write-Host "After deployment, the post-deploy script will create/point the Voice application" -ForegroundColor Cyan
            Write-Host "at your container app. You then associate a phone number's Location with it." -ForegroundColor Cyan
        }
        default {
            azd env set TELEPHONY_PROVIDER acs
            Write-Host "Using Azure Communication Services (will be provisioned automatically)." -ForegroundColor Green
        }
    }
}
else {
    if (-not [string]::IsNullOrWhiteSpace($twilioToken)) {
        azd env set TELEPHONY_PROVIDER twilio
        Write-Host "Telephony: Twilio (credentials detected)" -ForegroundColor Green
    }
    elseif (-not [string]::IsNullOrWhiteSpace($infobipKey)) {
        azd env set TELEPHONY_PROVIDER infobip
        Write-Host "Telephony: Infobip (credentials detected)" -ForegroundColor Green
    }
    elseif (-not [string]::IsNullOrWhiteSpace($genesysKey)) {
        azd env set TELEPHONY_PROVIDER genesys
        Write-Host "Telephony: Genesys AudioHook (credentials detected)" -ForegroundColor Green
    }
    elseif (-not [string]::IsNullOrWhiteSpace($sinchKey)) {
        azd env set TELEPHONY_PROVIDER sinch
        Write-Host "Telephony: Sinch (credentials detected)" -ForegroundColor Green
    }
    elseif (-not [string]::IsNullOrWhiteSpace($bandwidthToken)) {
        azd env set TELEPHONY_PROVIDER bandwidth
        Write-Host "Telephony: Bandwidth (credentials detected)" -ForegroundColor Green
    }
    else {
        azd env set TELEPHONY_PROVIDER acs
    }
}

Write-Host ""
Write-Host "Pre-provisioning checks passed. Proceeding..." -ForegroundColor Green
Write-Host ""
