data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  site_address         = trimspace(var.gateway_domain) != "" ? trimspace(var.gateway_domain) : ":80"
  public_base_url      = trimspace(var.gateway_domain) != "" ? "https://${trimspace(var.gateway_domain)}" : ""
  env_file = join("\n", [
    "GATEWAY_IMAGE=${var.gateway_image}",
    "SITE_ADDRESS=${local.site_address}",
    "API_KEY=${jsonencode(var.gateway_api_key)}",
    "ADMIN_TOKEN=${jsonencode(var.gateway_admin_token)}",
    "WEBHOOK_URL=${jsonencode(var.webhook_url)}",
    "WEBHOOK_SECRET=${jsonencode(var.gateway_webhook_secret)}",
    "DEFAULT_COUNTRY_CODE=${jsonencode(var.default_country_code)}",
    "SEND_INTERVAL_MS=${var.send_interval_ms}",
    "MAX_ATTEMPTS=3",
    "MEDIA_ALLOWED_HOSTS=${jsonencode(var.media_allowed_hosts)}",
    "PUBLIC_BASE_URL=${jsonencode(local.public_base_url)}",
    "LOG_LEVEL=info",
    ""
  ])
}
