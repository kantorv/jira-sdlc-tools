---
slug: /step-by-step-installation/jira-tokens
sidebar_position: 5
sidebar_label: Jira tokens
---

# Jira tokens

Each role needs a **classic Jira API token** with these permissions/scopes:

- `read:jira-user`
- `read:jira-work`
- `write:jira-work`

The tokens are **per-role** and are sent as per-request Basic authentication;
there is no login session to share. A token always belongs to the account that
created it, so create each one while signed in as that role's user.

See [Creating Jira tokens](../../../process/SECURITY.md#jira).

**Using a single account?** Skip *Account setup* and follow *Token setup* once,
signed in as yourself.

**Multiple (3) additional accounts** After [adding the users](jira-users.md), go to your mailbox. You should have
three invitation emails:

![Three Jira invitation emails in the inbox, one per role](../../../assets/jira-new-user-invitation-email.png)

Repeat the steps below for **each** of them.

## Account setup

1. Open the invitation email and click **Accept invite**.

2. You're redirected to the email verification screen.

   ![The Atlassian email verification screen asking for a code](../../../assets/jira-new-user-verification-email.png)

3. Go back to your mailbox, copy the verification code, and paste it into the
   verification field.

   ![The verification email containing the code](../../../assets/jira-new-user-verification-code.png)

4. Fill in the name and password in the post-setup form. Make the **full name
   match the role**, e.g. `Jira Task Executor`, so the board shows which role
   did what.

   ![The post-setup form with full name and password fields](../../../assets/jira-new-user-post-setup.png)

## Token setup

05. You might be redirected to an onboarding screen. It doesn't matter what you
    select there. Once you reach the boards list, open the token page:
    [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens).

06. You land on an email verification screen.

    ![The verification screen shown before managing API tokens](../../../assets/jira-token-verification-code.png)

07. Go to your mailbox and copy the code into the verification field. You then
    reach the **API tokens** screen.

    ![The verification email for API token access](../../../assets/jira-token-verification-code-email.png)

08. Click **Create API token with scopes**.

    ![The API tokens screen](../../../assets/jira-token-api-tokens-screen.png)

    ![Naming the new API token](../../../assets/jira-token-name-token.png)

09. On the app selection screen, select **Jira** only.

    ![The app selection screen with Jira selected](../../../assets/jira-token-select-app.png)

10. Set the scope type filter to **Classic**, then find and select each of the
    three permissions: `read:jira-user`, `read:jira-work` and `write:jira-work`.

    ![Selecting the read:jira-user scope](../../../assets/jira-token-permissions-user-read.png)

    ![Selecting the read:jira-work scope](../../../assets/jira-token-permissions-work-read.png)

    ![Selecting the write:jira-work scope](../../../assets/jira-token-permissions-work-write.png)

    With all three selected, the review screen looks like this. Click
    **Create token**.

    ![The review screen listing the three selected scopes](../../../assets/jira-token-permissions-review.png)

11. Copy the token and store it locally together with the user's email. Both go into
    `.jst/jira-sdlc-tools.local.env` (see
    [Fill `.jst/jira-sdlc-tools.local.env`](../software/fill-the-local-env.md)).
    Copy it now: Atlassian only shows it once.

    ![The created token with its copy button](../../../assets/jira-token-copy-token-screenshot.png)

12. Confirm the token was created:

    1. Go to
       [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens).

       ![The API tokens list showing the newly created token](../../../assets/jira-token-created-confirmation.png)

    2. Check that the token you just created is listed.

    3. Confirm it has all three required scopes: `read:jira-user`,
       `read:jira-work` and `write:jira-work`.

       ![The token's details listing its three scopes](../../../assets/jira-token-confirmation-scopes.png)
