# Terraform + AWS Notes (VPC, EC2, VS Code SSH)

My reference notes from building a dev environment with Terraform: a VPC, an Ubuntu EC2 instance with Docker, and an auto-written SSH config for VS Code Remote-SSH.

**Region:** `us-west-2`  
**Provider:** `hashicorp/aws ~> 6.0`

---

## 1. What I Built

| File | Purpose |
|---|---|
| `provider.tf` | Pins the AWS provider, sets region, and uses the `terraform_demo` profile |
| `main.tf` | VPC, subnet, IGW, route table, route, association, security group, key pair, EC2 instance |
| `datasources.tf` | `aws_ami` lookup for the newest Ubuntu 24.04 image |
| `variables.tf` | `host_os` variable (default `linux`) |
| `terraform.tfvars` / `dev.tfvars` | Values for variables |
| `userdata.tpl` | Boot script that installs Docker |
| `linux-ssh-config.tpl` | Writes a Host entry into `~/.ssh/config` |

### Dependency Chain

Terraform works this out automatically from resource references:

```text
VPC
├── subnet
├── Internet Gateway
├── route table
└── security group

Internet Gateway + route table
└── default route (0.0.0.0/0)

subnet + route table
└── route table association

AMI data source + key pair + subnet + security group
└── EC2 instance
```

The network is a public subnet:

- VPC: `10.0.0.0/16`
- Subnet: `10.0.1.0/24`
- `map_public_ip_on_launch = true`

It is public because the route table sends:

```text
0.0.0.0/0 → Internet Gateway
```

---

## 2. Core Terraform Concepts

### Resource

A **resource** is something Terraform creates.

Example:

```hcl
resource "aws_vpc" "mtc_vpc" {
  # ...
}
```

Here:

- `aws_vpc` = resource type
- `mtc_vpc` = local name

Reference it as:

```hcl
aws_vpc.mtc_vpc.id
```

### Data Source

A **data source** is a read-only lookup of something that already exists.

Example:

```hcl
data.aws_ami.mtc_ami.id
```

### Variable

A **variable** is an input to Terraform.

It is:

1. Declared in `variables.tf`
2. Set in `.tfvars`
3. Used as `var.host_os`

Example:

```hcl
var.host_os
```

### Implicit Dependencies

Terraform automatically understands dependencies when one resource references another resource's attribute.

For example:

```hcl
aws_subnet.mtc_public_subnet.id
```

tells Terraform that the subnet must exist before the resource using it can be created.

### Provider

The provider is the plugin that communicates with the cloud API.

```hcl
hashicorp/aws ~> 6.0
```

`~> 6.0` means compatible 6.x versions are allowed.

### Terraform Workflow

```text
terraform init
      ↓
download providers
      ↓
terraform plan
      ↓
preview changes
      ↓
terraform apply
      ↓
create/update resources
      ↓
terraform destroy
      ↓
remove resources
```

### Plan Symbols

| Symbol | Meaning |
|---|---|
| `+` | Create |
| `~` | Change in place |
| `-` | Destroy |
| `-/+` | Replace |

---

## 3. State

Terraform state is stored in:

```text
terraform.tfstate
```

State maps Terraform configuration to real resources using their IDs.

Without state, Terraform cannot reliably determine whether a resource should be created or updated.

### Useful State Commands

Show all tracked resources:

```bash
terraform state list
```

Show one resource:

```bash
terraform state show <address>
```

Import an existing resource:

```bash
terraform import <address> <id>
```

Stop tracking a resource without deleting it:

```bash
terraform state rm <address>
```

### Renaming Resources

If I rename a resource in the Terraform code, Terraform may interpret it as:

```text
destroy old resource
+
create new resource
```

To avoid this, I can use:

```bash
terraform state mv
```

or a Terraform `moved` block.

### State Security

Terraform state can contain:

- Real resource IDs
- Configuration details
- Secrets in plain text

**Never commit `terraform.tfstate` to Git.**

Do not paste raw Terraform state into chats or public repositories.

### Remote State

For teams, remote state such as:

```text
S3 + encryption + locking
```

is normally used.

Local state is fine for learning.

### Important Lesson From This Project

If:

```bash
terraform apply
```

fails halfway, Terraform state, the AWS console, and Terraform's plan may temporarily disagree.

Check all three:

```text
Terraform state
Terraform plan
AWS console
```

Then either:

1. Delete the orphaned resource, or
2. Import it into Terraform state.

---

## 4. Key Pieces Explained

### AMI Lookup

AMI IDs differ between AWS regions, so I search instead of hardcoding them.

Example:

```hcl
owners = ["099720109477"]
```

`099720109477` is Canonical.

Using:

```hcl
most_recent = true
```

with a name filter selects the newest matching Ubuntu 24.04 image.

Inside a data source, `name` is a computed attribute.

Therefore, only the `filter` block's `name` should be used for searching.

---

### Key Pair

`aws_key_pair` uploads my public key:

```text
~/.ssh/mtckey.pub
```

using:

```hcl
file(pathexpand(...))
```

The private key stays on my local machine.

---

### user_data

`user_data` uses:

```hcl
templatefile("userdata.tpl", {})
```

The script runs during the EC2 instance's first boot as `root`.

It:

1. Installs Docker from Docker's apt repository.
2. Adds the `ubuntu` user to the `docker` group.

Important:

`user_data` normally runs only during the initial instance boot.

Changing `userdata.tpl` later does not automatically rerun it on an existing instance.

---

### local-exec Provisioner

After the instance is created, `local-exec` renders:

```text
linux-ssh-config.tpl
```

using the instance's public IP and appends a Host block to:

```text
~/.ssh/config
```

This allows VS Code Remote-SSH to connect to the EC2 instance.

Important details:

- It runs only on creation.
- It does not automatically run on every `terraform apply`.
- Every new instance can add another Host entry.
- Old entries can pile up.
- `interpreter` switches between Bash and PowerShell using `var.host_os`.
- `StrictHostKeyChecking no` disables SSH host-key verification.
- `UserKnownHostsFile /dev/null` prevents storing the host key.

These last two settings are convenient for a lab but unsafe elsewhere.

**Provisioners are generally considered a last resort in real Terraform projects.**

---

## 5. Problems I Hit and What Fixed Them

| Symptom | Cause | Fix |
|---|---|---|
| `failed to get shared config profile` | `shared_credentials_files` pointed at the downloaded keys CSV, which is not the INI credentials format | Remove that line; use `aws configure --profile terraform_demo` so the profile lives in `~/.aws/credentials` |
| `aws: command not found` | AWS CLI was not installed | Install `awscli2` |
| `UnauthorizedOperation ... explicit deny in a service control policy` | An organization SCP denied `ec2:CreateVpc` outside allowed regions | Activate advanced features to own/manage the organization, then edit the region policy (`RegionFloor` statement) to allow the required regions |
| Console showed nothing after apply | Wrong account or wrong region selected in the console | Check the account ID and region selector |
| `Unsupported block type: tag` | Route table uses `tags = { }`, a map, not a `tag { }` block | Use `tags = { Name = "..." }` |
| Subnet `InvalidParameterValue ... availabilityZone` | Region changed but `availability_zone` still pointed to `eu-north-1a` | Keep the AZ in the same region as the provider |
| `Can't configure a value for "name"` | `name` was incorrectly set at the top level of an AMI data source | Delete it; keep `name` only inside `filter` |
| Security group `UnknownError` on create | Transient failure; group existed in AWS but not in state | Delete the orphan or import it, then apply again |

### Useful Debugging Commands

Decode an AWS authorization message:

```bash
aws sts decode-authorization-message \
  --encoded-message '<blob>' \
  --profile terraform_demo
```

Check the current AWS identity:

```bash
aws sts get-caller-identity \
  --profile terraform_demo
```

Test VPC creation permissions:

```bash
aws ec2 create-vpc \
  --cidr-block 10.99.0.0/16 \
  --dry-run \
  --region <r> \
  --profile terraform_demo
```

Disable the AWS CLI pager:

```bash
export AWS_PAGER=""
```

Enable Terraform debug logging:

```bash
TF_LOG=DEBUG terraform apply
```

> **Warning:** `TF_LOG=DEBUG` may contain account details or other sensitive information. Do not share raw debug logs publicly.

---

## 6. AWS Concepts I Learned

### IAM User vs Root vs Organization

An IAM user with `AdministratorAccess` can still be blocked by an AWS Organizations SCP.

The important rule is:

> **Explicit deny wins.**

If an SCP denies an action, IAM permissions cannot override that deny.

---

### SCPs

Service Control Policies (SCPs) define the maximum permissions available to accounts within an AWS Organization.

SCPs are managed from the organization's management account.

Workloads should generally run in member accounts rather than directly in the management account.

---

### Regions and Availability Zones

AWS resources are created within a specific region.

Availability Zones belong to a specific region.

For example:

```text
us-west-2a
```

belongs to:

```text
us-west-2
```

Always make sure the following are consistent:

```text
Terraform provider region
        ↓
Availability Zone
        ↓
AWS console region
```

---

### Public Subnet

A subnet is considered public when its route table provides a route to an Internet Gateway.

Example:

```text
0.0.0.0/0
    ↓
Internet Gateway
```

---

### Security Group

A security group is a **stateful firewall** attached to resources such as EC2 instances.

---

### NACL

A Network ACL is a **stateless**, subnet-level network filtering layer.

---

### Free vs Paid AWS Resources

The following generally do not themselves incur charges:

- VPCs
- Subnets
- Security groups

However, resources such as the following can incur charges:

- EC2 instances
- Public IPv4 addresses
- NAT Gateways

---

## 7. Things to Fix / Do Next

### 1. Narrow the Security Group

Currently it allows all ports and protocols from:

```text
0.0.0.0/0
```

while the EC2 instance has a public IP.

This is unnecessarily exposed.

Restrict ingress to SSH:

```text
22/tcp
```

from my own public IP:

```text
x.x.x.x/32
```

---

### 2. Set an AWS Budget

Add an AWS Budget with email alerts for unexpected spending.

The spending limit was removed when advanced AWS Organizations features were activated, so a budget is important.

---

### 3. Add a `.gitignore`

Before committing anything, add:

```gitignore
.terraform/
*.tfstate*
*.tfvars
```

---

### 4. Delete the Access-Key CSV

Delete the AWS access-key CSV from:

```text
~/Downloads
```

Consider rotating the access key as well.

---

### 5. Destroy Resources After Learning Sessions

Run:

```bash
terraform destroy
```

at the end of each learning session.

Also check other AWS regions to make sure nothing was accidentally left running.

---

### 6. Replace the `local-exec` SSH Config Hack

Once comfortable with Terraform, replace the `local-exec` SSH configuration approach with a cleaner solution.

---

### 7. Learn Next

Next Terraform topics to learn:

- Outputs
- Locals
- Modules
- `for_each`
- `count`
- Remote state
- IAM roles
- Short-lived credentials instead of long-lived access keys

---

## 8. Quick Command Cheat Sheet

```bash
# Initialize Terraform
terraform init

# Format Terraform files
terraform fmt

# Validate Terraform configuration
terraform validate

# Preview changes
terraform plan

# Create/update infrastructure
terraform apply

# Apply using a specific variable file
terraform apply -var-file=dev.tfvars

# Destroy infrastructure
terraform destroy

# List resources in Terraform state
terraform state list

# Show Terraform outputs
terraform output
```
