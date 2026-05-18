"""
Cognito Pre Sign-up Lambda trigger.

Auto-confirms self-service sign-ups so that newly registered users skip the
email-verification step and can sign in immediately. Custom attribute
mapping (display name, group, etc.) should be done in the User Pool schema
(Cognito → User pool → Branding designer), not by this Lambda, since
custom attributes are otherwise silently dropped by Cognito's Hosted
UI signup flow.

Runs only on self-service sign-up (Hosted UI / SignUp API).
Admin-created users go through Pre Authentication / Post Confirmation triggers.
"""


def handler(event, context):
    event["response"]["autoConfirmUser"] = True
    event["response"]["autoVerifyEmail"] = True
    return event
