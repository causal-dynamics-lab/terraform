# verify

Standalone helper that reads the infra-version marker back **as the deployer
itself** — it authenticates with the `cielara-key.json` the prepare apply
wrote, so a successful read proves the Cielara control plane's identity can
reach the marker. It is deliberately a root module with its own provider
block, not part of the published module's resource graph. Run it from the
folder you applied the prepare module in:

```bash
terraform -chdir=.terraform/modules/cielara_prepare/verify init
terraform -chdir=.terraform/modules/cielara_prepare/verify apply \
  -var key_path=../../../../cielara-key.json
```

A 403 in the first minute or two is IAM propagation — retry.
