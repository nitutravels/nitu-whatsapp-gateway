# Troubleshooting

## Oracle: out of host capacity

Symptom:

```text
Out of host capacity
```

Actions:

1. Change `AVAILABILITY_DOMAIN_INDEX` from `0` to `1` or `2` when the home region has multiple availability domains.
2. Rerun the deployment workflow.
3. Try again later if all Always Free A1 capacity is temporarily exhausted.

Do not change the shape to a paid shape unless you deliberately accept billing.

## Terraform backend bucket error

Check:

- `OCI_NAMESPACE` is the Object Storage namespace, not the tenancy name.
- `OCI_TF_STATE_BUCKET` contains a valid bucket name.
- The deployment user can manage resources in `OCI_COMPARTMENT_OCID`.
- OCI region and API-key configuration belong to the same tenancy.

The workflow creates the bucket automatically before `terraform init`.

## OCI authentication failure

Check that `OCI_PRIVATE_KEY` includes all lines:

```text
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
```

Confirm that the fingerprint and user OCID correspond to the same uploaded public API key.

## Oracle VM exists but gateway is unavailable

First check the workflow summary's public IP. Then verify DNS resolves to that exact address.

Common causes:

- GHCR package is still private, so Docker cannot pull it.
- DNS points to an older IP.
- Certificate issuance is waiting for DNS propagation.
- Cloud-init is still installing Docker.
- Oracle reclaimed or stopped the Always Free instance.

The package intentionally has no public SSH port. Use Oracle Console diagnostics, serial console or an OCI Bastion session for advanced maintenance.

## HTTPS certificate not issued

Confirm:

- `GATEWAY_DOMAIN` is a real fully qualified domain name.
- Its `A` record points to the Terraform output IP.
- Ports 80 and 443 are reachable.
- No CDN proxy is interfering with the first ACME challenge.

Caddy retries certificate issuance automatically.

## Pairing code is not generated

1. Confirm the gateway dashboard is reachable over HTTPS.
2. Enter the number in international format without `+`.
3. Confirm the number is 8–15 digits.
4. Wait for the dashboard error message.
5. Retry once after refreshing the page.

The gateway deliberately rebuilds the browser client in phone-pairing mode, because pairing-code callbacks are established during client initialization.

## Pairing succeeds but status never becomes ready

- Open WhatsApp → Linked devices and confirm the new device appears.
- Remove stale linked devices if WhatsApp has reached its device limit.
- Keep the phone online during initial linking.
- Use the dashboard's unlink action and pair again.

## Messages remain queued

`/readyz` must return HTTP 200. Queued messages do not leave the server while the linked session is offline.

Also check:

- recipient contains country code
- test number can receive WhatsApp messages
- account has not been logged out or restricted
- scheduled timestamp is not in the future

## Media message rejected

The URL must:

- use HTTPS
- use a hostname listed in `MEDIA_ALLOWED_HOSTS`
- resolve to a public IP
- be directly downloadable without browser login

Add only trusted domains to the allow-list.

## GitHub secret or variable changes do not apply

Run the deployment workflow with infrastructure provisioning enabled; a code-only push does not update Terraform metadata. After a successful apply, the server normally synchronizes configuration within five minutes.

From Oracle Console diagnostics or serial console, inspect:

```text
systemctl status nitu-wa-config-sync.timer
journalctl -u nitu-wa-config-sync.service --no-pager -n 100
```

Do not expose the metadata endpoint to Docker containers. `nitu-wa-metadata-guard.service` and the periodic sync/update scripts maintain that firewall rule.

## GitHub push builds image but server does not update

The VM checks every ten minutes. Confirm:

- package remains public
- `latest` tag exists
- build job succeeded for both Arm64 and AMD64
- Oracle instance is running

A routine documentation-only commit does not trigger a build because `docs/**` and Markdown files are ignored.

## Destroy workflow fails

The destroy workflow retains the boot volume by design. It also leaves the manually bootstrapped Terraform state bucket. Remove those manually only after recovery is no longer needed.
