# Private APIM self-hosted gateway lab

Terraform provisions a complete live Azure lab in a **new resource group**, including
its own virtual network and every required subnet. Sweden Central is the default
region. This is production-shaped networking, not a production service: APIM
`Developer_1` has **no SLA**. Nothing is deployed merely by reading this repository
or running its offline tests. `terraform apply` creates billable resources and runs
the image build.

## Request paths

Two distinct public Azure Front Door **Premium** HTTPS endpoints expose the same
custom mock API:

```text
managed endpoint /get
  -> Front Door Private Link
  -> private Application Gateway HTTP listener
  -> HTTPS APIM Developer_1, internal VNet mode
  -> custom mock API

self-hosted endpoint /get and /post
  -> Front Door Private Link to the ACA managed environment
  -> exactly one mcr.microsoft.com/azure-api-management/gateway:v2 replica
  -> same custom mock API
```

Classic Developer-tier APIM in internal VNet mode cannot use an inbound private
endpoint. Application Gateway provides the required Private Link bridge; Front
Door does not connect directly to an APIM private endpoint. The Application
Gateway listener is HTTP **inside the private path**; its APIM backend connection
uses HTTPS. Clients use HTTPS with certificate validation enabled.
The self-hosted gateway is configured for exactly one steady-state replica;
ACA revision rollouts can briefly overlap old and new revisions.

The self-hosted gateway's API association derives its revisionless API ID from
the API resource ID, removing only a trailing `;rev=...` suffix. This matches
Azure's canonical association ID and avoids replacement drift on later plans;
the API resource itself retains its configured revision.

Application Gateway uses conventional v2 deployment with an **unused Standard
public frontend IP**, because private-only Application Gateway deployment does
not support Private Link. Only the private frontend has the HTTP listener; the
public frontend does not expose an application listener. Do not enable the
`NetworkIsolation` feature for this design. Its NSG must retain the conventional
Application Gateway control-plane requirements: GatewayManager TCP 65200–65535,
AzureLoadBalancer probes, and required outbound internet access. See Microsoft's
[private-deployment limitations](https://learn.microsoft.com/azure/application-gateway/application-gateway-private-deployment#limitations--known-issues).
Private Link preserves client source addresses, so the listener NSG allows TCP
80 from any source **to the private gateway subnet**, rather than assuming
traffic originates in the Private Link configuration subnet. The public
frontend has no listener. Only explicitly matched Front Door private endpoint
requests are approved by the Terraform-invoked approval script.
Terraform reads the subscription's network-isolation feature state and blocks
creation if it is registered or changing; it never toggles that shared feature.
For this read-only [Features GET](https://learn.microsoft.com/rest/api/resources/features/get?view=rest-resources-2021-07-01),
AzAPI requires `Microsoft.Network/features@2021-07-01`; the resource ID still uses
the full `/providers/Microsoft.Features/providers/Microsoft.Network/features/...`
path.

**ACA “external” app ingress does not mean public internet ingress.** The mock
uses `external_enabled = true` in an **internal** Container Apps environment with
public network access disabled. This publishes it at the environment's private
load balancer so managed APIM in the neighboring subnet can reach it. Setting
the app flag to `false` would make it environment-only: APIM elsewhere in the
VNet would receive HTTP 404. This follows Microsoft's
[VNet-only ingress guidance](https://learn.microsoft.com/azure/container-apps/ingress-overview#restrict-an-app-to-virtual-network-access-only).
The mock's source restrictions allow only the APIM and ACA subnet ranges; it is
never configured as a Front Door origin. Front Door's self-hosted origin is the
gateway app, not the mock. Successful live smoke tests remain necessary to
validate the actual source addresses seen on the gateway-to-mock path; offline
validation cannot prove managed-service ingress behavior. Microsoft documents
allowlist default-deny behavior but does not guarantee the source identity seen
through every Private Link path. Therefore, the allowlist alone is not claimed
as verified protection against a misconfigured Front Door route: never add a
mock origin or arbitrary Host forwarding. Live acceptance should also confirm
that unapproved direct mock access is rejected.

Terraform creates `${name_prefix}-${random_suffix}-vnet` in the workload resource
group. `virtual_network_cidr` defaults to `10.47.0.0/24`; Terraform divides the
first half of that range into four equal, non-overlapping subnets:

| Subnet | Default prefix | Purpose |
| --- | --- | --- |
| APIM | `10.47.0.0/27` | Dedicated to classic APIM internal VNet injection. |
| ACA | `10.47.0.32/27` | Delegated to `Microsoft.App/environments`. |
| Application Gateway | `10.47.0.64/27` | Dedicated Application Gateway subnet. |
| Application Gateway Private Link configuration | `10.47.0.96/27` | Dedicated subnet with Private Link service policies disabled. |

You can supply another IPv4 `/16` through `/24`. The same derivation produces four
subnets between `/19` and `/27`, so each remains large enough for this template.
Choose a range that does not overlap networks you may later peer or route to this
VNet. Azure-provided DNS is used so the Terraform-created private DNS zones work
without a custom DNS forwarding dependency.

APIM and ACA each have a dedicated NAT gateway. Conventional Application Gateway
retains its required public infrastructure frontend and default outbound
allowances; its only backend is private APIM, so it does not need a separate NAT
gateway. APIM private DNS zones are scoped to the individual APIM hostnames, not
the whole `azure-api.net` namespace. ACA also creates Azure-managed infrastructure
in its own managed resource group; Terraform owns the environment, not the
platform's individual internal resources.
Internal classic APIM no longer requires a customer-supplied frontend public IP;
its NAT public IP is for outbound connectivity, not a public API listener.

Azure-provided DNS remains reachable without an explicit NSG allow rule.
`AzurePlatformDNS` is a service tag for **blocking** platform DNS, not an allowed
destination for an explicit `Allow` rule. Ordinary NSG rules, including the
APIM/ACA deny-all outbound rules, do not block platform DNS unless that tag is
explicitly targeted. The lab leaves it untargeted and preserves its other
custom egress rules. See Microsoft's
[platform considerations](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#azure-platform-considerations).

## Prerequisites and deployment

- Terraform matching `versions.tf`, Azure CLI (`az`), Python 3, and `curl`.
- An authenticated Azure CLI session in the intended tenant/subscription, with
  permission to create the workload and networking, manage
  role assignments and Private Link approvals, and build images in ACR.
- Availability/quota for Front Door Premium, Application Gateway, APIM
  Developer, Azure Container Apps, ACR, and associated networking in this region.
- A non-overlapping `virtual_network_cidr`; no pre-existing VNet or subnet is required.

> **Existing-state warning:** This standalone topology is intended for a fresh
> Terraform state. State created by the earlier shared-VNet version still points
> at external subnets and cannot be migrated in place to a new VNet. Applying this
> configuration against that state would replace APIM, ACA, Application Gateway,
> and related network attachments. Use a new backend/workspace/state for a parallel
> deployment, or deliberately tear down the old deployment with its matching old
> configuration first.

Docker is not required on the runner. Terraform invokes **`az acr build` at
apply time** to build and push the mock image; do not run a separate manual image
build/push. The build script resolves the `mock-api` context and Dockerfile from
its own location, independently of the caller's working directory. The apply
runner therefore needs Azure CLI access as well as the Terraform provider's
authentication. Inspect the existing Azure context before deploying:

```bash
az account show --query '{subscription:id,tenant:tenantId}' -o json
terraform init
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set publisher_email, verify tenant/subscription, and
# choose a non-overlapping virtual_network_cidr.
terraform plan -out=lab.tfplan
# Review the complete resource-group and VNet deployment before continuing.
terraform apply lab.tfplan
terraform output -json > terraform-outputs.json
bash scripts/test-endpoints.sh terraform-outputs.json
```

`terraform init` generates/updates `.terraform.lock.hcl`; review and commit that
lockfile when you intentionally commit the project. Do not commit Terraform
state, saved plans, local variable files, credentials, or output JSON. Treat the
entire state and plan as sensitive: **GatewayKey is stored in state even though
it is not exposed as an output**. Use access-controlled encrypted remote state
for shared use and protect local artifacts/backups as well.
Keep Terraform debug logging disabled (`unset TF_LOG TF_LOG_PATH`) when deploying
or rotating credentials; sensitive output markings do not make debug logs safe.

Allow **45–90+ minutes** for provisioning, followed by APIM configuration and
Front Door/Private Link propagation. Temporary 404/502/503 responses are possible
while configuration propagates. Front Door Premium, Application Gateway, APIM,
ACR, Container Apps, NAT/public IPs, logging and traffic can incur charges even
when you are not testing. Check current Azure pricing before applying.

Both Front Door origins are created before Terraform invokes
`scripts/approve-private-endpoints.sh`. The script checks the tenant and
subscription, matches each origin's distinctive request message, approves only
those connections, and waits for stable `Approved` status before routes are
created. Already-approved connections are safe to revisit. The default deadline
is **900 seconds** with 10-second polling; delayed appearance, concurrent ARM
operations, throttling and transient server errors are retried within the same
deadline. Authentication failures, rejected connections and malformed responses
fail explicitly. No portal approval is required. If Azure propagation exceeds
the deadline, rerun the reviewed Terraform plan/apply; the failed provisioner is
retried. `APPROVAL_TIMEOUT_SECONDS` (1–7200) and `APPROVAL_POLL_SECONDS` (>0–120)
may be set in the apply runner's environment.

Gateway authentication tokens expire in at most **30 days**. Plan controlled
rotation before expiry; do not print or paste the key into shell history, logs,
outputs, or source control.

Change the non-secret `gateway_token_rotation_id` in `terraform.tfvars` to a new
value and complete a reviewed plan/apply **at least every 29 days**. The marker
refreshes the issuance timestamp and token and updates the gateway revision.
This is operator-controlled rotation, not a background renewal service: leaving
Terraform idle does not renew the key. After applying the rotation, rerun the
smoke tests. The gateway remains configured for one replica, so do not assume
zero-downtime rotation.

For example, persist a new marker such as `rotation-2026-10-01` in
`terraform.tfvars`, then:

```bash
unset TF_LOG TF_LOG_PATH
terraform plan -var='gateway_token_rotation_id=rotation-2026-10-01' -out=rotation.tfplan
terraform apply rotation.tfplan
bash scripts/test-endpoints.sh
```

Choose your own new marker on every rotation; do not reuse the example value.
The issuance timestamp has a maximum 720-hour lifetime. A gateway environment
issuance marker rolls the revision because changing an ACA secret alone does
not restart running replicas. Do not replace only the token-generation action:
that would reuse the old issuance timestamp. Rotate through
`gateway_token_rotation_id` so both issuance and token are refreshed.

## Read-only smoke tests

```bash
# Read current outputs directly, without creating an output JSON file:
bash scripts/test-endpoints.sh

# Override bounded retry settings when needed:
SMOKE_MAX_ATTEMPTS=40 SMOKE_RETRY_DELAY=15 SMOKE_REQUEST_TIMEOUT=30 \
  bash scripts/test-endpoints.sh terraform-outputs.json

```

No `jq` prerequisite. Python parses the Terraform output JSON. Required URL
outputs are `managed_endpoint_url` and `self_hosted_endpoint_url`: distinct
HTTPS `*.azurefd.net` roots, including generated `*.z01.azurefd.net` names, without
credentials, ports, or path prefixes. Other
deployment outputs include `resource_group_name`, `apim_name`,
`apim_private_ip_addresses`, `aca_environment_name`, `mock_app_fqdn`, and
`gateway_app_fqdn`; no gateway key output is needed.

The runner performs all three checks:

1. Self-hosted `GET /get`: HTTP 200 and JSON containing
   `{"service":"mock-api","method":"GET","path":"/get"}`.
2. Self-hosted `POST /post`: HTTP 200, matching service/method/path, and exact
   echo in `json` of a payload with scalar, nested, array, boolean, and null values.
3. Managed `GET /get`: the same GET response contract.

It prints curl exit status, HTTP status and body, retries network failures,
unexpected status and malformed/wrong JSON, and exits nonzero if any check
exhausts its attempts. Defaults are 30 attempts, 20 seconds between attempts,
and a 30-second request timeout; the upper bound is roughly 25 minutes per check
(three checks run sequentially). Allowed ranges are 1–120 attempts, 0–300 seconds
delay and 1–120 seconds timeout. Redirects are not followed and TLS verification
is never disabled. Scratch files stay in a private directory under the current
working directory and are removed on exit. These scripts only read outputs and
send mock API test requests; they do not deploy or modify Azure configuration.

## Local validation without deploying

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform test
for script in scripts/*.sh; do bash -n "$script"; done
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
(cd mock-api && python3 -B -m unittest discover -s tests -p 'test_*.py' -v)
```

Every Terraform test run is explicitly **plan-only**, with all Azure providers
mocked. These checks exercise VNet/subnet derivation, topology, and network safety
guards without contacting Azure or running provisioners. Python
tests use fake Azure CLI/curl executables or the local WSGI application; they
cover build paths from unrelated working directories, delayed approval,
idempotency, failures, real Front Door hostname shapes, JSON echo validation,
chunked input and the mock's 1 MiB request limit. Plan assertions reject explicit
`AzurePlatformDNS` rules while preserving the required custom NSG rules.

## Safe teardown

The VNet and all four subnets are owned by this Terraform configuration, so a
reviewed normal destroy removes the complete lab without special state surgery:

```bash
terraform plan -destroy -out=cleanup.tfplan
terraform show cleanup.tfplan
terraform apply cleanup.tfplan
```

The state and saved plan contain the self-hosted gateway key. Keep both encrypted,
do not upload or log them, and verify the plan targets only this lab before applying.
Afterward, confirm that the workload resource group and its billable resources are
gone. Azure may take additional time to finish deleting managed resources.

## References

- [APIM private endpoints and limitations](https://learn.microsoft.com/azure/api-management/private-endpoint)
- [APIM internal VNet with Application Gateway](https://learn.microsoft.com/azure/api-management/api-management-howto-integrate-internal-vnet-appgateway)
- [Front Door Premium Private Link](https://learn.microsoft.com/azure/frontdoor/private-link)
- [Container Apps private endpoints](https://learn.microsoft.com/azure/container-apps/private-endpoints-with-dns)
- [Self-hosted gateway overview](https://learn.microsoft.com/azure/api-management/self-hosted-gateway-overview)
