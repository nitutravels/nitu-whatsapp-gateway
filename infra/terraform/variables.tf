variable "tenancy_ocid" {
  description = "OCI tenancy OCID."
  type        = string
}
variable "compartment_ocid" {
  description = "OCI compartment OCID in which the gateway is created."
  type        = string
}
variable "region" {
  description = "OCI home region, for example ap-mumbai-1 or ap-hyderabad-1."
  type        = string
}
variable "availability_domain_index" {
  description = "Zero-based availability domain index."
  type        = number
  default     = 0
  validation {
    condition     = var.availability_domain_index >= 0
    error_message = "availability_domain_index must be zero or greater."
  }
}
variable "instance_shape" {
  description = "Oracle Always Free compute shape. E2.1.Micro is used as the reliable x86 fallback when Ampere A1 capacity is unavailable."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}
variable "instance_ocpus" {
  description = "OCPU count used only when the selected shape is flexible."
  type        = number
  default     = 1
  validation {
    condition     = var.instance_ocpus > 0 && var.instance_ocpus <= 2
    error_message = "Keep OCPUs at 2 or less for the current Always Free allowance."
  }
}
variable "instance_memory_gbs" {
  description = "Memory used only when the selected shape is flexible. Fixed micro shapes ignore this value."
  type        = number
  default     = 1
  validation {
    condition     = var.instance_memory_gbs >= 1 && var.instance_memory_gbs <= 12
    error_message = "Use between 1 and 12 GB and keep the total allocation within the Always Free allowance."
  }
}
variable "boot_volume_gbs" {
  type    = number
  default = 50
  validation {
    condition     = var.boot_volume_gbs >= 50 && var.boot_volume_gbs <= 200
    error_message = "OCI boot volume size must be between 50 and 200 GB."
  }
}
variable "gateway_image" {
  description = "Public GHCR image produced by this repository for the selected compute architecture."
  type        = string
}
variable "gateway_domain" {
  description = "Required DNS name such as wa.nitutravels.in. Caddy obtains and renews HTTPS automatically after DNS points to the reserved IP."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$", var.gateway_domain))
    error_message = "gateway_domain must be a valid fully-qualified domain name, for example wa.nitutravels.in."
  }
}
variable "gateway_api_key" {
  description = "API key accepted by the message API."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.gateway_api_key) >= 32
    error_message = "gateway_api_key must contain at least 32 characters."
  }
}
variable "gateway_admin_token" {
  description = "Bearer token for the web administration dashboard."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.gateway_admin_token) >= 32
    error_message = "gateway_admin_token must contain at least 32 characters."
  }
}
variable "gateway_webhook_secret" {
  description = "HMAC secret used to sign outbound webhook requests."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.gateway_webhook_secret) >= 32
    error_message = "gateway_webhook_secret must contain at least 32 characters."
  }
}
variable "webhook_url" {
  description = "Optional HTTPS endpoint receiving delivery and incoming-message events."
  type        = string
  default     = ""
}
variable "default_country_code" {
  type    = string
  default = "91"
}
variable "media_allowed_hosts" {
  description = "Comma-separated host allow-list for media downloads."
  type        = string
  default     = "nitutravels.in,www.nitutravels.in"
}
variable "send_interval_ms" {
  description = "Minimum global delay between outgoing messages."
  type        = number
  default     = 6000
  validation {
    condition     = var.send_interval_ms >= 5000
    error_message = "Do not set the sending interval below five seconds."
  }
}