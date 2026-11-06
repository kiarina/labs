"""Rewrites IP addresses in results/*.json into address classes, so the
public results carry no address of the machine they ran on. Private IPv4
addresses are kept (they show which interface a link used); public IPv4,
home directories in stack traces become ~;
CGNAT (100.64.0.0/10, e.g. Tailscale) and IPv6 addresses become a class.
    python3 scripts/redact.py results/*.json
"""
import ipaddress, json, re, sys

def klass(a: str) -> str:
    try:
        ip = ipaddress.ip_address(a)
    except ValueError:
        return a
    if ip.version == 4:
        if ip in ipaddress.ip_network("100.64.0.0/10"):
            return "ipv4-cgnat"
        return a if ip.is_private else "ipv4-public"
    if ip in ipaddress.ip_network("fc00::/7"):
        return "ipv6-ula"
    if ip.is_link_local:
        return "ipv6-link-local"
    return "ipv6-global" if ip.is_global else "ipv6-other"

addr = re.compile(r"(?<![\w.:])(\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,7})(?![\w.:])")

home = re.compile(r"/(?:Users|home)/[^/\s]+")

def fix(v):
    if isinstance(v, str):
        return home.sub("~", addr.sub(lambda m: klass(m.group(1)), v))
    if isinstance(v, list):
        return [fix(x) for x in v]
    if isinstance(v, dict):
        return {k: fix(x) for k, x in v.items()}
    return v

for f in sys.argv[1:]:
    d = json.load(open(f))
    json.dump(fix(d), open(f, "w"), indent=2, ensure_ascii=False)
