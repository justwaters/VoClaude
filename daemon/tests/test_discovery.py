from types import SimpleNamespace

from voclaude import discovery


def adapter(name, *ips):
    return SimpleNamespace(name=name, nice_name=name, ips=[SimpleNamespace(ip=ip) for ip in ips])


def test_advertises_only_lan_addresses(monkeypatch):
    monkeypatch.setattr(discovery.ifaddr, "get_adapters", lambda: [
        adapter("lo0", "127.0.0.1"),
        adapter("en0", "10.240.12.120", ("fe80::1", 0, 0)),
        adapter("utun10", "100.115.55.24"),       # Tailscale
        adapter("en19", "169.254.16.75"),         # link-local
        adapter("en5", "100.100.1.2"),            # CGNAT on a real interface
        adapter("docker0", "172.17.0.1"),
        adapter("en1", "192.168.1.20"),
    ])
    assert discovery.local_ipv4_addresses() == ["10.240.12.120", "192.168.1.20"]
