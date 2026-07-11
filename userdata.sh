#!/bin/bash
set -euo pipefail

# Log everything
exec > /var/log/userdata_1.log 2>&1

echo "=== USER DATA START $(date) ==="

# Update packages
DEBIAN_FRONTEND=noninteractive apt-get update -y

# Install nginx
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp
/tmp/aws/install || true
rm -rf /tmp/awscliv2.zip /tmp/aws

aws --version > /var/log/aws_version.txt 2>&1 || true

mkdir -p /var/www/html

# Create HTML page
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
  <head>
    <title>VPC</title>
  </head>
  <body>
    <h1>Abou</h1>
    <p>VPC</p>
    <p>Private Subnet App Server</p>
    <p>Deployed at: $(date)</p>
  </body>
</html>
EOF

# Start nginx
systemctl start nginx
systemctl enable nginx

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

APP_SERVER_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

APP_SERVER_PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

aws s3 ls > /var/log/s3_test.txt 2>&1 || true

cat > /var/log/deploy_info.txt <<EOF
Timestamp = $(date +%F_%H-%M-%S)
APP_SERVER_ID = $APP_SERVER_ID
APP_SERVER_PRIVATE_IP = $APP_SERVER_PRIVATE_IP
EOF

echo "=== USER DATA END $(date) ==="
