"""Resolve logical credential names from a DS Bot or shell environment."""

import os


PREFIX = "DSH_SECRET_"
SPAPI_CREDENTIALS = {
    "client_id": "SP_API_CLIENT_ID",
    "client_secret": "SP_API_CLIENT_SECRET",
    "refresh_token": "SP_API_REFRESH_TOKEN",
}
EBAY_CREDENTIALS = ("EBAY_CLIENT_ID", "EBAY_CLIENT_SECRET")
CREDENTIAL_NAMES = (*SPAPI_CREDENTIALS.values(), *EBAY_CREDENTIALS, "GATEWAY_TOKEN")


def resolve_with_source(name):
    prefixed = os.environ.get(PREFIX + name)
    if prefixed is not None:
        return prefixed, PREFIX
    bare = os.environ.get(name)
    return bare, "bare" if bare is not None else None


def resolve(name):
    value, _ = resolve_with_source(name)
    return value


def missing(resolved):
    return [name for name, value in resolved.items() if not value]


def sensitive_values(names):
    return {value for name in names for key in (name, PREFIX + name)
            if (value := os.environ.get(key))}
