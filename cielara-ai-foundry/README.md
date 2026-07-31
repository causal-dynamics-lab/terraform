# Cielara AI Foundry (data plane models)

Provisions the Azure AI Foundry resource the Cielara data plane needs, with the
model deployments the data plane resolves by name:

| Deployment name          | Category            | Selected by default | Source of truth                                            |
| ------------------------ | ------------------- | ------------------- | ---------------------------------------------------------- |
| `gpt-5.5`                | reasoning           | yes                 | core `internal/llmprovider/categories.go` azure_openai row |
| `gpt-5.3-codex`          | coding              | yes                 | same                                                       |
| `gpt-5.4-mini`           | mini                | yes                 | same                                                       |
| `text-embedding-3-small` | embedding           | yes                 | same                                                       |
| `gpt-5.6-luna`           | reasoning \| coding | no                  | core `ProviderModels` azure_openai row                     |

`gpt-5.6-luna` is an *alternative* the web app offers for the reasoning and
coding categories. It has to be deployed for an operator to be able to select
it, but nothing points at it until someone picks it under **Admin > Models**.

Deployment names are load-bearing — the data plane looks models up by
deployment name, so keep them equal to the model names unless you also change
the model selection in the data-plane web app (Admin > Models).

## Usage

```bash
cd cielara-ai-foundry
terraform init
terraform apply \
  -var subscription_id=<sub-id> \
  -var tenant_id=<tenant-id> \
  -var environment=staging
```

Auth: `az login` (or `ARM_*` env vars) works out of the box; set
`azure_client_id` / `azure_client_secret` for non-interactive SP auth.

## Outputs

```bash
terraform output endpoint          # Azure OpenAI endpoint for the data-plane web app
terraform output -raw api_key      # API key (sensitive)
terraform output deployment_names
```

Paste `endpoint` + `api_key` into the data-plane web app under
**Admin > Models** (or the first-launch setup page).

## Notes

- The account is kind `AIServices` (Azure AI Foundry), SKU `S0`, with a custom
  subdomain derived from `name_prefix`-`environment` — the subdomain must be
  globally unique, so pick a distinctive `name_prefix`/`environment` pair.
- `model_deployments` is overridable; `version = null` (default) tracks the
  model's current default version. Capacity is in 1K-TPM units.
- Model availability varies by region; the `eastus2` default carries the full
  set above.
