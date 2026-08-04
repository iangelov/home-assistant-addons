# home-assistant-addons

## Tailscale

`accept_dns` defaults to `true`. When enabled, the add-on accepts the DNS
configuration from the tailnet and makes MagicDNS available to Home Assistant
Core and Supervisor. When disabled, those clients resolve only tailnet names
through Tailscale; ordinary DNS remains outside the tailnet DNS configuration.

To enable MagicDNS for Home Assistant, configure Quad100 once from the HAOS
terminal (the add-on only reports when this is missing; it never changes it):

```sh
ha dns options --servers dns://100.100.100.100
```

To undo that change, run:

```sh
ha dns reset
ha dns restart
```
