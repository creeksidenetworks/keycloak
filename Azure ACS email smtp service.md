# Guide: Enable Azure Communication Services (ACS) to Send `donotreply` SMTP Emails

This guide walks through how to configure **Azure Communication Services – Email** so you can send emails from a `donotreply@yourdomain.com` address using **SMTP**.

> **Scope**
> - Azure Communication Services (ACS) – Email
> - Custom domain sender (`donotreply@…`)
> - SMTP relay (username/password)
> - Suitable for applications, appliances, or services that only support SMTP

---

## 1. Prerequisites

Before you begin, ensure you have:

- An **Azure subscription** with permission to create resources
- A **custom domain** you control (e.g. `example.com`)
- Access to manage **DNS records** for the domain
- An Azure AD account with **Contributor** or higher

---

## 2. Create an Azure Communication Services Resource

1. Sign in to the **Azure Portal**
2. Navigate to **Create a resource** → **Communication Services**
3. Select **Azure Communication Services**
4. Fill in the required fields:
   - **Subscription**: your subscription
   - **Resource Group**: create or select one
   - **Resource Name**: e.g. `acs-email-prod`
   - **Data location**: choose the closest region
5. Click **Review + Create** → **Create**

Once deployed, open the ACS resource.

---

## 3. Enable Email in Azure Communication Services

1. In the ACS resource, go to **Email** (left menu)
2. Click **Get started** if Email is not yet enabled
3. Confirm the Email service is **Active**

---

## 4. Add and Verify a Custom Sending Domain

To send email from `donotreply@yourdomain.com`, the domain must be verified.

### 4.1 Add Domain

1. In **ACS → Email → Domains**
2. Click **Add domain**
3. Enter your domain (e.g. `example.com`)
4. Choose **Custom domain**

### 4.2 Configure DNS Records

Azure will provide several DNS records. Add **all** of them to your DNS provider:

| Record Type | Purpose |
|-----------|--------|
| TXT | Domain ownership verification |
| TXT (SPF) | Sender Policy Framework |
| CNAME | DKIM signing |
| CNAME | Mail routing |

> ⚠️ DNS propagation may take several minutes to hours.

### 4.3 Verify Domain

- Return to Azure Portal
- Click **Verify** next to the domain
- Status should change to **Verified**

---

## 5. Create a DoNotReply Email Address

Once the domain is verified:

- Any address under the domain becomes valid
- Example sender:
  ```
  donotreply@example.com
  ```

No mailbox creation is required—ACS handles delivery.

---

## 6. Enable SMTP Authentication

Azure Communication Services provides an SMTP endpoint.

### 6.1 Locate SMTP Settings

1. Go to **ACS → Email → SMTP settings**
2. Note the following:
   - **SMTP server** (e.g. `smtp.azurecomm.net`)
   - **Port**: `587`
   - **Encryption**: STARTTLS

### 6.2 Generate SMTP Credentials

1. In **SMTP settings**, click **Create credentials**
2. Assign a name (e.g. `donotreply-smtp`)
3. Copy and securely store:
   - **Username**
   - **Password** (shown once)

---

## 7. Configure Your Application or Service

Use the following SMTP configuration:

| Setting | Value |
|------|------|
| SMTP Server | Provided by ACS |
| Port | 587 |
| Encryption | STARTTLS |
| Username | ACS SMTP username |
| Password | ACS SMTP password |
| From Address | `donotreply@example.com` |

### Example (Generic SMTP)

```
From: donotreply@example.com
SMTP Host: smtp.azurecomm.net
Port: 587
TLS: Enabled
Authentication: Yes
```

---

## 8. Test Email Delivery

1. Send a test email to an external address (e.g. Gmail)
2. Verify:
   - Email is delivered
   - Sender address shows `donotreply@yourdomain.com`
   - SPF/DKIM pass (check email headers)

---

## 9. Best Practices for DoNotReply Addresses

- Do not accept inbound replies (no mailbox required)
- Add a footer such as:
  > "This is an automated message. Please do not reply."
- Configure **SPF, DKIM, and DMARC** for best deliverability
- Monitor email metrics in **ACS → Email → Metrics**

---

## 10. Security & Limits

- Rotate SMTP credentials periodically
- Restrict access to credentials
- Be aware of ACS sending limits and throttling
- Avoid sending spam or bulk unsolicited emails

---

## 11. Troubleshooting

| Issue | Resolution |
|-----|-----------|
| Emails not delivered | Check DNS verification status |
| SPF/DKIM fail | Ensure records are correct and propagated |
| Authentication error | Regenerate SMTP credentials |
| From address rejected | Ensure domain is verified |

---

## 12. Summary

You have successfully:

- Created an Azure Communication Services resource
- Enabled Email service
- Verified a custom domain
- Configured SMTP authentication
- Sent emails from `donotreply@yourdomain.com`

This setup is ideal for applications, Open OnDemand portals, FreeIPA notifications, monitoring systems, and other infrastructure services that require SMTP-only email delivery.

---

**Optional Next Steps**
- Configure DMARC reporting
- Integrate with Azure Monitor alerts
- Use ACS Email APIs for advanced workflows

