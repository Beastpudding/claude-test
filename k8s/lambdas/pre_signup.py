"""
Cognito Pre Sign-up Lambda trigger.

Allow-list filter: only emails ending in @kbfg.com (KB 국민은행) can register.
Self-service signups with any other domain are rejected at signup time —
the user sees the raised exception message in Cognito's Hosted UI.

Email verification is intentionally NOT auto-confirmed: Cognito sends a 6-digit
OTP to the submitted email and the user must enter it before they can sign in.
This proves they actually control that @kbfg.com mailbox.

Runs only on self-service sign-up (Hosted UI / SignUp API).
Admin-created users (AdminCreateUser API) skip this trigger entirely.
"""

ALLOWED_DOMAIN = "@kbfg.com"


def lambda_handler(event, context):
    email = (event.get("request", {})
                  .get("userAttributes", {})
                  .get("email", "")
                  .strip()
                  .lower())

    if not email.endswith(ALLOWED_DOMAIN):
        # The message after "PreSignUp failed with error " is shown to the user
        # in Cognito Hosted UI. Keep it short and clear.
        raise Exception(f"KBFG 직원 이메일({ALLOWED_DOMAIN})만 가입 가능합니다.")

    # Do NOT auto-confirm: force the user to verify their email via the OTP
    # that Cognito sends on signup. Cognito's User Pool already has
    # AutoVerifiedAttributes=[email] from setup, so the OTP is sent automatically.
    return event
