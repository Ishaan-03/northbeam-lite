#!/bin/bash
echo "Scanning IAM roles for last-used activity..."
echo "---"

for role in $(aws iam list-roles --query 'Roles[].RoleName' --output text); do
  last_used=$(aws iam get-role --role-name "$role" --query 'Role.RoleLastUsed.LastUsedDate' --output text)

  if [ "$last_used" == "None" ]; then
    echo "Role: $role | Last used: NEVER"
  else
    echo "Role: $role | Last used: $last_used"
  fi
done

echo "---"
echo "Scan complete."
