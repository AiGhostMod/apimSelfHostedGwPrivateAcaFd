# Mock API

The non-root container runs a small WSGI application on port **8080** with
Gunicorn. Runtime dependencies are pinned in `requirements.txt`; Python's standard
library alone is sufficient for the local tests:

```sh
cd mock-api
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

| Request | Response |
| --- | --- |
| `GET /get` | `{"method":"GET","path":"/get","service":"mock-api"}` |
| `POST /post` | Same metadata for POST, plus `json` containing the supplied JSON value |
| `GET /health` | HTTP 200, `{"status":"ok"}` |

POST accepts objects, arrays, strings, numbers, booleans, and `null`. Invalid JSON
returns 400, bodies larger than 1 MiB return 413, unsupported methods return 405
with `Allow`, and unknown routes return 404. This is an echo service: don't send
credentials or confidential payloads. Health probes run against `/health`.

## Image lifecycle

Terraform hashes `Dockerfile`, `requirements.txt`, `.dockerignore`, and all `app/`
files to generate the image tag. `terraform_data.mock_image` runs
`scripts/build-image.sh` **during apply**, using the authenticated Azure CLI caller
and explicitly selected subscription. It invokes remote `az acr build`; no local
Docker daemon or ACR admin credentials are needed. The caller needs ACR Tasks
build permissions (for example, Contributor on the registry), in addition to
deployment and role-assignment permissions. Tests and documentation are excluded
from the uploaded build context.

The app depends on completion of that build and a managed identity's AcrPull
assignment. `acr_role_propagation_wait` defaults to `180s`; Azure role propagation
is eventually consistent, so increase the wait and retry apply if necessary.
If a tagged image is manually deleted, use
`terraform apply -replace=terraform_data.mock_image` to rebuild it. A changed
Docker base image behind the same pinned tag also requires an explicit rebuild;
this lab does not run automatic vulnerability or base-image refresh jobs.

## Private ingress

Both boundaries matter: the environment has an internal load balancer and
`public_network_access = "Disabled"`, while the mock app itself has
**`external_enabled = true`**. Here “external” means **outside the ACA environment
but still private to the VNet**, not internet-accessible. This is intentional:
setting it to `false` would return HTTP 404 to managed APIM in the separate subnet.
Both managed and self-hosted gateways use the same mock app directly; no relay is
required.

Ingress allow rules admit only the APIM and ACA subnet CIDRs; other source
addresses are denied. Front Door must never have a mock origin or route: its
origins are the APIM gateways only. The generic ACA IP-restriction documentation
does not specify Private Endpoint source-address translation, so the allowlist
alone is not a verified isolation guarantee against a future, incorrectly
configured Front Door mock origin. Keep that routing invariant and verify both
gateway paths and negative direct-backend access after deployment. No cloud
deployment or source-address behavior was tested by the local unit tests.

See Microsoft's [VNet-only ingress configuration](https://learn.microsoft.com/en-us/azure/container-apps/ingress-overview#restrict-an-app-to-virtual-network-access-only)
and [IP restrictions](https://learn.microsoft.com/en-us/azure/container-apps/ip-restrictions).
