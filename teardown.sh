#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/.deploy_state" 2>/dev/null || true
export AWS_DEFAULT_REGION="$REGION"

echo "🧹 Starting teardown..."

echo "🖥️ Terminating instances..."

INSTANCE_IDS=()

# Check bastion
if aws ec2 describe-instances --instance-ids "$BASTION_ID" >/dev/null 2>&1; then
    INSTANCE_IDS+=("$BASTION_ID")
else
    echo "⚠️ Bastion not found, skipping"
fi

# Check app server
if aws ec2 describe-instances --instance-ids "$APP_SERVER_ID" >/dev/null 2>&1; then
    INSTANCE_IDS+=("$APP_SERVER_ID")
else
    echo "⚠️ App server not found, skipping"
fi

# Terminate only if at least one exists
if [ ${#INSTANCE_IDS[@]} -gt 0 ]; then
    echo "🚀 Terminating: ${INSTANCE_IDS[*]}"
    
    aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" >/dev/null

    echo "⏳ Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"

    echo "✅ Instances terminated"
else
    echo "⚠️ No instances to terminate"
fi

# Delete VPC Endpoint
echo "deleting VPC endpoint: $S3_ENDPOINT_ID"
[ -n "${S3_ENDPOINT_ID:-}" ] && \
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$S3_ENDPOINT_ID" || true
echo "✅ VPC endpoint deleted"

# Delete NAT gateway
echo "Deleting NAT gateway: $NAT_ID"
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"

echo "Waiting for NAT to be deleted..."

while true; do
    STATE=$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$NAT_ID" \
      --query 'NatGateways[0].State' \
      --output text 2>/dev/null || echo "deleted")
    [ "$STATE" = "deleted" ] && break
    echo "NAT state: $STATE — waiting..."
    sleep 10
done

# Releasing elastic IP
echo "Releasing elastic IP"
aws ec2 release-address --allocation-id "$ALLOCATION_ID"

# Delete Security Groups 
echo "🔒 Deleting app server security group: $APP_SERVER_SG_ID"
aws ec2 delete-security-group --group-id "$APP_SERVER_SG_ID" 2>/dev/null || true

echo "🔒 Deleting bastion security group: $BASTION_SG_ID"
aws ec2 delete-security-group --group-id "$BASTION_SG_ID" 2>/dev/null || true

# Delete private route table
echo "Deleting private route table: $PRIVATE_ROUTE_TABLE_ID"
aws ec2 disassociate-route-table --association-id "$PRIVATE_ROUTE_TABLE_ASSOCIAATION_Id" 2>/dev/null || true
aws ec2 delete-route-table --route-table-id "$PRIVATE_ROUTE_TABLE_ID"

# Delete public route table
echo "Deleting public route table: $PUBLIC_ROUTE_TABLE_ID"
aws ec2 disassociate-route-table --association-id "$PUBLIC_ROUTE_TABLE_ASSOCIAATION_Id" 2>/dev/null || true
aws ec2 delete-route-table --route-table-id "$PUBLIC_ROUTE_TABLE_ID"

# Detach and delete Internet Gateway
echo "Detach and delete Internet Gateway: $IGW_ID"
aws ec2 detach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID"

aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
 
# Delete subnets
echo "Deleting public subnet: $PUBLIC_SUBNET_ID"
aws ec2 delete-subnet --subnet-id "$PUBLIC_SUBNET_ID"

echo "Deleting private subnet: $PRIVATE_SUBNET_ID"
aws ec2 delete-subnet --subnet-id "$PRIVATE_SUBNET_ID"

# Delete VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID"

# Detach all Managed Policies (ARNs)
echo "Detaching all Managed Policies (ARNs)"
for policy_arn in $(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text); do
    echo "Detaching policy: $policy_arn"
    aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$policy_arn"
done

# Delete all Inline Policies
echo "Deleting all Inline Policies"
for policy_name in $(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" --query 'PolicyNames[*]' --output text); do
    echo "Deleting policy: $policy_name"
    aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "$policy_name"
done

# Remove role from instance profile
echo "Removing role $IAM_ROLE_NAME from instance profile $IAM_PROFILE_NAME"
aws iam remove-role-from-instance-profile --instance-profile-name "$IAM_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" 2>/dev/null || true

# Delete instance profile
echo "Delete instance profile: $IAM_PROFILE_NAME"
aws iam delete-instance-profile --instance-profile-name "$IAM_PROFILE_NAME"

# Delete role
echo "Deleting role: $IAM_ROLE_NAME"
aws iam delete-role --role-name "$IAM_ROLE_NAME"

# Deleting key pair from aws
echo "Deleting key pair: $KEY_NAME"
aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true

# Remove state file
rm -f "$SCRIPT_DIR/.deploy_state"
echo "🗑️ Cleanup completed successfully!"
