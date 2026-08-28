# ESXi PXE provisioning with WDS, iPXE, and IIS

Reusable scripts and reference configuration for booting ESXi installers over
UEFI PXE, switching to HTTP for installer content, and selecting a dedicated
Kickstart file per host MAC address.

## Design

- Windows Deployment Services (WDS) provides PXE/TFTP only.
- A router or DHCP appliance owns DHCP scopes and relays PXE traffic.
- iPXE is loaded by WDS and chains to IIS-hosted scripts.
- IIS serves the extracted ESXi ISO and host-specific Kickstart files over HTTP.
- A MAC dispatcher selects the intended host launcher and passes `BOOTIF` to
  the ESXi installer.

Read [the setup guide](docs/setup-guide.md) before deployment. The repository
intentionally excludes ESXi installer media, passwords, private credentials,
and environment-specific Kickstarts.

## Repository contents

- `scripts/` — Windows Server WDS/IIS, VLAN, inventory, and validation scripts.
- `ipxe/` — reusable central dispatcher and per-host launcher templates.
- `config/` — safe example configuration files.
- `docs/` — build guide and WordPress-ready article draft.

## Security notes

Keep this repository private if it contains internal host MAC addresses or
network addresses. Do not commit Kickstarts that embed passwords. Store them
outside source control or use a secret-management workflow.
