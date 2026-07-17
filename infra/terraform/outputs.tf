output "public_ip" {
  description = "Reserved public IP. Create an A record for the gateway domain pointing here."
  value       = oci_core_public_ip.gateway.ip_address
}

output "dashboard_url" {
  description = "Gateway administration URL. HTTPS becomes active after DNS resolves."
  value       = trimspace(var.gateway_domain) != "" ? "https://${trimspace(var.gateway_domain)}/admin" : "http://${oci_core_public_ip.gateway.ip_address}/admin"
}

output "health_url" {
  value = trimspace(var.gateway_domain) != "" ? "https://${trimspace(var.gateway_domain)}/healthz" : "http://${oci_core_public_ip.gateway.ip_address}/healthz"
}

output "instance_id" {
  value = oci_core_instance.gateway.id
}
