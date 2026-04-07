# Slack Notifications

## Cluster Expiration Notifications

When a cluster expires and is destroyed by the automated cleanup job, a Slack notification is sent.
The notification @mentions the user who created the cluster, so they are aware their cluster has been cleaned up.

For the @mention to work, your GitHub username must be mapped to your Slack member ID in the `slack-users.json` file at the repository root.
If no mapping is found, the notification will include your GitHub username as plain text instead.

## How to Add Your Slack Member ID

1. Open Slack (desktop or web).
2. Click your **profile picture** in the top-right corner.
3. Click **"Profile"**.
4. Click the **three dots (...)** menu button.
5. Select **"Copy member ID"**.
6. Edit `slack-users.json` in the repository root and add your GitHub username and Slack member ID:

```json
{
  "jsenko": "U01AB2CDE",
  "your-github-username": "YOUR_SLACK_MEMBER_ID"
}
```

7. Commit and push the change.
