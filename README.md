# Terraform + AWS: From Zero to a Secured Lab (Notes and Interview Prep)

These are my learning notes from building a small AWS environment with Terraform, then securing, scanning, attacking (safely) and monitoring it. They are written so that someone who has **never used Terraform or AWS** can follow them, and so that I can use them to **prepare for interviews**.

Every code block in here is code I actually wrote and ran. Where I hit an error, the error and the fix are included, because the mistakes taught me the most.

> **Safety note.** Account IDs, IP addresses and keys in this document are replaced with placeholders such as `<ACCOUNT_ID>` and `<MY_IP>`. Never commit real keys, `terraform.tfstate`, or `terraform.tfvars` to git.

---

## Table of contents

1. [The big picture](#1-the-big-picture)
2. [Setting up access to AWS](#2-setting-up-access-to-aws)
3. [Terraform basics](#3-terraform-basics)
4. [Building the network](#4-building-the-network)
5. [Firewall rules: the security group](#5-firewall-rules-the-security-group)
6. [Building the server](#6-building-the-server)
7. [Terraform state](#7-terraform-state)
8. [Organizations and the policy that blocked me](#8-organizations-and-the-policy-that-blocked-me)
9. [Scanning my own code with checkov](#9-scanning-my-own-code-with-checkov)
10. [IAM: roles, trust, and temporary credentials](#10-iam-roles-trust-and-temporary-credentials)
11. [Instance profiles, IMDSv2 and the 401 test](#11-instance-profiles-imdsv2-and-the-401-test)
12. [S3: buckets and the public-bucket experiment](#12-s3-buckets-and-the-public-bucket-experiment)
13. [Detection: finding my own activity in CloudTrail](#13-detection-finding-my-own-activity-in-cloudtrail)
14. [Secrets hygiene, cost safety and cleanup](#14-secrets-hygiene-cost-safety-and-cleanup)
15. [Error log: what broke and how I fixed it](#15-error-log-what-broke-and-how-i-fixed-it)
16. [Command cheat sheet](#16-command-cheat-sheet)
17. [Interview questions and answers](#17-interview-questions-and-answers)
18. [What I have not covered yet](#18-what-i-have-not-covered-yet)

---

## 1. The big picture

### What is the cloud?

Instead of buying a physical server, I rent one from Amazon Web Services (AWS) and pay for the time it runs. AWS offers hundreds of building blocks: servers (EC2), private networks (VPC), file storage (S3), identities and permissions (IAM), and more.

### What is Infrastructure as Code (IaC)?

I could create all of this by clicking in the AWS web console. That works once, but it is slow, hard to repeat, and impossible to review. **Infrastructure as Code** means I describe what I want in text files, and a tool builds it for me.

Benefits:

- **Repeatable.** Destroy everything and rebuild it in about a minute.
- **Reviewable.** The files go in git, so changes can be reviewed like any other code.
- **Scannable.** Security tools can read the files and warn me before anything is built.

### What is Terraform?

Terraform is the IaC tool I used. I write files in a language called **HCL**, describing the desired result ("a network, a firewall, a server"). Terraform compares that with what exists in AWS and works out what to create, change or delete.

An analogy: I give an architect a blueprint, and the architect builds it. If I change the blueprint, the architect works out the difference and only builds that.

### What I built

```
Internet
   |
Internet Gateway (the door to the internet)
   |
Route table (road signs: "everything for the internet goes through the door")
   |
Public subnet 10.0.1.0/24  (inside the VPC 10.0.0.0/16)
   |
EC2 server (Ubuntu + Docker)  <- firewall (security group) allows only SSH from my IP
   |
IAM role (temporary identity, one small permission)
   |
S3 bucket (private storage the role may read)
```

Later sections add the security layers: scanning, least privilege, metadata protection, logging.

### Files in the project

| File | What it does |
|---|---|
| `provider.tf` | Says which cloud, which version, which region and which login profile |
| `main.tf` | The network, firewall, key pair and server |
| `datasources.tf` | Looks up the newest Ubuntu image |
| `variables.tf` | Inputs I can change without editing resources |
| `terraform.tfvars` | The values for those inputs (**git-ignored**) |
| `userdata.tpl` | A script the server runs on first boot (installs Docker) |
| `linux-ssh-config.tpl` | A template that writes an SSH shortcut for VS Code |
| `iam.tf` | Roles and permissions |
| `s3.tf` | The private storage bucket |
| `.gitignore` | Keeps secrets and state out of git |

---

## 2. Setting up access to AWS

Terraform needs permission to act in my AWS account. The safe way:

1. Create an **IAM user** for Terraform (I named it `terraform-demo`). An IAM user is a login identity for programs or people.
2. Give that user an **access key**. A key has two parts: an *access key ID* (like a username) and a *secret access key* (like a password).
3. Store the key in a **profile** on my laptop, using the AWS CLI:

```bash
aws configure --profile terraform_demo
```

That writes `~/.aws/credentials` in this format:

```ini
[terraform_demo]
aws_access_key_id     = AKIA................
aws_secret_access_key = ****************************************
```

4. Tell Terraform which profile to use in `provider.tf`:

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "terraform_demo"
}
```

### Line by line

- `required_providers` says Terraform needs the **AWS provider**, a plugin that knows how to talk to the AWS API. `source` is where it comes from.
- `version = "~> 6.0"` means "any 6.x version". It stops a surprise major upgrade from breaking my code.
- `region` is where resources are created. Resources live in one region, and the console only shows one region at a time.
- `profile` picks which stored key to use.

### My first mistake

I originally wrote this in `provider.tf`:

```hcl
shared_credentials_files = ["/home/<user>/Downloads/terraform-demo_accessKeys.csv"]
```

That points Terraform at the **CSV file AWS lets you download**. The CSV is not in the credentials format, so Terraform could not find the profile and failed with `failed to get shared config profile`. The fix was to remove that line and use `aws configure`, which writes the proper file.

### Verify who you are

Before running Terraform, always check which identity you are using:

```bash
aws sts get-caller-identity --profile terraform_demo
```

It returns the account ID and the ARN of the user. I used this command constantly.

### Rotating the key

The original key sat in a CSV in `~/Downloads`, so I replaced it. Safe rotation order, so I could never lock myself out:

```bash
# 1. list keys (a user can have at most two)
aws iam list-access-keys --user-name terraform-demo --profile terraform_demo

# 2. create a second key in the console (do not download the CSV), then:
aws configure --profile terraform_demo        # paste the new key

# 3. prove the new key works
aws sts get-caller-identity --profile terraform_demo
terraform plan

# 4. deactivate the old key (reversible), re-test, and only then delete it
aws iam update-access-key --user-name terraform-demo --access-key-id <OLD_KEY_ID> --status Inactive --profile terraform_demo
aws iam delete-access-key --user-name terraform-demo --access-key-id <OLD_KEY_ID> --profile terraform_demo

# 5. securely delete the downloaded CSV
shred -u ~/Downloads/terraform-demo_accessKeys.csv
```

---

## 3. Terraform basics

### The workflow

| Command | What it does |
|---|---|
| `terraform init` | Downloads the provider plugins. Run once per project, and again after adding a provider |
| `terraform fmt` | Tidies formatting |
| `terraform validate` | Checks syntax and references (does **not** check variable values) |
| `terraform plan` | Shows what would change, without changing anything |
| `terraform apply` | Does it (asks for `yes`) |
| `terraform destroy` | Deletes everything Terraform created |

Habit: **read every plan before applying**, and look for the words `destroy` and `replace` first.

Symbols in a plan:

| Symbol | Meaning |
|---|---|
| `+` | create |
| `~` | change in place |
| `-` | destroy |
| `-/+` | destroy and recreate (replace) |

### The building blocks of HCL

**Resource**: something Terraform creates.

```hcl
resource "aws_vpc" "mtc_vpc" {
  cidr_block = "10.0.0.0/16"
}
```

- `aws_vpc` is the **type** (provided by the AWS plugin).
- `mtc_vpc` is the **local name**, a label only Terraform sees. I use it to refer to this resource.
- Together, `aws_vpc.mtc_vpc` is the resource's address.

**References and dependencies**: one resource uses another's attribute.

```hcl
resource "aws_subnet" "mtc_subnet" {
  vpc_id = aws_vpc.mtc_vpc.id
}
```

Because the subnet refers to `aws_vpc.mtc_vpc.id`, Terraform knows the VPC must exist first. I never wrote an order. Terraform builds a **dependency graph** from references and runs independent pieces in parallel.

**Data source**: a read-only lookup of something that already exists.

```hcl
data "aws_caller_identity" "current" {}
```

It asks AWS "who am I?" and gives me the account ID as `data.aws_caller_identity.current.account_id`. It creates nothing.

**Variable**: an input.

```hcl
variable "host_os" {
  type    = string
  default = "linux"
}
```

Used as `var.host_os`. Values come from defaults, `terraform.tfvars`, `-var-file`, or `-var` on the command line, with later ones winning.

**Output**: a value printed after apply and available through `terraform output`.

**Provisioner**: a script that runs on my laptop or the server after a resource is created (a last resort in real projects).

**Template**: a text file with placeholders, filled in by `templatefile()`.

### Variables with a safety check

Variables can have a `validation` block. This one protects the firewall rule I use later:

```hcl
variable "my_ip" {
  type        = string
  description = "My public IP in CIDR form, e.g. 203.0.113.5/32"

  validation {
    condition     = can(cidrhost(var.my_ip, 0)) && endswith(var.my_ip, "/32")
    error_message = "my_ip must be a single IP in CIDR form ending in /32."
  }
}
```

How the condition works:

- `cidrhost(var.my_ip, 0)` only works on a well-formed CIDR such as `203.0.113.5/32`.
- `can(...)` turns a failure into `false` instead of crashing.
- `endswith(var.my_ip, "/32")` rejects broad ranges, so `0.0.0.0/0` (the whole internet) is refused.

I tested it by setting `my_ip = "0.0.0.0/0"` on purpose. `terraform plan` stopped with my error message. Two lessons:

1. `terraform validate` still passed. It only checks code, not values. The validation rule runs on `plan` and `apply`.
2. The rule checks **format**, not ownership. A typo like `.9/32` instead of `.93/32` is still a valid single IP, so I must compare my IP with `curl -s https://checkip.amazonaws.com` myself.

The actual value lives in `terraform.tfvars`, which is git-ignored:

```hcl
host_os = "linux"
my_ip   = "<MY_IP>/32"
```

A committed template, `terraform.tfvars.example`, documents the setting without my real IP.

---

## 4. Building the network

### CIDR notation in plain words

`10.0.0.0/16` is a range of IP addresses. The number after the slash says how many leading bits are fixed:

| CIDR | Addresses | Meaning |
|---|---|---|
| `/32` | 1 | exactly one machine |
| `/24` | 256 | a small subnet |
| `/16` | 65,536 | a whole VPC |
| `0.0.0.0/0` | all | everyone / the whole internet |

### The VPC

A **VPC** (Virtual Private Cloud) is my own private network inside AWS.

```hcl
resource "aws_vpc" "mtc_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "dev"
  }
}
```

- `cidr_block` is the address range of the whole network.
- The two DNS settings let machines inside resolve names.
- `tags` are labels. `Name` is what the console displays.

### The subnet

A **subnet** is a slice of the VPC placed in one availability zone (a physical data centre group).

```hcl
resource "aws_subnet" "mtc_subnet" {
  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-west-2a"

  tags = {
    Name = "dev-subnet"
  }
}
```

- `map_public_ip_on_launch = true` gives servers here a public IP so I can SSH in.
- `availability_zone` **must belong to the provider's region**. When I changed the region to `us-west-2` but left `eu-north-1a`, the subnet failed with `InvalidParameterValue ... availabilityZone`.

### The internet gateway

```hcl
resource "aws_internet_gateway" "mtc_internet_gateway" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-igw"
  }
}
```

The door between the VPC and the internet. A gateway alone does nothing until a route points to it.

### The route table, the route and the association

```hcl
resource "aws_route_table" "mtc_route_table" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-route-table"
  }
}

resource "aws_route" "mtc_default_route" {
  route_table_id         = aws_route_table.mtc_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.mtc_internet_gateway.id
}

resource "aws_route_table_association" "mtc_route_table_association" {
  subnet_id      = aws_subnet.mtc_subnet.id
  route_table_id = aws_route_table.mtc_route_table.id
}
```

- The **route table** is a set of road signs.
- The **route** says "anything not inside the VPC (`0.0.0.0/0`) goes through the internet gateway".
- The **association** attaches the road signs to the subnet.

A subnet is **public** because its route table has a route to an internet gateway. Remove that route and the subnet becomes private.

### A mistake I made with the route table

I wrote `tag { ... }` (a block) instead of `tags = { ... }` (a map) and got `Unsupported block type: tag`. Tags on these resources are always a map.

---

## 5. Firewall rules: the security group

A **security group** is a firewall attached to a server's network interface. Key facts:

- It is **stateful**: if an inbound connection is allowed, the reply is allowed automatically.
- Everything inbound is **denied by default**, and rules only **allow**. You cannot write a deny rule (NACLs, the subnet-level firewall, can).

### Version 1: what I wrote first (insecure)

```hcl
resource "aws_security_group" "mtc_security_group" {
  name        = "dev-sg"
  description = "dev security group"
  vpc_id      = aws_vpc.mtc_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

`protocol = "-1"` means all protocols, ports 0 to 0 means all ports, and `0.0.0.0/0` means the whole internet. Combined with a public IP, this exposes everything on the server to the world. Bots scan for open ports within minutes of a server appearing.

### Version 2: locked to one IP and one port

```hcl
resource "aws_security_group" "mtc_security_group" {
  name        = "dev-sg"
  description = "dev security group"
  vpc_id      = aws_vpc.mtc_vpc.id

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    description = "Allow all outbound (apt and Docker downloads)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

The rule now answers three questions:

| Question | Answer in code |
|---|---|
| Who may connect? | `cidr_blocks = [var.my_ip]` (one IP, `/32`) |
| Which door? | port 22, the SSH port |
| Which language? | `protocol = "tcp"` |

`egress` stays open so the server can download packages during setup.

### When my IP changes, SSH stops working

That is the lock working. Home, college and hotspot networks all give different public IPs. The fix is to tell Terraform the new IP, which is an in-place update of one rule:

```bash
terraform apply -var="my_ip=$(curl -s https://checkip.amazonaws.com)/32"
```

- Use `-var`, not an environment variable. A value in `terraform.tfvars` beats `TF_VAR_my_ip`, so the environment variable would silently lose.
- The `-var` value only applies to that run. Update `terraform.tfvars` too, or the next plain apply reverts the rule.
- Never "fix" it by opening `0.0.0.0/0`, and never edit the rule by hand in the console (Terraform would revert it on the next apply, which is called **drift**).

---

## 6. Building the server

### The key pair (how I log in)

```hcl
resource "aws_key_pair" "mtc_auth" {
  key_name   = "mtc_auth"
  public_key = file(pathexpand("~/.ssh/mtckey.pub"))
}
```

- `file()` reads a local file. `pathexpand()` turns `~` into my home directory.
- I upload only the **public** key. The private key (`~/.ssh/mtckey`) never leaves my laptop.

### Finding the operating system image (AMI)

```hcl
data "aws_ami" "mtc_ami" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}
```

- An **AMI** is the template a server boots from. AMI IDs differ per region, so I search instead of hardcoding one.
- `099720109477` is Canonical, the company behind Ubuntu. Filtering by owner stops a malicious look-alike image from being picked.
- `most_recent = true` takes the newest match.
- My mistake: I wrote `name = "name"` at the top level. Inside a data source `name` is a computed value that Terraform fills in, so I got `Can't configure a value for "name"`. The only `name` I set belongs inside `filter`.

### The EC2 instance (final version, with the security fixes)

```hcl
resource "aws_instance" "mtc_instance" {
  ami                    = data.aws_ami.mtc_ami.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.mtc_subnet.id
  vpc_security_group_ids = [aws_security_group.mtc_security_group.id]
  key_name               = aws_key_pair.mtc_auth.key_name
  iam_instance_profile   = aws_iam_instance_profile.mtc_ec2_profile.name
  user_data              = templatefile("${path.module}/userdata.tpl", {})

  tags = {
    Name = "dev-instance"
  }

  root_block_device {
    volume_size = 10
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  provisioner "local-exec" {
    command = templatefile("${path.module}/linux-ssh-config.tpl", {
      hostname     = self.public_ip
      user         = "ubuntu"
      identityfile = pathexpand("~/.ssh/mtckey")
    })
    interpreter = var.host_os == "windows" ? ["PowerShell", "-Command"] : ["/bin/bash", "-c"]
  }
}
```

What each part does:

- `ami` comes from the data source above, so the server always boots the newest Ubuntu 24.04.
- `instance_type = "t2.micro"` is a small, cheap size.
- `subnet_id` and `vpc_security_group_ids` place the server in my subnet behind my firewall, using references.
- `iam_instance_profile` gives the server an identity (section 11).
- `metadata_options` forces IMDSv2 (section 11).
- `root_block_device` sets a 10 GB disk.
- `${path.module}` means "the folder this file is in".

### user_data: a script that runs at first boot

`userdata.tpl` installs Docker from Docker's official apt repository:

```bash
#!/bin/bash
set -euxo pipefail

apt-get update -y
apt-get install -y ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

arch="$(dpkg --print-architecture)"
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu
```

- `set -euxo pipefail` makes the script stop on the first error and print each command, which helps debugging.
- `usermod -aG docker ubuntu` lets the `ubuntu` user run Docker without `sudo` (after logging in again).
- `user_data` runs **once**, at first boot, as root. Changing it later does not re-run it on an existing server. Terraform finishes before the script does, so Docker may still be installing for a few minutes. `cloud-init status --wait` on the server shows when it is done.

### The SSH config provisioner (for VS Code Remote-SSH)

`linux-ssh-config.tpl`:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh

cat << EOF >> ~/.ssh/config

Host ${hostname}
  HostName ${hostname}
  User ${user}
  IdentityFile ${identityfile}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF

chmod 600 ~/.ssh/config
```

After the server is created, Terraform fills in the placeholders (`${hostname}` becomes the server's public IP), runs the script on my laptop, and appends a `Host` entry to `~/.ssh/config`. VS Code Remote-SSH reads that file, so I can connect by IP.

Things to remember:

- It runs **only on creation**, not on every apply.
- Each rebuild adds another `Host` block for a new IP, so old ones pile up and need pruning.
- `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` skip host-key checks. That is convenient for a throwaway lab and **unsafe for real servers**.
- `interpreter` picks bash or PowerShell from `var.host_os` using a conditional (`condition ? a : b`).

### Connecting

```bash
ssh ubuntu@<public-ip>
```

Terraform prints nothing about the IP by default. Find it with `terraform state show aws_instance.mtc_instance | grep public_ip`. Replace `<public-ip>` with the real address, with no angle brackets (bash treats `<` as a redirect).

---

## 7. Terraform state

### What it is

Terraform keeps a file, `terraform.tfstate`, that records **which real AWS resources correspond to which blocks in my code**. My code says "a VPC called `mtc_vpc`", but AWS only knows IDs like `vpc-0abc...`. State is the link between the two.

On every `plan`, Terraform:

1. reads my `.tf` files (what I want),
2. reads state (what it believes exists),
3. refreshes against AWS (what actually exists),
4. shows the difference.

Without state, Terraform could not tell "create" from "update" and would try to build duplicates.

### Useful commands

```bash
terraform state list                  # everything Terraform tracks
terraform state show aws_vpc.mtc_vpc  # details of one resource
terraform state rm <address>          # stop tracking (does NOT delete in AWS)
terraform state mv <old> <new>        # rename without destroy/recreate
terraform import <address> <id>       # adopt an existing resource into state
```

### Rules for state

- **It can contain secrets in plain text.** Never commit `*.tfstate` or `*.tfstate.backup`. They are in my `.gitignore`.
- **Never edit it by hand.** Use the `state` commands.
- **Losing it is painful.** Resources keep running (and costing money) but Terraform forgets them.
- **Local state does not suit teams.** Two people with separate files collide. The standard fix is remote state in S3 with locking (not built yet, see section 18).
- **Renaming a resource in code means destroy and recreate** unless I use `terraform state mv` or a `moved` block.

### A real problem I hit: the orphaned security group

An apply created the security group, but the follow-up check call failed with `UnknownError`. AWS had the group, while Terraform's state did not. The next `plan` wanted to **create** it again, which would fail with a duplicate-name error.

Two ways to fix it:

```bash
# Option A: delete the orphan in AWS, then apply again
aws ec2 delete-security-group --group-id <sg-id> --region <region> --profile terraform_demo
terraform apply

# Option B: adopt the existing group into state
terraform import aws_security_group.mtc_security_group <sg-id>
```

Lesson: when `state list`, `plan` and AWS disagree, check all three before applying.

### Project hygiene I learned

Check the folder for leftover lab files before every apply. I once had an experiment file with a typo in its name (`s3_puplic_test.tf`), so my `rm s3_public_test.tf` never matched it. It would have rebuilt a public bucket on the next apply.

---

## 8. Organizations and the policy that blocked me

### The symptom

Creating a VPC failed with `403 UnauthorizedOperation`:

```
... is not authorized to perform: ec2:CreateVpc ... with an explicit deny in a service control policy ...
```

I had already given my user `AdministratorAccess`, and it made no difference.

### What a service control policy (SCP) is

An **SCP** is a guardrail set at the **AWS Organizations** level. It sets the **maximum** permissions for every account inside the organization. An SCP sits above IAM, so:

- An IAM allow can never override an SCP deny.
- Admin rights inside an account do not bypass an SCP.
- Only the **management account** of the organization can change SCPs.

How AWS decides a request (simplified): an **explicit deny anywhere always wins**. Otherwise the request needs an allow in the SCP **and** an allow in IAM.

### Reading the error

AWS offers a decoder for the long "Encoded authorization failure message":

```bash
aws sts decode-authorization-message \
  --encoded-message '<the encoded string, pasted in full>' \
  --profile terraform_demo --query DecodedMessage --output text
```

The decoded JSON showed `"explicitDeny": true`, the matching statement ID (`RegionFloor`, a deny based on `aws:RequestedRegion`), and the action and resource. That identified exactly which rule blocked me and why: only certain regions were allowed.

### Two kinds of deny, and how to tell them apart

| Message says | Meaning | Where to fix |
|---|---|---|
| `because no identity-based policy allows ...` | **Implicit** deny: nothing granted it | Add an allow to the user or role |
| `with an explicit deny in a service control policy` | **Explicit** deny from the organization | Change the SCP in the management account |

### How I resolved it

My account sat inside an organization whose guardrails AWS managed for me. By activating advanced features in AWS Settings I took control of the organization, and from the **management account** I could edit the region guardrail so my chosen regions were allowed. (Activation cannot be reversed, and it removes the spend limit, so I immediately set a budget alert.)

### Management account vs member account

| | Management account | Member account |
|---|---|---|
| Purpose | Administers the organization, billing, SCPs, budgets | Runs the workloads |
| I used it for | Editing guardrails, budgets | Terraform, EC2, S3, IAM |

Keep workloads **out** of the management account. Always check which account and region the console banner shows. Several times I thought resources were missing when I was simply looking at the wrong account or region.

---

## 9. Scanning my own code with checkov

**checkov** is a static scanner for infrastructure code. It reads my `.tf` files and flags insecure settings **before anything is built**.

```bash
pipx install checkov     # pipx keeps tool dependencies isolated from other Python tools
checkov -d . --quiet
```

My first scan: `Passed checks: 13, Failed checks: 9`.

### Triage: fix, accept, or defer

The skill is deciding what to fix and writing down why. Not every finding is worth fixing in a lab.

| Finding | What it means | Decision |
|---|---|---|
| **CKV_AWS_79** IMDSv1 enabled | Credentials can be stolen with a simple request (SSRF) | **Fixed** with `http_tokens = "required"` |
| **CKV_AWS_23** missing description | The egress rule had no description | **Fixed** (one line) |
| CKV_AWS_130 public IP by default | The subnet hands out public IPs | Accepted: SSH needs it in a public lab subnet |
| CKV_AWS_382 egress to `0.0.0.0/0` | The server can reach anywhere | Accepted for now: `apt` and Docker need outbound access |
| CKV_AWS_126 detailed monitoring | One-minute metrics cost extra | Accepted: costs money, no lab value |
| CKV_AWS_135 EBS optimized | `t2.micro` does not support it | Accepted: cannot be fixed on this type |
| CKV2_AWS_11 VPC flow logs | Network logging costs money | Deferred |
| CKV2_AWS_12 default security group | The VPC default group keeps its default rules | Deferred |
| CKV2_AWS_41 no IAM role on instance | Instance had no identity | **Fixed** later with an instance profile (section 11) |

For S3, two findings were accepted with reasons, written next to the code:

```hcl
resource "aws_s3_bucket" "mtc_bucket" {
  #checkov:skip=CKV_AWS_18:Lab bucket, no real traffic to audit; logging bucket adds cost
  #checkov:skip=CKV_AWS_145:AES256 encryption is on; a customer-managed KMS key costs money and a lab does not need it
  ...
}
```

A report with deliberate, explained skips is more credible than one with everything "fixed" or everything ignored.

---

## 10. IAM: roles, trust, and temporary credentials

### The vocabulary

- **IAM user**: a long-lived identity with permanent keys (my `terraform-demo`).
- **IAM role**: an identity with **no permanent keys**. Someone *assumes* it and receives **temporary credentials** that expire (about an hour by default).
- **STS** (Security Token Service): the AWS service that issues those temporary credentials.
- **Policy**: a JSON document listing what is allowed or denied.

Roles are safer than keys because stolen temporary credentials stop working on their own.

### What an ARN is

An **ARN** (Amazon Resource Name) is the unique address of anything in AWS:

```
arn:partition:service:region:account-id:resource
arn:aws:iam::<ACCOUNT_ID>:role/mtc_labreadonly
```

| Part | Here | Meaning |
|---|---|---|
| `arn` | `arn` | Always first |
| partition | `aws` | The AWS family (almost always `aws`) |
| service | `iam` | Which service owns it |
| region | *(empty)* | IAM is global, so it is blank |
| account-id | `<ACCOUNT_ID>` | The owning account |
| resource | `role/mtc_labreadonly` | Type and name |

AWS-managed policies show `aws` where the account ID would be, e.g. `arn:aws:iam::aws:policy/ReadOnlyAccess`. After assuming a role, my identity looks different: `arn:aws:sts::<ACCOUNT_ID>:assumed-role/mtc_labreadonly/botocore-session-...`.

### Two policies on every role

| Policy | Question it answers | Where it lives |
|---|---|---|
| **Trust policy** | *Who* may become this role? | `assume_role_policy` |
| **Permissions policy** | *What* can it do once assumed? | An attachment or inline policy |

### My first role: a read-only role that only my user can assume

New variables, so values are not hardcoded:

```hcl
variable "trusted_user" {
  type        = string
  description = "IAM user allowed to assume the lab role"
  default     = "terraform-demo"
}

variable "role_name" {
  type        = string
  description = "Name of the lab role"
  default     = "mtc_labreadonly"
}

variable "role_policy_arn" {
  type        = string
  description = "Managed policy attached to the lab role"
  default     = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
```

The role (`iam.tf`):

```hcl
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "mtc_labreadonly" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.trusted_user}"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "mtc_labreadonly" {
  role       = aws_iam_role.mtc_labreadonly.name
  policy_arn = var.role_policy_arn
}

output "mtc_labreadonly_arn" {
  value = aws_iam_role.mtc_labreadonly.arn
}
```

Line by line:

- The **data source** gives the account ID, so it is not typed into code or pushed to git.
- `jsonencode()` turns a Terraform map into correctly formatted JSON.
- `Version = "2012-10-17"` is the fixed policy language version.
- `Effect = "Allow"` with `Action = "sts:AssumeRole"` permits becoming this role.
- `Principal` names **exactly one user** by ARN. A wildcard principal (`"*"`) would let anyone try, and an over-broad trust policy is a classic cloud vulnerability.
- The attachment gives the role AWS's `ReadOnlyAccess`. A new role can do nothing until you attach something.
- `${...}` inserts a value into a string, and `var.name` reads a variable.

My mistakes here: the attachment referred to a role name that did not match the resource label (`Reference to undeclared resource`), and one line had a folder path pasted where `user/terraform-demo` belonged, which would have failed with `MalformedPolicyDocument`.

### Assuming the role from the CLI

`~/.aws/config`:

```ini
[profile lab_readonly]
role_arn       = arn:aws:iam::<ACCOUNT_ID>:role/mtc_labreadonly
source_profile = terraform_demo
region         = us-west-2
```

`source_profile` is the identity used to *ask* for the role. The CLI calls `sts:AssumeRole` and caches the temporary credentials. No new secret keys exist anywhere. (My first attempt left the placeholder `<ROLE_ARN>` in the file, which AWS rejected as too short, `Invalid length for parameter RoleArn`.)

```bash
aws sts get-caller-identity --profile terraform_demo   # ...:user/terraform-demo
aws sts get-caller-identity --profile lab_readonly     # ...:assumed-role/mtc_labreadonly/...
aws ec2 describe-vpcs --region us-west-2 --profile lab_readonly                      # works
aws ec2 create-vpc --cidr-block 10.98.0.0/16 --dry-run --region us-west-2 --profile lab_readonly   # denied
```

The read worked and the create was denied with `because no identity-based policy allows the ec2:CreateVpc action`, an implicit deny. User IDs start with `AIDA...` while role IDs start with `AROA...`. `--dry-run` asks AWS whether the call *would* be allowed, without doing it.

---

## 11. Instance profiles, IMDSv2 and the 401 test

### The goal

A server often needs to call AWS (read a bucket, for example). The bad way is to store an access key on it. The good way is to give the server a **role** and let AWS hand it short-lived credentials automatically.

### The role for EC2

The trust policy now names a **service**, not a user:

```hcl
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mtc_ec2_role" {
  name               = "mtc_ec2_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_instance_profile" "mtc_ec2_profile" {
  name = "mtc_ec2_profile"
  role = aws_iam_role.mtc_ec2_role.name
}
```

- `aws_iam_policy_document` builds the policy JSON from readable blocks (same result as `jsonencode`).
- `type = "Service"` with `ec2.amazonaws.com` lets the EC2 service hand this role to a server.
- An **instance profile** is the container that carries a role onto an instance. The console hides it, but Terraform needs it as a separate resource.
- The profile must contain the role whose trust policy names EC2. Putting `mtc_labreadonly` (whose trust names a *user*) in it would not work, because EC2 would not be allowed to assume it.

The server uses it through one line in `aws_instance`: `iam_instance_profile = aws_iam_instance_profile.mtc_ec2_profile.name`.

### One tiny permission (least privilege)

```hcl
resource "aws_iam_role_policy" "mtc_ec2_describe_vpcs" {
  name = "describe-vpcs-only"
  role = aws_iam_role.mtc_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:DescribeVpcs"
      Resource = "*"
    }]
  })
}
```

- This is an **inline** policy, attached to one role. The earlier attachment used a reusable managed policy.
- It allows **one exact action**, not `ec2:*` or `ReadOnlyAccess`.
- `Resource = "*"` is needed because `Describe*` calls cannot be narrowed to one resource.

### What the metadata service is

Every EC2 instance can reach a special address, `169.254.169.254`, that works **only from inside the instance**. It tells the server about itself, including the **temporary credentials of its role**.

### Why that is dangerous: SSRF

**SSRF** (Server-Side Request Forgery) is a web-app bug where an attacker makes the *server* fetch a URL they choose. If the attacker points it at `http://169.254.169.254/...`, the server fetches its own credentials and hands them over. This is a well-known path in real cloud breaches and in training labs.

### The fix: require IMDSv2

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"
  http_put_response_hop_limit = 1
}
```

| | IMDSv1 (old) | IMDSv2 (what I required) |
|---|---|---|
| How to read data | One plain `GET` | First a `PUT` to get a session token, then a `GET` that carries the token |
| Simple SSRF works? | Yes | No, because most SSRF bugs can only trigger a plain `GET` |

- `http_tokens = "required"` turns on IMDSv2.
- `http_put_response_hop_limit = 1` stops containers on the server from reaching the metadata service. If a container ever needs it, the limit would be raised to 2.

### The test I ran on the instance

```bash
# 1. no keys stored on the machine
ls ~/.aws 2>&1                         # No such file or directory
env | grep -c AWS_ACCESS_KEY           # 0

# 2. the proper two-step way works
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/
# prints: mtc_ec2_role

# 3. a plain request with no token is refused
curl -s -o /dev/null -w "%{http_code}\n" http://169.254.169.254/latest/meta-data/iam/security-credentials/
# prints: 401
```

**Why 401 is the result I wanted.** `401 Unauthorized` means "you did not present a valid token". A successful attack would return `200` and a block of credentials. Getting `401` for the token-less request proves the simple attack path is closed, and getting the role name with a token proves the legitimate path still works.

I did not print the credential endpoint itself (`.../security-credentials/mtc_ec2_role`), because it returns a live key, secret and session token.

Then I used the role from the server, with no keys configured:

```bash
sudo snap install aws-cli --classic
export AWS_DEFAULT_REGION=us-west-2
aws sts get-caller-identity
# ...:assumed-role/mtc_ec2_role/i-0...   (the session name is the instance ID)

aws ec2 describe-vpcs   # denied until the policy above existed, then allowed
aws ec2 create-vpc --cidr-block 10.97.0.0/16 --dry-run   # denied
aws s3 ls               # denied
```

Two protections stack: **IMDSv2 makes the credentials harder to steal, and least privilege makes them less useful if stolen.**

---

## 12. S3: buckets and the public-bucket experiment

### What S3 is

S3 is cloud file storage. Files are **objects**, stored in **buckets**. Bucket names are unique across all of AWS, so I include my account ID in mine.

### Who can read an object: three layers plus a master switch

| Layer | What it is | Example |
|---|---|---|
| **IAM policy** (identity-based) | Attached to a user or role | "`mtc_ec2_role` may read this bucket" |
| **Bucket policy** (resource-based) | Attached to the bucket | "Allow this role, deny everyone else" |
| **ACL** (legacy) | Old per-object permissions | "Everyone can read this file" |
| **Block Public Access** | A master switch above the others | Overrides any public grant |

### The private bucket (`s3.tf`)

```hcl
resource "aws_s3_bucket" "mtc_bucket" {
  bucket        = "mtc-lab-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "mtc-lab-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "mtc_bucket" {
  bucket                  = aws_s3_bucket.mtc_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "mtc_bucket" {
  bucket = aws_s3_bucket.mtc_bucket.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "mtc_bucket" {
  bucket = aws_s3_bucket.mtc_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mtc_bucket" {
  bucket = aws_s3_bucket.mtc_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

- `force_destroy = true` lets `terraform destroy` delete a bucket that still has files. It is a **lab-only** setting.
- The four Block Public Access switches together make public access impossible, whatever a policy or ACL says.
- `BucketOwnerEnforced` turns ACLs off completely (AWS's current recommendation).
- **Versioning** keeps old versions, which protects against accidental overwrites and deletes.
- **Encryption** at rest is on (S3 does this by default now, but writing it down makes it visible to scanners).

### Letting the server read exactly one bucket

```hcl
resource "aws_iam_role_policy" "mtc_ec2_read_bucket" {
  name = "read-lab-bucket-only"
  role = aws_iam_role.mtc_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListThisBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.mtc_bucket.arn
      },
      {
        Sid      = "ReadObjectsInThisBucket"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.mtc_bucket.arn}/*"
      }
    ]
  })
}
```

**Why two statements:** S3 has two kinds of ARN. The bucket (`arn:aws:s3:::name`) is what `s3:ListBucket` applies to. The objects inside it (`arn:aws:s3:::name/*`) are what `s3:GetObject` applies to. Mixing them up is one of the most common IAM mistakes and gives `AccessDenied` even when the action looks right.

Results from the instance:

| Command | Result | Why |
|---|---|---|
| `aws s3 ls s3://<bucket>/` | Listed the file | Role has `s3:ListBucket` on this bucket |
| `aws s3 cp s3://<bucket>/hello.txt -` | Printed the contents | Role has `s3:GetObject` on the objects |
| `aws s3 cp /etc/hostname s3://<bucket>/x.txt` | `AccessDenied` | No `s3:PutObject` granted |
| `aws s3 ls` (no bucket) | `AccessDenied` | No `s3:ListAllMyBuckets` granted |

### The public-bucket experiment (safe, throwaway, harmless file)

First I checked whether the **account-level** Block Public Access existed:

```bash
aws s3control get-public-access-block --account-id <ACCOUNT_ID> --profile terraform_demo --region us-west-2
# NoSuchPublicAccessBlockConfiguration  -> no account-level protection is set
```

So only the bucket-level settings decide whether a bucket can be public, which is itself a finding. Then, on a separate throwaway bucket, I turned Block Public Access **off** and attached a policy allowing everyone to read:

```hcl
resource "aws_s3_bucket_public_access_block" "public_test" {
  bucket                  = aws_s3_bucket.public_test.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "public_test" {
  bucket     = aws_s3_bucket.public_test.id
  depends_on = [aws_s3_bucket_public_access_block.public_test]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.public_test.arn}/*"
    }]
  })
}
```

`depends_on` matters because S3 rejects a public policy while Block Public Access is still on, so the block must be switched off first.

An anonymous request, with no credentials at all:

```bash
curl -s https://<bucket>.s3.us-west-2.amazonaws.com/public.txt
# prints the file contents -> anyone on the internet can read it
```

Then I set all four switches back to `true` and repeated the request:

```
<Error><Code>AccessDenied</Code><Message>Access Denied</Message>...
```

The public policy was **still attached**, and it no longer worked. Block Public Access overrides it. One master switch beats a dangerous policy.

I then deleted the experiment file and destroyed the bucket.

### The three lines I would say in an interview

1. **Attack:** a bucket policy with `Principal = "*"` plus Block Public Access off makes objects readable by anyone.
2. **Prevent:** Block Public Access on at bucket **and** account level, ACLs disabled, no wildcard principals.
3. **Detect:** CloudTrail events `PutBucketPolicy` and `PutBucketPublicAccessBlock`, plus IAM Access Analyzer findings for public buckets.

---

## 13. Detection: finding my own activity in CloudTrail

**CloudTrail** records API activity in an account. **Event history** keeps 90 days of **management events** (changes to settings and resources) for free, with no setup.

```bash
aws cloudtrail lookup-events --region us-west-2 --profile terraform_demo \
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPolicy \
  --max-results 3 --query 'Events[].[EventTime,Username,EventName]' --output table
```

To read a full event:

```bash
aws cloudtrail lookup-events --region us-west-2 --profile terraform_demo \
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutBucketPolicy \
  --max-results 1 --query 'Events[0].CloudTrailEvent' --output text \
  | python3 -c 'import sys,json; e=json.load(sys.stdin); print({k:e.get(k) for k in ["eventTime","sourceIPAddress","userAgent","awsRegion","errorCode"]}); print(e["requestParameters"].get("bucketName"))'
```

### How an investigator reads one event

| Field | What I saw | What it tells an investigator |
|---|---|---|
| `eventTime` | A UTC timestamp | When (CloudTrail uses UTC, so convert to local time) |
| `sourceIPAddress` | My laptop's IP | Where the call came from |
| `userAgent` | `... Terraform ... terraform-provider-aws ... aws-sdk-go-v2` | Which tool: Terraform here, a browser string for the console, `aws-cli` for the CLI |
| `errorCode` | None | The call succeeded |
| `bucketName` | The test bucket | What was changed |

A known identity, a known IP and a known tool means a normal change. The same call from an unfamiliar IP, a browser agent or an unrecognised role is the red flag.

### The timeline of the experiment

1. `PutBucketPublicAccessBlock`: Block Public Access switched **off**.
2. `PutBucketPolicy` one second later: the public policy attached.
3. `PutBucketPublicAccessBlock` about five minutes later: switched back **on**.

So the bucket was exposed for roughly five minutes. A burst of "block off, then public policy on" within seconds is itself a pattern to alert on.

### What CloudTrail did NOT show

My anonymous `curl` that fetched the file is not in the list. Reading an object (`GetObject`) is a **data event**, which is not recorded by default and needs a separate trail (which costs money). So CloudTrail tells me **when** a bucket became public, but not **who read the files** while it was open unless data events or S3 access logging were enabled.

### Filtering noise

A busy account has many harmless `AssumeRole` events. The newest one I looked at was AWS Resource Explorer using its own service-linked role, which is background activity. Filtering by role ARN cuts through it:

- `userIdentity.type = IAMUser` with a real source IP: a person or tool assuming a role (my CLI profile).
- `userIdentity.type = AWSService` with source `ec2.amazonaws.com`: EC2 handing a role to a server at launch, which is routine.

### How I would detect it for real

- An **EventBridge** rule on `PutBucketPolicy`, `DeleteBucketPublicAccessBlock` or `PutBucketAcl`, sending an alert through SNS.
- **IAM Access Analyzer** for buckets that become public or shared outside the account.
- **GuardDuty** for anomalous S3 and credential activity (check current pricing and the free trial first).
- **AWS Config** rules that continuously check for public buckets.

---

## 14. Secrets hygiene, cost safety and cleanup

### Keeping secrets out of git

`.gitignore`:

```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
crash.log
```

- Commit `.terraform.lock.hcl` (it pins provider versions) and `terraform.tfvars.example` (a template with a fake value).
- Do not paste state files or unredacted debug logs into chats or issues.

### gitleaks

**gitleaks** scans for secrets (access keys, tokens, private keys):

```bash
gitleaks git -v        # every commit in history
gitleaks dir . -v      # files on disk right now, including untracked ones
```

My results: all commits scanned, **no leaks**, and the working directory was clean too. To make sure the tool could actually find something, I scanned a throwaway folder containing an invented key. It flagged the secret line (rule `generic-api-key`). A clean result only means something if the scanner is shown to work.

A pre-commit hook blocks a commit that contains a secret before it enters history:

```bash
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/sh
gitleaks git --pre-commit --staged -v
EOF
chmod +x .git/hooks/pre-commit
```

I tested it by committing a fake secret, and the commit was refused. Limits: hooks live in `.git/hooks`, which git does not track, so a team needs CI scanning or a shared hook manager. I also confirmed my deleted old key ID never appeared in history:

```bash
git log --all -S'<OLD_KEY_ID_PREFIX>' --oneline    # no output
```

If a key ever does leak: **rotate it first**, then clean the history. Deleting a file does not remove it from past commits.

### Cost safety

- Moving to advanced features **removed my spend limit**, so I created a budget in the management account. A **zero-spend budget** emails me as soon as any cost appears, which is the right tripwire for a free-tier lab.
- Free tier has allowances and a time limit. Running past them, or using services outside the free list, costs money. The Free Tier page in the billing console shows usage.
- Watch the usual surprises: running instances, public IPv4 addresses, and NAT gateways (billed hourly, so avoided in labs).
- `terraform destroy` at the end of **every** session, then confirm nothing is left:

```bash
terraform state list
aws ec2 describe-instances --region us-west-2 --profile terraform_demo \
  --filters Name=instance-state-name,Values=running,pending,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text
aws s3 ls --profile terraform_demo
```

IAM roles and policies cost nothing, but servers bill while they run.

### Rules of engagement for attack practice

Only test my own accounts and intentionally vulnerable training targets (flaws.cloud, flaws2.cloud, CloudGoat). Never point scanners or exploitation tools at an account I do not own.

---

## 15. Error log: what broke and how I fixed it

| Symptom | Cause | Fix |
|---|---|---|
| `failed to get shared config profile, terraform_demo` | `shared_credentials_files` pointed at the downloaded keys **CSV**, which is not the credentials format | Remove that line; create the profile with `aws configure --profile terraform_demo` |
| `aws: command not found` | AWS CLI not installed | Install `awscli2` |
| `Could not connect to the endpoint URL` | Network or DNS problem on my machine | Check connectivity with `curl` and `ping` before blaming credentials |
| `UnauthorizedOperation ... explicit deny in a service control policy` | An organization guardrail denied the action. Admin IAM rights cannot override it | Decode the message, find the statement, edit the SCP in the **management account** |
| Console showed nothing after a successful apply | Wrong **account** or wrong **region** in the console | Check the banner for the account ID and the region selector |
| `Unsupported block type: tag` | Route table tags are a map (`tags = {}`), not a block | Use `tags = { Name = "..." }` |
| Subnet `InvalidParameterValue ... availabilityZone` | Region changed, AZ still named another region | Keep `availability_zone` in the provider's region |
| `Can't configure a value for "name"` | Set `name` at the top level of a data source | Delete it; keep `name` only inside `filter` |
| Security group `UnknownError` on create | Transient failure; group existed in AWS but not in state | Delete the orphan or `terraform import` it, then apply |
| `Reference to undeclared resource` | A resource label did not match its references | Make the label identical everywhere it is used |
| `MalformedPolicyDocument` (caught before apply) | A folder path was pasted where `user/<name>` belonged in an ARN | Fix the ARN |
| `Invalid length for parameter RoleArn, value: 10` | The literal placeholder `<ROLE_ARN>` was left in `~/.aws/config` | Replace placeholders with real values |
| `bash: syntax error near unexpected token newline` | Typed `<public-ip>` literally; bash treats `<` as a redirect | Never type angle brackets, substitute the real value |
| `Permission denied (publickey)` on git push | GitHub did not have my SSH public key | Upload the key (`gh ssh-key add`) |
| `Repository not found` | The remote repo did not exist yet | `gh repo create <name> --private` |
| Push rejected, "fetch first" | GitHub had a commit I lacked (a README) | `git pull --rebase origin main`, then push. Never force-push to fix it |
| SSH times out after changing network | My IP changed and the security group only allows the old one | `terraform apply -var="my_ip=$(curl -s https://checkip.amazonaws.com)/32"` |
| Ran instance commands on my laptop | The prompt was `comrade@...`, not `ubuntu@ip-...` | Always check the prompt before running server-side commands |

### Patterns behind the mistakes

- **Placeholders pasted literally** caused four separate errors. Read each command and replace every `<...>`.
- **Wrong account or region** caused repeated "missing resource" scares.
- **Stale or unsaved files**: a scan once showed no change because my edit was not saved. Check with `grep` that the edit is in the file.

---

## 16. Command cheat sheet

```bash
# Terraform
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
terraform apply -var="my_ip=$(curl -s https://checkip.amazonaws.com)/32"
terraform apply -target=aws_iam_role.mtc_labreadonly     # lab shortcut only
terraform destroy
terraform output
terraform state list
terraform state show <address>
terraform import <address> <id>

# Who am I, and what can I see?
aws sts get-caller-identity --profile terraform_demo
aws iam list-access-keys --user-name terraform-demo --profile terraform_demo
aws ec2 describe-security-groups --region us-west-2 --profile terraform_demo

# Would this be allowed? (changes nothing)
aws ec2 create-vpc --cidr-block 10.99.0.0/16 --dry-run --region us-west-2 --profile terraform_demo

# Decode a permissions error
aws sts decode-authorization-message --encoded-message '<string>' --profile terraform_demo

# Scanning
checkov -d . --quiet
gitleaks git -v
gitleaks dir . -v

# Detection
aws cloudtrail lookup-events --region us-west-2 --profile terraform_demo \
  --lookup-attributes AttributeKey=EventName,AttributeValue=<EventName> --max-results 5

# Git
git status --short
git pull --rebase origin main
git log --oneline --graph --all

# Quality of life
export AWS_PAGER=""      # stop the CLI opening a pager
```

---

## 17. Interview questions and answers

The answers are written the way I would say them out loud.

### A. Terraform fundamentals

**Q: What is Terraform and why use it instead of the console?**
It is an Infrastructure as Code tool. I describe the infrastructure I want in files, and Terraform builds it. The result is repeatable, reviewable in git, and scannable by security tools before anything exists. I could destroy and rebuild my whole lab in about a minute.

**Q: Explain the Terraform workflow.**
`init` downloads provider plugins, `plan` shows what would change without changing it, `apply` makes the changes, and `destroy` removes everything. I read every plan, looking first for `destroy` and `replace`.

**Q: What is a provider?**
A plugin that knows how to talk to one platform's API. I use the AWS provider, pinned with `version = "~> 6.0"` so a major upgrade cannot surprise me. The `.terraform.lock.hcl` file pins the exact version and is committed.

**Q: What is the difference between a resource and a data source?**
A resource is something Terraform creates and manages. A data source is a read-only lookup of something that already exists. I use `aws_ami` to look up the newest Ubuntu image, and `aws_caller_identity` to get my account ID without hardcoding it.

**Q: How does Terraform decide the order to build things?**
From references. If a subnet uses `aws_vpc.mtc_vpc.id`, Terraform knows the VPC comes first. It builds a dependency graph and runs independent resources in parallel. `depends_on` is for hidden dependencies, like my S3 policy needing Block Public Access changed first.

**Q: What does "idempotent" mean here?**
Running `apply` twice gives the same result. The second run reports no changes because the real infrastructure already matches the code.

**Q: What do `~`, `+`, `-` and `-/+` mean in a plan?**
Change in place, create, destroy, and destroy-then-recreate (replace). A replace on something that holds data, such as a database, is the line I would stop and investigate.

**Q: What is a provisioner, and why are they discouraged?**
A script run after a resource is created. I used `local-exec` to append an SSH config entry. It runs only on creation, is not tracked in state, and fails in ways Terraform cannot reason about, so real projects prefer cloud-native approaches like `user_data`, images or configuration management.

**Q: What is `user_data`?**
A script an EC2 instance runs once at first boot. Mine installs Docker. Changing it does not re-run it on an existing server, and Terraform reports success before the script finishes.

### B. State

**Q: What is Terraform state and why does it matter?**
It maps my code to real resource IDs. Without it Terraform could not tell create from update and would build duplicates. It also stores resource attributes, which can include secrets in plain text.

**Q: How should state be stored for a team?**
Remotely, in something like S3 with encryption, versioning and locking, so two people cannot run `apply` at once and nobody keeps a private copy. I used local state in the lab and have not built a remote backend yet.

**Q: What happens if the state file is lost?**
The resources keep running and billing, but Terraform no longer knows about them. Recovery is `terraform import`, one resource at a time, which is why remote state with versioning matters.

**Q: What is drift?**
When real infrastructure no longer matches the code, usually because someone changed it by hand in the console. The next `plan` shows the difference, and `apply` reverts the change. That is why I fix things in code, not in the console.

**Q: What is `terraform import` for?**
Adopting an existing resource into state. I used the idea when a security group existed in AWS but not in state, and the alternative was deleting it and recreating it.

**Q: How do you rename a resource without destroying it?**
`terraform state mv old new`, or a `moved` block. Just renaming it in code makes Terraform plan a destroy and a create.

**Q: What is the risk of `terraform state rm`?**
It makes Terraform forget a resource without deleting it, so the resource keeps running untracked.

**Q: Is it safe to commit state to git?**
No. It can contain secrets and real IDs. `*.tfstate*` and `*.tfvars` are in my `.gitignore`.

### C. Variables and code quality

**Q: How do variables get their values, and what wins?**
From defaults, `terraform.tfvars`, `-var-file`, environment variables and `-var`. The last one specified wins, except that `terraform.tfvars` beats an environment variable. That is why I use `-var` when my IP changes.

**Q: How do you stop a bad value from reaching production?**
A `validation` block. Mine requires `my_ip` to be a single address ending in `/32`, so the "open to the world" value `0.0.0.0/0` is rejected on `plan`. It checks format only, so a wrong-but-valid IP still gets through, and a human must compare it.

**Q: Why did `terraform validate` pass when my variable value was bad?**
`validate` checks syntax and references, not variable values. The validation rule runs on `plan` and `apply`.

**Q: What is `-target`, and why is it dangerous?**
It applies only chosen resources. It bypasses the normal full dependency check and can leave the configuration half-applied, so I used it only for a lab exercise.

**Q: What are modules, `count` and `for_each`?**
Modules package reusable infrastructure, and `count` and `for_each` create many similar resources from one block. I understand the idea but have not built them yet (see section 18).

### D. AWS networking

**Q: What makes a subnet public?**
A route table with a route to an internet gateway (`0.0.0.0/0`). Remove that route and the subnet is private. A public IP on the instance is also needed for inbound access.

**Q: Security group versus NACL?**
A security group is a **stateful** firewall on the instance's network interface, with allow rules only. A network ACL is a **stateless** firewall at the subnet level, with numbered allow and deny rules, so return traffic needs its own rule.

**Q: Why is `0.0.0.0/0` on all ports a finding?**
It exposes every service on the server to the whole internet. Bots find open ports within minutes. I replaced it with one port (22), one protocol (TCP) and one address (`/32`).

**Q: What does `/32` mean?**
A single IP address. `/24` is 256 addresses, `/16` is 65,536, and `/0` is everything.

**Q: Why not just open SSH to everyone and rely on the key?**
Keys are strong, but exposing the port invites brute force, scanning and any future SSH vulnerability. Restricting the source address removes most of that exposure. An even better design avoids open ports using Session Manager.

**Q: Why did SSH stop working when I changed networks?**
The rule allows only the IP I applied. The fix is to update the rule, never to open it to everyone.

**Q: Why avoid a NAT gateway in a lab?**
It is billed by the hour and is easy to forget.

### E. IAM and identity

**Q: IAM user versus role?**
A user has long-lived keys. A role has none, and whoever assumes it receives temporary credentials from STS that expire. Roles are safer because stolen credentials stop working on their own.

**Q: What is a trust policy versus a permissions policy?**
The trust policy says who may assume the role. The permissions policy says what the role can do. Both are needed. A role with a broad trust policy is a real vulnerability class.

**Q: What is an ARN?**
The unique address of any AWS resource, in the form `arn:partition:service:region:account:resource`. Policies and trust relationships use ARNs to name exactly one thing.

**Q: What is an instance profile?**
The container that attaches a role to an EC2 instance. Terraform needs it as a separate resource.

**Q: Why did giving my user `AdministratorAccess` not fix the 403?**
The error said **explicit deny in a service control policy**. An SCP sits above IAM at the organization level, and an explicit deny beats any allow. The fix had to be made in the management account.

**Q: How do you tell an implicit deny from an explicit deny?**
The message wording. "No identity-based policy allows ..." is implicit, so add an allow. "Explicit deny in ..." names the policy type, so find and change that policy.

**Q: What is an SCP, and does it grant permissions?**
A guardrail that sets the maximum permissions for accounts in an organization. It never grants anything by itself. The request still needs an IAM allow inside the limit.

**Q: What is least privilege, with an example from my lab?**
Granting only what is needed. My server's role could do `ec2:DescribeVpcs`, and later read one bucket (`s3:ListBucket` on the bucket and `s3:GetObject` on its objects), and nothing else. Writes and listing other buckets were denied, and I tested that.

**Q: How do you debug an `AccessDenied`?**
Identify who I am (`get-caller-identity`), read the error for the action and resource, check implicit versus explicit, decode the authorization message if there is one, and then check the layers: IAM policy, resource policy, SCP, permission boundary.

**Q: What are the risks of access keys, and how do you reduce them?**
They are long-lived and easy to leak. I rotated mine (create new, test, deactivate old, test, delete), kept them out of git, deleted the CSV, and prefer roles with temporary credentials. In CI, OIDC role assumption is better than stored keys.

### F. Metadata service, SSRF and the 401 test

**Q: Explain what you did with IMDSv2 and why.**
I required IMDSv2 on the instance so a simple SSRF can't read the metadata service. A plain request returns 401, and only the token-based request works. I also gave the role a single permission, so a stolen credential could only list VPCs.

**Q: What is the instance metadata service?**
A special address (`169.254.169.254`) reachable only from inside an EC2 instance. It exposes information about the instance, including the temporary credentials of its role.

**Q: What is SSRF and why does it matter in AWS?**
Server-Side Request Forgery lets an attacker make a server fetch a URL of their choice. If the server can reach the metadata service, the attacker can have it fetch its own role credentials. This pattern appears in real breaches and in training labs.

**Q: How does IMDSv2 stop that?**
It needs a `PUT` request first to obtain a session token, then a `GET` carrying the token. Most SSRF bugs can only make a plain `GET`, and the `PUT` response is not forwarded beyond the instance by default. A request without a token gets `401`.

**Q: What does `http_put_response_hop_limit = 1` do?**
It limits how many network hops the token response can travel, which stops containers on the host from reaching the metadata service. If a container legitimately needs it, raise the limit to 2.

**Q: If credentials are stolen from the instance, how bad is it?**
It depends on the role. With my role the attacker could only describe VPCs or read one bucket. They also expire, typically within hours. That is the point of combining IMDSv2 with least privilege.

**Q: How would you prove IMDSv2 is enforced?**
From the instance, request the credentials endpoint with no token and expect `401`, then fetch a token and expect to receive the role name. I also confirmed there were no keys on the machine.

### G. S3

**Q: What controls who can read an S3 object?**
IAM policies on the caller, the bucket policy on the resource, and legacy ACLs, with **Block Public Access** as a master switch that overrides public grants. I turn ACLs off with `BucketOwnerEnforced`.

**Q: What caused many public bucket leaks, and how do you prevent them?**
A policy or ACL granting access to everyone, with Block Public Access off. Prevent it with Block Public Access at bucket **and** account level, no wildcard principals, and Access Analyzer to flag exposure.

**Q: What did your experiment show?**
With Block Public Access off and a `Principal = "*"` policy, an anonymous `curl` read the file. After re-enabling Block Public Access, the same request returned `AccessDenied` even though the policy was still attached.

**Q: Why two statements in the read policy?**
The bucket and its objects have different ARNs. `s3:ListBucket` applies to the bucket ARN, and `s3:GetObject` applies to `bucket-arn/*`. Mixing them gives `AccessDenied` even with the right action.

**Q: Why did I turn on versioning and encryption?**
Versioning protects against accidental overwrite or deletion, and encryption protects data at rest. I accepted a customer-managed KMS key and access logging as lab-only trade-offs because they add cost.

**Q: What does `force_destroy` do, and when would you never use it?**
It lets Terraform delete a non-empty bucket. I never would on a bucket with real data, because one wrong `destroy` would wipe it.

### H. Detection and logging

**Q: How would you detect someone making a bucket public?**
CloudTrail shows `PutBucketPolicy` and `PutBucketPublicAccessBlock` with the identity, source IP and tool. I would alert on those events through EventBridge and SNS, and use IAM Access Analyzer for public exposure.

**Q: What does CloudTrail Event history not show?**
Data events such as `GetObject`. It tells me when a bucket became public, not who read from it, unless data events or S3 access logs were enabled.

**Q: How do you tell a normal change from a suspicious one?**
Compare the identity, source IP and user agent with what I expect. Terraform from my own IP is normal. The same call from an unknown IP, a browser agent or an unfamiliar role is suspicious.

**Q: What is the difference between a user assuming a role and a service assuming one?**
In CloudTrail the user shows `IAMUser` with a real source IP. A service shows `AWSService` with the service name as the source, for example EC2 handing a role to an instance at launch.

**Q: Which tools help with detection in AWS?**
CloudTrail for the activity log, GuardDuty for threat detection, Config for continuous configuration checks, Access Analyzer for exposure, and EventBridge for alerting.

### I. Secrets, scanning and CI

**Q: How do you keep secrets out of a repo?**
`.gitignore` for state and variable files, a pre-commit hook running gitleaks, gitleaks in CI, and rotating anything that might have leaked. I scanned all commits and the working directory, and confirmed the scanner works by catching a fake key.

**Q: A key was committed. What do you do?**
Rotate it immediately, then clean history. Deleting the file does not remove it from past commits.

**Q: What does checkov do and how did you use it?**
It scans infrastructure code for insecure settings before deployment. I triaged my findings: I fixed IMDSv1 and the missing role, and accepted others with a written reason, for example `t2.micro` cannot be EBS optimized.

**Q: Why use OIDC instead of stored keys in GitHub Actions?**
OIDC lets the pipeline assume a role and receive short-lived credentials, so no long-lived key sits in repository secrets. The trust policy must be tight: scoped to a specific repo and branch, or it becomes a vulnerability.

### J. Scenarios

**Q: `terraform plan` shows one resource being destroyed and recreated. What do you do?**
Stop and read why. Find the attribute that forces a replacement, and decide whether it is expected. For anything with data, add `lifecycle { prevent_destroy = true }` or change the code to avoid replacement.

**Q: `apply` fails halfway through. What state are you in?**
Some resources exist and some do not. Terraform's state records what succeeded. I check `terraform state list`, `plan` and the console. If a resource exists in AWS but not in state, I import it or delete it, then apply again.

**Q: I get a 403 as an admin. Where do I look?**
At the error text. If it mentions an SCP or explicit deny, it is organization-level. If it says no identity-based policy allows it, my IAM policy is missing the action. Then check resource policies and permission boundaries.

**Q: A teammate changed a security group in the console. What happens?**
That is drift. `plan` shows the difference and `apply` reverts it. The right fix is to change the code through review.

**Q: SSH stopped working after I moved networks. Why, and what is the fix?**
My IP changed and the security group allows only the old one. Update `my_ip` and apply, and do not open the rule to everyone.

**Q: How would you let a server read one S3 bucket without storing keys on it?**
Create a role trusted by `ec2.amazonaws.com`, attach a policy allowing `s3:ListBucket` on the bucket and `s3:GetObject` on its objects, wrap it in an instance profile, and attach the profile to the instance. Require IMDSv2.

**Q: You find a publicly readable bucket. What do you do?**
Turn on Block Public Access, check CloudTrail for who changed it and when, check access logs or data events for who read it, rotate anything exposed, and add detection so it is flagged quickly next time.

**Q: Walk me through an attack from SSRF to data access, and how you would prevent and detect it.**
An attacker finds an SSRF bug in a web app on the instance and makes it request the metadata service, receiving the role's temporary credentials. With those they call AWS APIs from outside. **Prevent:** require IMDSv2, fix the SSRF bug, give the role least privilege, use Block Public Access. **Detect:** CloudTrail shows the role being used from an unexpected IP, and GuardDuty can flag credential use from an unusual location.

**Q: A destroy leaves something behind. How do you check?**
`terraform state list` should be empty, and I check for running instances, buckets and other billable resources directly with the CLI, in each region I used.

**Q: What would you do differently in production?**
Remote state with locking, modules, separate environments, OIDC for the pipeline instead of long-lived keys, access logging and KMS on buckets, VPC flow logs, GuardDuty and alerting, and no public IPs where Session Manager would do.

---

## 18. What I have not covered yet

Honest list of gaps:

- **Remote state** (S3 backend with locking).
- **Modules**, `count` and `for_each`, `locals`, and `sensitive` outputs.
- **`lifecycle` rules** (`prevent_destroy`, `create_before_destroy`) and `moved` blocks.
- **Multiple environments** (workspaces or separate directories).
- **Terraform in CI/CD** with OIDC and plan-on-pull-request.
- **Testing and policy as code** (`terraform test`, OPA or Sentinel).
- **Using short-lived credentials for Terraform itself** instead of an access key.
- **Detection beyond Event history:** GuardDuty, EventBridge alerts, Athena over CloudTrail.
- **Hands-on attack practice:** flaws.cloud, flaws2.cloud and CloudGoat (planned, not started).
- **VPC extras:** a private subnet, flow logs, security groups versus NACLs in practice.

Next steps: turn the network into a module and move state to S3, then work through flaws.cloud and write the attack, prevent and detect lines for each level.