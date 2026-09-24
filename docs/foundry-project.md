# Foundry project and realtime model

The deployment creates a project-enabled Microsoft Foundry resource, a Foundry
project, an Entra-authenticated project connection to the resource, and a GPT
Realtime deployment. The Container App uses its managed identity and the
`Cognitive Services User` role; no model credentials are stored in source or
application settings.

## Prerequisites and region selection

The deploying principal needs Contributor and Role Based Access Control
Administrator at subscription scope. Register the `Microsoft.CognitiveServices`
provider and choose a region that supports both Voice Live and the requested
model version and deployment SKU.

Before provisioning, the hook queries the current subscription inventory with:

```shell
az cognitiveservices model list --location <region> -o table
```

The default is the latest generally available GPT Realtime release validated
for this template:

| Setting | Default |
|---|---|
| `AZURE_VOICE_LIVE_MODEL_NAME` | `gpt-realtime-2.1` |
| `AZURE_VOICE_LIVE_MODEL_VERSION` | `2026-07-07` |
| `AZURE_VOICE_LIVE_DEPLOYMENT_NAME` | `gpt-realtime` |
| `AZURE_VOICE_LIVE_MODEL_SKU` | `GlobalStandard` |
| `AZURE_VOICE_LIVE_MODEL_CAPACITY` | `1` |

Availability and quota vary by subscription and region. If the exact
model/version/SKU is unavailable, `azd up` stops before provisioning with the
inventory command and settings to change. Azure Resource Manager remains the
authoritative quota and capacity check and identifies the
`realtimeDeployment` resource if allocation fails.

## Deploy and validate

Run `azd up`, then open the `AZURE_AI_FOUNDRY_PROJECT_ID` output in the Foundry
portal. Confirm that the project contains the `realtime-models` connection and
that the parent Foundry resource contains the configured deployment.

Open the application URL and start a browser conversation. Verify microphone
audio is streamed while response audio plays, speak during a response to test
interruption handling, and review Container App logs for Voice Live session or
quota errors.

## Select or upgrade a model

List available versions first, then set all deployment inputs and reprovision:

```shell
az cognitiveservices model list --location <region> -o table
azd env set AZURE_VOICE_LIVE_MODEL_NAME <catalog-model>
azd env set AZURE_VOICE_LIVE_MODEL_VERSION <version>
azd env set AZURE_VOICE_LIVE_DEPLOYMENT_NAME <deployment-name>
azd env set AZURE_VOICE_LIVE_MODEL_SKU <sku>
azd env set AZURE_VOICE_LIVE_MODEL_CAPACITY <capacity>
azd provision
azd deploy
```

The application always receives the deployment name through `VOICE_LIVE_MODEL`,
so compatible releases require configuration and provisioning changes but no
application code change. The template pins the model version and disables
automatic upgrades to keep production behavior repeatable.

This realtime deployment is also the default runtime path when Foundry IQ is
disabled. To route Voice Live sessions through a grounded prompt agent and an
Azure AI Search knowledge base instead, follow
[Foundry IQ knowledge for voice calls](./foundry-iq.md). That path
provisions additional chat and embedding model deployments; changing the
realtime model settings does not change those Foundry IQ deployments.

Project connections use Entra authentication. Add credentials only when
connecting the project to an external service that cannot use Entra ID; store
such credentials in Key Vault rather than in parameters or source control.
