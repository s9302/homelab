# usage: env P_NAME P_SLUG P_HOST ; forward-auth (single application) provider on the embedded outpost,
# access limited to group "authentik Admins". Homelab 2026-11-15.
import os
from authentik.core.models import Application, Group
from authentik.flows.models import Flow
from authentik.outposts.models import Outpost
from authentik.policies.models import PolicyBinding
from authentik.providers.proxy.models import ProxyMode, ProxyProvider
name, slug, host = os.environ["P_NAME"], os.environ["P_SLUG"], os.environ["P_HOST"]
p, created = ProxyProvider.objects.get_or_create(name=name, defaults=dict(
    authorization_flow=Flow.objects.get(slug="default-provider-authorization-implicit-consent"),
    invalidation_flow=Flow.objects.get(slug="default-provider-invalidation-flow"),
    external_host=host, mode=ProxyMode.FORWARD_SINGLE, access_token_validity="hours=12"))
p.external_host = host; p.mode = ProxyMode.FORWARD_SINGLE; p.save()
app, _ = Application.objects.get_or_create(slug=slug, defaults=dict(name=name, provider=p, meta_launch_url=host))
admins = Group.objects.get(name="authentik Admins")
PolicyBinding.objects.get_or_create(target=app, group=admins, defaults=dict(order=0))
o = Outpost.objects.get(managed="goauthentik.io/outposts/embedded")
o.providers.add(p); o.save()
print("proxy", slug, "created" if created else "existed", p.mode, p.external_host, "bindings", PolicyBinding.objects.filter(target=app).count())
