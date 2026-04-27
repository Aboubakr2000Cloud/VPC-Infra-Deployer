#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/.deploy_state" 2>/dev/null || true
export AWS_DEFAULT_REGION="$REGION"

run_part_a() {

  echo "Deploying infrastructure..."

  # Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --query 'Vpc.VpcId' \
  --output text \
  --tag-specifications "ResourceType=vpc,Tags=[
    {Key=Name,Value=week12-vpc},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

# Enable DNS hostnames and support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support

# Create IGW
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --tag-specifications "ResourceType=internet-gateway,Tags=[
    {Key=Name,Value=week12-igw},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

# Create public subnet
PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week12-public-subnet},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]") 

# Create private subnet
PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week12-private-subnet},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

# Enable auto-assign public IP on subnet
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --map-public-ip-on-launch

# Attach to VPC
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

# Create public route table
PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=week12-public-rt},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

# Create private route table
PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=week12-private-rt},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

# Add 0.0.0.0/0 route to IGW
aws ec2 create-route \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID"

# Associate public route table with public subnet
PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query 'AssociationId' \
  --output text)

# Associate private route table with private subnet
PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --query 'AssociationId' \
  --output text)

# Allocate an Elastic IP for the NAT Gateway
ALLOCATION_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)

# Tag elastic IP
aws ec2 create-tags \
  --resources "$ALLOCATION_ID" \
  --tags Key=Name,Value=week12-eip \
         Key=Project,Value=$PROJECT_TAG \
         Key=Week,Value=$WEEK_TAG

# Create NAT Gateway
NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --allocation-id "$ALLOCATION_ID" \
  --query 'NatGateway.NatGatewayId' \
  --output text \
  --tag-specifications "ResourceType=natgateway,Tags=[
    {Key=Name,Value=week12-nat},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]") 

# Wait for the NAT Gateway to be available
while true; do
    STATE=$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$NAT_ID" \
      --query 'NatGateways[0].State' \
      --output text)
    [ "$STATE" = "available" ] && break
    echo "NAT state: $STATE — waiting..."
    sleep 10
done

# Add 0.0.0.0/0 route to NAT
aws ec2 create-route \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_ID"

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_ID="$PUBLIC_SUBNET_ID"
PRIVATE_SUBNET_ID="$PRIVATE_SUBNET_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id="$PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id"
PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id="$PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
EOF
}

if [ -f "$SCRIPT_DIR/.deploy_state" ]; then
  echo "Infrastructure already exists. Loading state..."
else
  run_part_a
fi

source "$SCRIPT_DIR/.deploy_state"

run_part_b() {

  MY_IP=$(curl -s checkip.amazonaws.com)

  BASTION_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$BASTION_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

  if [ "$BASTION_SG_ID" = "None" ]; then
     echo "Creating Bastion SG..."
  
     BASTION_SG_ID=$(aws ec2 create-security-group \
     --vpc-id "$VPC_ID" \
     --group-name "$BASTION_SG_NAME" \
     --description "Week 12 Bastion SG" \
     --query 'GroupId' \
     --output text)

     aws ec2 create-tags \
       --resources "$BASTION_SG_ID" \
       --tags Key=Name,Value=week12-bastion-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG"

     aws ec2 authorize-security-group-ingress \
       --group-id "$BASTION_SG_ID" \
       --protocol tcp --port 22 --cidr "$MY_IP/32"
  fi
  
  APP_SERVER_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$APP_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

  if [ "$APP_SERVER_SG_ID" = "None" ]; then
    echo "Creating App server SG..."

    APP_SERVER_SG_ID=$(aws ec2 create-security-group \
      --vpc-id "$VPC_ID" \
      --group-name "$APP_SG_NAME" \
      --description "Week 12 App SG" \
      --query 'GroupId' \
      --output text)

    aws ec2 create-tags \
      --resources "$APP_SERVER_SG_ID" \
      --tags Key=Name,Value=week12-app-server-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG"

    aws ec2 authorize-security-group-ingress \
      --group-id "$APP_SERVER_SG_ID" \
      --protocol tcp --port 22 --source-group "$BASTION_SG_ID"

    aws ec2 authorize-security-group-ingress \
      --group-id "$APP_SERVER_SG_ID" \
      --protocol tcp --port 80 --source-group "$BASTION_SG_ID"

  fi

  if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
      aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "$SCRIPT_DIR/$KEY_NAME.pem"
      chmod 400 "$SCRIPT_DIR/$KEY_NAME.pem"
  fi

  echo "Creating IAM role..."

  aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || \
  aws iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document file://"$SCRIPT_DIR/iam/ec2-trust-policy.json"

  aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess']" \
    --output text | grep -q AmazonS3ReadOnlyAccess || \
  aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

  aws iam create-instance-profile \
    --instance-profile-name "$IAM_PROFILE_NAME" 2>/dev/null || true

  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IAM_PROFILE_NAME" \
    --role-name "$IAM_ROLE_NAME" 2>/dev/null || true

cat > "$SCRIPT_DIR/.deploy_state" <<EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_ID="$PUBLIC_SUBNET_ID"
PRIVATE_SUBNET_ID="$PRIVATE_SUBNET_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id="$PUBLIC_ROUTE_TABLE_ASSOCIATION_Id"
PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id="$PRIVATE_ROUTE_TABLE_ASSOCIATION_Id"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"

# ---- Part B ----
BASTION_SG_ID="$BASTION_SG_ID"
APP_SERVER_SG_ID="$APP_SERVER_SG_ID"

PART_B_DONE=true
EOF

  sleep 15
}

if [ "${PART_B_DONE:-false}" = "true" ]; then
  echo "Security Groups & IAM already done"
else
  run_part_b
fi

run_part_c() {

echo "Launch the Instances"

# Bastion
BASTION_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --security-group-ids "$BASTION_SG_ID" \
  --key-name "$KEY_NAME" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=week12-bastion},{Key=Project,Value=$PROJECT_TAG},{Key=Week,Value=$WEEK_TAG}]")

echo "✅ Bastion launched: $BASTION_ID"

# App server
APP_SERVER_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$PRIVATE_SUBNET_ID" \
  --security-group-ids "$APP_SERVER_SG_ID" \
  --key-name "$KEY_NAME" \
  --iam-instance-profile Name="$IAM_PROFILE_NAME" \
  --user-data file://"$SCRIPT_DIR/userdata.sh" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=week12-app-server},{Key=Project,Value=$PROJECT_TAG},{Key=Week,Value=$WEEK_TAG}]")

echo "✅ App server launched: $APP_SERVER_ID"


echo "Waiting for Bastion..."
aws ec2 wait instance-status-ok --instance-ids "$BASTION_ID"

echo "Waiting for App server..."
aws ec2 wait instance-running --instance-ids "$APP_SERVER_ID"


BASTION_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$BASTION_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

APP_SERVER_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids "$APP_SERVER_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo "Bastion IP: $BASTION_PUBLIC_IP"
echo "App private IP: $APP_SERVER_PRIVATE_IP"

echo "ssh-add abou.pem"
echo "ssh -A ubuntu@$BASTION_PUBLIC_IP"
echo "ssh ubuntu@$APP_SERVER_PRIVATE_IP"

cat > "$SCRIPT_DIR/.deploy_state" <<EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_ID="$PUBLIC_SUBNET_ID"
PRIVATE_SUBNET_ID="$PRIVATE_SUBNET_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id="$PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id"
PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id="$PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"

# ---- Part B ----
BASTION_SG_ID="$BASTION_SG_ID"
APP_SERVER_SG_ID="$APP_SERVER_SG_ID"

# ---- Part C ----
BASTION_ID="$BASTION_ID"
APP_SERVER_ID="$APP_SERVER_ID"

PART_B_DONE=true
PART_C_DONE=true
EOF
}

if [ "${PART_C_DONE:-false}" = "true" ]; then
  echo "Bastion and App server already launched"
else
  run_part_c
fi

run_part_d() {
  
S3_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=service-name,Values=com.amazonaws.$REGION.s3" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text)

if [ -z "$S3_ENDPOINT_ID" ] || [ "$S3_ENDPOINT_ID" = "None" ]; then
    echo "Creating S3 Gateway Endpoint..."

    S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
      --vpc-id "$VPC_ID" \
      --service-name "com.amazonaws.$REGION.s3" \
      --route-table-ids "$PRIVATE_ROUTE_TABLE_ID" \
      --vpc-endpoint-type Gateway \
      --query 'VpcEndpoint.VpcEndpointId' \
      --output text)
fi

echo "S3 Endpoint: $S3_ENDPOINT_ID"

cat > "$SCRIPT_DIR/.deploy_state" <<EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_ID="$PUBLIC_SUBNET_ID"
PRIVATE_SUBNET_ID="$PRIVATE_SUBNET_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id="$PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id"
PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id="$PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"

# ---- Part B ----
BASTION_SG_ID="$BASTION_SG_ID"
APP_SERVER_SG_ID="$APP_SERVER_SG_ID"

# ---- Part C ----
BASTION_ID="$BASTION_ID"
APP_SERVER_ID="$APP_SERVER_ID"

# ---- Part D ----
S3_ENDPOINT_ID="$S3_ENDPOINT_ID"

PART_B_DONE=true
PART_C_DONE=true
PART_D_DONE=true
EOF
}

if [ "${PART_D_DONE:-false}" = "true" ]; then
  echo "S3 Endpoint already exists"
else
  run_part_d
fi
