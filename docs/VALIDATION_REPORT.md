# Validation report

Package version: `1.0.0`  
Review date: 17 July 2026

## Completed before packaging

- JavaScript syntax checks for gateway and dashboard files
- Node test suite: 4 tests passed
- Offline production dependency audit: 0 known vulnerabilities reported from the lockfile/cache
- PHP syntax checks for both integration examples
- YAML parsing for GitHub Actions, Dependabot, Docker Compose and the rendered cloud-init template
- HCL parsing for every Terraform file
- Credential-pattern scan excluding documentation examples
- Cloud-init template size check: comfortably below OCI's 32,000-byte combined metadata limit after base64 encoding
- ZIP integrity and SHA-256 checksum verification

## Performed automatically during deployment

The GitHub workflow uses the July 2026 supported action lines and downloads Terraform `1.15.8` plus OCI provider `8.23.0`, formats the Terraform configuration, runs `terraform validate`, creates a plan and applies only that saved plan. The workflow stops before provisioning if any of those steps fail.

The container workflow performs a clean multi-platform Docker build for `linux/arm64` and `linux/amd64`. This is the authoritative native-module build check for the Oracle A1 target.

## Not claimed

- No OCI resources were created during package generation because no user credentials were supplied.
- No real WhatsApp account was linked or messaged during package generation.
- Unofficial linked-device compatibility cannot be guaranteed after future WhatsApp Web changes.
