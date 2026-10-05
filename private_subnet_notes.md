## Private subnet exercise

1. **What:** built a second subnet whose route table has only the automatic local VPC route — no route to an internet gateway — making it structurally private rather than privately-configured.
2. **Why it's stronger than a security group alone:** a security group can be misconfigured open; a subnet with no route to the internet and no public IP has no reachable address for inbound traffic and no path for outbound traffic, regardless of firewall rules.
3. **Verified independently:** confirmed via `describe-route-tables` (only the local route exists) and via `terraform state show` on a real launched instance (`public_ip: null`), not just by reading my own Terraform code.
