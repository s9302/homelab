# usage: env NAME SLUG REDIRECT(regex|strict:url) LAUNCH ; writes secret to /tmp/<slug>-secret
import os, secrets
from authentik.core.models import Application
from authentik.crypto.models import CertificateKeyPair
from authentik.flows.models import Flow
from authentik.providers.oauth2.models import OAuth2Provider, RedirectURI, RedirectURIMatchingMode, ScopeMapping
name, slug, redir, launch = os.environ["P_NAME"], os.environ["P_SLUG"], os.environ["P_REDIR"], os.environ["P_LAUNCH"]
p, created = OAuth2Provider.objects.get_or_create(name=name, defaults=dict(
    authorization_flow=Flow.objects.get(slug="default-provider-authorization-implicit-consent"),
    invalidation_flow=Flow.objects.get(slug="default-provider-invalidation-flow"),
    client_type="confidential", client_id=slug, client_secret=secrets.token_urlsafe(48),
    signing_key=CertificateKeyPair.objects.get(name="authentik Self-signed Certificate"),
    sub_mode="user_username", access_code_validity="minutes=1", access_token_validity="minutes=10"))
p.grant_types = ["authorization_code", "refresh_token"]
mode, url = redir.split(":", 1)
p.redirect_uris = [RedirectURI(RedirectURIMatchingMode.REGEX if mode == "regex" else RedirectURIMatchingMode.STRICT, url)]
p.property_mappings.set(ScopeMapping.objects.filter(managed__in=[
    "goauthentik.io/providers/oauth2/scope-openid", "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile", "goauthentik.io/providers/oauth2/scope-offline_access"]))
p.save()
Application.objects.get_or_create(slug=slug, defaults=dict(name=name, provider=p, meta_launch_url=launch))
open(f"/tmp/{slug}-secret", "w").write(p.client_secret)
print("provider", slug, "created" if created else "existed", p.grant_types)
