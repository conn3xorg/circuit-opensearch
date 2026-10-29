output "config_file" {
  description = "Path of the file the circuit adds its settings to on each host."
  value       = local.config_file
}

output "url" {
  description = "URL the circuit checks OpenSearch's REST API on, from each host itself."
  value       = local.url
}
