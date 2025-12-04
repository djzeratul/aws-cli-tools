# AWS CLI Toolkit (Portable Bash/Zsh Helpers)

A collection of portable shell functions that streamline working with AWS CLI,
especially when using AWS SSO / IAM Identity Center.

The toolkit works in **both `bash` and `zsh`**, contains **no shell-specific
syntax**, and requires only the AWS CLI and `jq`.

---

## Features

### 🔹 SSO Aware
- Automatically detect SSO base profiles
- Extract SSO tokens from AWS cache
- Generate AWS profiles for *all* accounts and roles (`awssyncprofiles`)

### 🔹 Smart Profile Switching
- `awsjump` lets you pick **account → role** via a 2-step menu
- Automatically sets `AWS_PROFILE`
- Sorted alphabetically
- No AWS API calls → instant

### 🔹 Credential Management
- `awsfix` automatically detects expired credentials
- Offers to run `aws sso login` when needed

### 🔹 Utilities
- `awswhere` shows who you are (profile, region, ARN, account)
- `awsprofiles` lists all profiles with SSO metadata
- `awsclear` resets all AWS-related environment variables

---

## Installation

Clone your dotfiles repo (or create the folder):

```bash
mkdir -p ~/dev/dotfiles/aws-tools
cd ~/dev/dotfiles/aws-tools
```

Place `aws-tools.sh` in this directory.

---

## Shell Setup (Zsh or Bash)

Add this to your `~/.zshrc` **or** `~/.bashrc`:

```bash
AWS_TOOLS="$HOME/dev/dotfiles/aws-tools/aws-tools.sh"
[ -f "$AWS_TOOLS" ] && source "$AWS_TOOLS"
```

Reload your shell:

```bash
source ~/.zshrc     # or: source ~/.bashrc
```

---

## Dependencies

- **AWS CLI v2+**
- **jq** (required for JSON parsing)

macOS:

```bash
brew install awscli jq
```

Debian/Ubuntu:

```bash
sudo apt install awscli jq
```

---

## Usage Overview

### 1. Log in to AWS SSO (once per session)

```bash
aws sso login --profile <base-profile>
```

### 2. Generate profiles for all accounts & roles (optional, but recommended)

```bash
awssyncprofiles <base-profile> > ~/.aws/sso-generated-profiles
cat ~/.aws/sso-generated-profiles >> ~/.aws/config
```

Profiles are created in the form:

```text
marketing-shared-AWSAdministratorAccess
product-core-AWSReadOnlyAccess
```

---

## Daily Workflow

### Pick an account + role interactively

```bash
awsjump
```

This sets:

```bash
export AWS_PROFILE="<account>-<role>"
```

### Check who you are

```bash
awswhere
```

### Fix expired credentials

```bash
awsfix
```

### List all your profiles

```bash
awsprofiles
```

### Clear AWS environment vars

```bash
awsclear
```

---

## Function Reference

| Function | Description |
|---------|-------------|
| `awsbase` | Detect or select a base SSO profile |
| `aws_sso_token` | Extract SSO access token from AWS cache |
| `awssyncprofiles` | Generate AWS config profiles for all SSO accounts/roles |
| `awsjump` | Two-step selector (account → role), sets AWS_PROFILE |
| `awsfix` | Refresh expired SSO credentials |
| `awswhere` | Show current account/ARN/profile |
| `awsprofiles` | Display all profiles with SSO metadata |
| `awsclear` | Clear AWS_* environment vars |

---

## Recommended AWS Config Structure

```text
~/.aws/config
~/.aws/credentials
~/.aws/sso-generated-profiles   # append this to config
```

---

## Troubleshooting

### “Command not found”
Ensure your shell sources the toolkit:

```bash
source ~/dev/dotfiles/aws-tools/aws-tools.sh
```

### “ExpiredTokenException”
Run:

```bash
awsfix
```

### “Unknown profile”
Regenerate:

```bash
awssyncprofiles <base-profile>
```

---

## License

Free to use and modify for personal or professional setups.
