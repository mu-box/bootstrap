#!/bin/bash

MD5=$(which md5 || which md5sum)

util_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname $util_dir)"

hosts=(ubuntu ci)

# ensure the build dir exists
mkdir -p $project_dir/.build

for host in "${hosts[@]}"; do
  echo "Copying $host script..."
  cp $project_dir/$host.sh $project_dir/.build/

  echo "Generating md5 for $host ..."
  cat $project_dir/$host.sh | ${MD5} | awk '{print $1}' > $project_dir/.build/$host.md5
done

echo "Uploading builds to s3..."
aws s3 sync \
  $project_dir/.build/ \
  s3://tools.microbox.cloud/bootstrap \
  --grants read=uri=http://acs.amazonaws.com/groups/global/AllUsers \
  --region us-east-1

# echo "Creating invalidation for cloudfront"
# aws  configure  set preview.cloudfront true
# aws cloudfront create-invalidation \
#   --distribution-id E1O0D0A2DTYRY8 \
#   --paths /bootstrap

echo "Cleaning..."
rm -rf $project_dir/.build
