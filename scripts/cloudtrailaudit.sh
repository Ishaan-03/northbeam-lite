#!/bin/bash
# NOTE: lookup-events retains only 90 days and captures management events only.
# S3 object-level (data) events require a paid CloudTrail data-event trail.
# Adjust the window deliberately — too narrow a window silently hides findings.

WINDOW="7 days ago"

echo "Scanning CloudTrail AssumeRole activity (last $WINDOW)..."
echo "---"

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --start-time "$(date -u -d "$WINDOW" +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'Events[].[EventTime,Username,EventName]' \
  --output table

echo "---"
echo "Hunting AccessDenied events..."

aws cloudtrail lookup-events \
  --start-time "$(date -u -d "$WINDOW" +%Y-%m-%dT%H:%M:%SZ)" \
  --output json | grep -B5 'AccessDenied'

echo "---"
echo "Scan complete."
