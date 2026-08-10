"""HTML templates for transactional email."""

from __future__ import annotations

import base64
from pathlib import Path

from django.conf import settings

_LOGO_FILE = Path(__file__).resolve().parent.parent / "email_assets" / "logo.png"

# Matches Flutter AppTheme.brandGreen
BRAND_GREEN = "#177245"
BRAND_GREEN_DARK = "#0F4D2E"
BRAND_GREEN_LIGHT = "#2A9B63"


def verification_email_html(*, greeting: str, verify_url: str) -> str:
    safe_name = _escape_html(greeting)
    logo_src = _logo_src()
    logo_block = (
        f'<img src="{logo_src}" alt="U-Panel" width="72" height="72" '
        'style="display:block;margin:0 auto 12px;border-radius:16px;" />'
        if logo_src
        else (
            '<div style="width:72px;height:72px;margin:0 auto 12px;border-radius:16px;'
            f'background:{BRAND_GREEN};color:#fff;font-size:28px;line-height:72px;text-align:center;">'
            "U</div>"
        )
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Verify your U-Panel account</title>
</head>
<body style="margin:0;padding:0;background:#eef2f6;font-family:Segoe UI,Arial,sans-serif;color:#0a2915;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#eef2f6;padding:32px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 8px 28px rgba(15,77,46,.12);">
          <tr>
            <td style="background:linear-gradient(135deg,{BRAND_GREEN} 0%,{BRAND_GREEN_DARK} 100%);padding:28px 24px 24px;text-align:center;">
              {logo_block}
              <div style="font-size:12px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:rgba(255,255,255,.88);">
                KIU-QA Department
              </div>
              <div style="font-size:22px;font-weight:700;color:#ffffff;margin-top:6px;line-height:1.3;">
                Verify your U-Panel account
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 28px 8px;">
              <p style="margin:0 0 14px;font-size:16px;line-height:1.6;color:#0a2915;">
                Dear {safe_name},
              </p>
              <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#334155;">
                Welcome to <strong style="color:{BRAND_GREEN};">U-Panel</strong> — KIU&apos;s attendance and campus app.
                Confirm your school email to finish setting up your account.
              </p>
              <table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto 22px;">
                <tr>
                  <td style="border-radius:10px;background:{BRAND_GREEN};">
                    <a href="{verify_url}" target="_blank" rel="noopener"
                       style="display:inline-block;padding:14px 32px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;">
                      Verify email address
                    </a>
                  </td>
                </tr>
              </table>
              <p style="margin:0 0 8px;font-size:13px;line-height:1.55;color:#64748b;">
                Or copy this link into your browser:
              </p>
              <p style="margin:0 0 18px;font-size:12px;line-height:1.5;word-break:break-all;">
                <a href="{verify_url}" style="color:{BRAND_GREEN};">{verify_url}</a>
              </p>
              <p style="margin:0;font-size:13px;line-height:1.55;color:#64748b;">
                This link expires in <strong>48 hours</strong>. If you did not sign up, you can ignore this message.
              </p>
            </td>
          </tr>
          <tr>
            <td style="padding:18px 28px 24px;border-top:1px solid #e2e8f0;background:#f8fafc;">
              <p style="margin:0 0 6px;font-size:12px;line-height:1.5;color:#64748b;">
                Sent by <strong style="color:{BRAND_GREEN_DARK};">KIU-QA Department</strong> · U-Panel
              </p>
              <p style="margin:0;font-size:11px;line-height:1.5;color:#94a3b8;">
                If this email is in spam, mark it as <em>Not spam</em> so future messages reach your inbox.
              </p>
            </td>
          </tr>
        </table>
        <p style="margin:16px 0 0;font-size:11px;color:#94a3b8;line-height:1.4;max-width:520px;">
          Kampala International University · Quality Assurance
        </p>
      </td>
    </tr>
  </table>
</body>
</html>"""


def password_reset_email_html(*, greeting: str, reset_url: str) -> str:
    safe_name = _escape_html(greeting)
    logo_src = _logo_src()
    logo_block = (
        f'<img src="{logo_src}" alt="U-Panel" width="72" height="72" '
        'style="display:block;margin:0 auto 12px;border-radius:16px;" />'
        if logo_src
        else (
            '<div style="width:72px;height:72px;margin:0 auto 12px;border-radius:16px;'
            f'background:{BRAND_GREEN};color:#fff;font-size:28px;line-height:72px;text-align:center;">'
            "U</div>"
        )
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Reset your U-Panel password</title>
</head>
<body style="margin:0;padding:0;background:#eef2f6;font-family:Segoe UI,Arial,sans-serif;color:#0a2915;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#eef2f6;padding:32px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:520px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 8px 28px rgba(15,77,46,.12);">
          <tr>
            <td style="background:linear-gradient(135deg,{BRAND_GREEN} 0%,{BRAND_GREEN_DARK} 100%);padding:28px 24px 24px;text-align:center;">
              {logo_block}
              <div style="font-size:12px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:rgba(255,255,255,.88);">
                KIU-QA Department
              </div>
              <div style="font-size:22px;font-weight:700;color:#ffffff;margin-top:6px;line-height:1.3;">
                Reset your password
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 28px 8px;">
              <p style="margin:0 0 14px;font-size:16px;line-height:1.6;color:#0a2915;">
                Dear {safe_name},
              </p>
              <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#334155;">
                We received a request to reset your <strong style="color:{BRAND_GREEN};">U-Panel</strong> password.
                Tap the button below to choose a new password.
              </p>
              <table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto 22px;">
                <tr>
                  <td style="border-radius:10px;background:{BRAND_GREEN};">
                    <a href="{reset_url}" target="_blank" rel="noopener"
                       style="display:inline-block;padding:14px 32px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;">
                      Reset password
                    </a>
                  </td>
                </tr>
              </table>
              <p style="margin:0 0 8px;font-size:13px;line-height:1.55;color:#64748b;">
                Or copy this link into your browser:
              </p>
              <p style="margin:0 0 18px;font-size:12px;line-height:1.5;word-break:break-all;">
                <a href="{reset_url}" style="color:{BRAND_GREEN};">{reset_url}</a>
              </p>
              <p style="margin:0;font-size:13px;line-height:1.55;color:#64748b;">
                This link expires in <strong>2 hours</strong>. If you did not request this, you can ignore this message.
              </p>
            </td>
          </tr>
          <tr>
            <td style="padding:18px 28px 24px;border-top:1px solid #e2e8f0;background:#f8fafc;">
              <p style="margin:0 0 6px;font-size:12px;line-height:1.5;color:#64748b;">
                Sent by <strong style="color:{BRAND_GREEN_DARK};">KIU-QA Department</strong> · U-Panel
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>"""


def _logo_src() -> str:
    override = getattr(settings, "EMAIL_LOGO_URL", "").strip()
    if override:
        return _escape_html(override)
    if not _LOGO_FILE.is_file():
        return ""
    encoded = base64.b64encode(_LOGO_FILE.read_bytes()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def _escape_html(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
