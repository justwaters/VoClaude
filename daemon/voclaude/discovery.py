"""Advertise the daemon on the local network over Bonjour / mDNS as `_voclaude._tcp`."""

from __future__ import annotations

import ipaddress
import logging
import socket

import ifaddr
from zeroconf import IPVersion
from zeroconf.asyncio import AsyncServiceInfo, AsyncZeroconf

from . import __version__
from .config import slugify

log = logging.getLogger("voclaude.discovery")

SERVICE_TYPE = "_voclaude._tcp.local."


def local_ipv4_addresses() -> list[str]:
    """Non-loopback IPv4 addresses, LAN addresses first."""
    found: list[ipaddress.IPv4Address] = []
    for adapter in ifaddr.get_adapters():
        for ip in adapter.ips:
            if isinstance(ip.ip, str):
                addr = ipaddress.IPv4Address(ip.ip)
                if not (addr.is_loopback or addr.is_link_local) and addr not in found:
                    found.append(addr)
    # Private LAN ranges before CGNAT/Tailscale (100.64/10) and anything public.
    found.sort(key=lambda a: (not a.is_private, str(a)))
    return [str(a) for a in found]


class Advertiser:
    def __init__(self, port: int, name: str | None = None):
        self.port = port
        self.hostname = (name or socket.gethostname()).split(".")[0]
        self._zc: AsyncZeroconf | None = None
        self._info: AsyncServiceInfo | None = None

    async def start(self) -> None:
        ips = local_ipv4_addresses()
        if not ips:
            log.warning("No network addresses found; not advertising on Bonjour")
            return
        server = f"voclaude-{slugify(self.hostname)}.local."
        self._info = AsyncServiceInfo(
            SERVICE_TYPE,
            f"VoClaude on {self.hostname}.{SERVICE_TYPE}",
            addresses=[socket.inet_aton(ip) for ip in ips],
            port=self.port,
            server=server,
            properties={
                "version": __version__,
                "host": server.rstrip("."),
                "ips": ",".join(ips)[:200],
                "port": str(self.port),
            },
        )
        self._zc = AsyncZeroconf(ip_version=IPVersion.V4Only)
        await self._zc.async_register_service(self._info, allow_name_change=True)
        log.info("Advertising %s on Bonjour (%s, %s)", self._info.name, server.rstrip("."), ", ".join(ips))

    async def stop(self) -> None:
        if self._zc is None:
            return
        if self._info is not None:
            await self._zc.async_unregister_service(self._info)
        await self._zc.async_close()
        self._zc = None
