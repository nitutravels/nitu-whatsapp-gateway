#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
export PUPPETEER_SKIP_DOWNLOAD=true

npm ci
npm run check
npm test
npm audit --omit=dev

if command -v php >/dev/null 2>&1; then
  php -l examples/php/send_message.php
  php -l examples/php/webhook.php
fi

cloud_init_bytes=$(wc -c < infra/terraform/cloud-init.yaml.tftpl)
if (( cloud_init_bytes > 24000 )); then
  echo "cloud-init template is too close to OCI's 32,000-byte combined metadata limit after base64 encoding: ${cloud_init_bytes} source bytes" >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  terraform -chdir=infra/terraform fmt -recursive
  terraform -chdir=infra/terraform init -backend=false
  terraform -chdir=infra/terraform validate
fi

if grep -RInE --exclude-dir=node_modules --exclude-dir=docs --exclude='package-lock.json' \
  '(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|ocid1\.(user|tenancy|compartment)\.[a-z0-9.-]+\.\.[a-z0-9]+)' .; then
  echo 'Potential live credential found in package.' >&2
  exit 1
fi

echo 'Package verification completed.'
