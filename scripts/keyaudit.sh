#!/bin/bash
echo "Scanning for IAM access keys older than 90 days..."
echo "---"

for user in $(aws iam list-users --query 'Users[].UserName' --output text); do
  keys=$(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].[AccessKeyId,CreateDate,Status]' --output text)

  if [ -z "$keys" ]; then
    continue
  fi

  while IFS=$'\t' read -r key_id create_date status; do
    created_epoch=$(date -d "$create_date" +%s)
    now_epoch=$(date +%s)
    age_days=$(( (now_epoch - created_epoch) / 86400 ))

    echo "User: $user | Key: $key_id | Status: $status | Age: ${age_days} days"

    if [ "$age_days" -gt 90 ]; then
      echo "  FLAGGED: exceeds 90-day threshold"
    fi
  done <<< "$keys"
done

echo "---"
echo "Scan complete."
