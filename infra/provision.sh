#!/bin/bash
# Provision AWS infrastructure for a claude-bot EC2 instance.
# Run from local machine. Reads all config from bot.yaml via yq.
#
# Usage: ./provision.sh [path/to/bot.yaml]
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

BOT_YAML="${1:-bot.yaml}"

if [ ! -f "$BOT_YAML" ]; then
  echo "Error: bot.yaml not found at '$BOT_YAML'"
  echo "Usage: $0 [path/to/bot.yaml]"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "Error: yq is required but not installed."
  echo "Install: brew install yq  (macOS) or see https://github.com/mikefarah/yq"
  exit 1
fi

BOT_NAME=$(yq -r '.name // "claude-bot"' "$BOT_YAML")
REGION=$(yq -r '.aws.region // "us-west-2"' "$BOT_YAML")
AWS_PROFILE=$(yq -r '.aws.profile // "default"' "$BOT_YAML")
INSTANCE_TYPE=$(yq -r '.aws.instance_type // "t3.medium"' "$BOT_YAML")
AMI=$(yq -r '.aws.ami // ""' "$BOT_YAML")
VOLUME_SIZE=$(yq -r '.aws.disk_gb // 30' "$BOT_YAML")
KEY_NAME=$(yq -r '.aws.key_name // ""' "$BOT_YAML")
SG_NAME=$(yq -r '.aws.security_group // ""' "$BOT_YAML")

# Apply defaults that depend on BOT_NAME
[ -z "$KEY_NAME" ] && KEY_NAME="$BOT_NAME"
[ -z "$SG_NAME" ] && SG_NAME="${BOT_NAME}-sg"

AWS="aws --profile $AWS_PROFILE --region $REGION"

# ─── AMI auto-detection ──────────────────────────────────────────────────────

if [ -z "$AMI" ]; then
  echo "Auto-detecting latest Ubuntu 24.04 AMI for $REGION..."
  AMI=$($AWS ec2 describe-images \
    --owners 099720109477 \
    --filters \
      "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
      "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)
  if [ -z "$AMI" ] || [ "$AMI" = "None" ]; then
    echo "Error: Could not auto-detect Ubuntu 24.04 AMI in $REGION"
    exit 1
  fi
  echo "Using AMI: $AMI"
fi

# ─── Provision ───────────────────────────────────────────────────────────────

echo "=== $BOT_NAME EC2 Provisioning ==="
echo "Region: $REGION | Profile: $AWS_PROFILE | Instance: $INSTANCE_TYPE"

# 1. SSH Key Pair
if $AWS ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
  echo "Key pair '$KEY_NAME' already exists"
else
  echo "Creating key pair..."
  $AWS ec2 create-key-pair --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > ~/.ssh/${KEY_NAME}.pem
  chmod 400 ~/.ssh/${KEY_NAME}.pem
  echo "Key saved to ~/.ssh/${KEY_NAME}.pem"
fi

# 2. Security Group
SG_ID=$($AWS ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  echo "Creating security group..."
  SG_ID=$($AWS ec2 create-security-group --group-name "$SG_NAME" \
    --description "$BOT_NAME EC2 - SSH access" --query 'GroupId' --output text)
  $AWS ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0
  echo "Security group created: $SG_ID"
else
  echo "Security group already exists: $SG_ID"
fi

# 3. Launch Instance
EXISTING=$($AWS ec2 describe-instances \
  --filters "Name=tag:Name,Values=$BOT_NAME" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "Instance already exists: $EXISTING"
  INSTANCE_ID="$EXISTING"
else
  echo "Launching instance..."
  INSTANCE_ID=$($AWS ec2 run-instances \
    --image-id "$AMI" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BOT_NAME}]" \
    --count 1 \
    --query 'Instances[0].InstanceId' --output text)
  echo "Instance launched: $INSTANCE_ID"
  echo "Waiting for instance to be running..."
  $AWS ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi

# 4. Elastic IP
EIP=$($AWS ec2 describe-addresses --filters "Name=tag:Name,Values=$BOT_NAME" \
  --query 'Addresses[0].PublicIp' --output text 2>/dev/null || echo "None")

if [ "$EIP" = "None" ] || [ -z "$EIP" ]; then
  echo "Allocating Elastic IP..."
  ALLOC_ID=$($AWS ec2 allocate-address --query 'AllocationId' --output text)
  $AWS ec2 create-tags --resources "$ALLOC_ID" --tags "Key=Name,Value=$BOT_NAME"
  $AWS ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID"
  EIP=$($AWS ec2 describe-addresses --allocation-ids "$ALLOC_ID" \
    --query 'Addresses[0].PublicIp' --output text)
  echo "Elastic IP: $EIP"
else
  echo "Elastic IP already exists: $EIP"
fi

# 5. SSH config
if ! grep -q "Host $BOT_NAME" ~/.ssh/config 2>/dev/null; then
  echo "" >> ~/.ssh/config
  echo "Host $BOT_NAME" >> ~/.ssh/config
  echo "    HostName $EIP" >> ~/.ssh/config
  echo "    User ubuntu" >> ~/.ssh/config
  echo "    IdentityFile ~/.ssh/${KEY_NAME}.pem" >> ~/.ssh/config
  echo "Added $BOT_NAME to ~/.ssh/config"
else
  echo "SSH config entry for $BOT_NAME already exists"
fi

echo ""
echo "=== Provisioning complete ==="
echo "Instance: $INSTANCE_ID"
echo "IP: $EIP"
echo "SSH: ssh $BOT_NAME"
echo ""
echo "Next: run 'ssh $BOT_NAME' then run setup.sh on the instance"
