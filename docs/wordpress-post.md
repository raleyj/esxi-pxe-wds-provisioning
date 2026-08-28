# Building an ESXi PXE Server with WDS, iPXE, and IIS

Booting ESXi from the network does not require a USB installer, vCenter, or a
DHCP role on the Windows server. This build uses WDS for initial UEFI PXE/TFTP,
iPXE for the handoff to HTTP, and IIS to serve the extracted ESXi image and a
separate Kickstart for every host.

## Architecture

The DHCP appliance owns the address scope. WDS runs on a Windows Server with a
dedicated PXE VLAN interface but does not manage DHCP. Clients receive iPXE from
WDS, iPXE downloads a central script from IIS, and that script selects a
host-specific launcher based on the PXE MAC address.

The host launcher passes `BOOTIF` to ESXi and points it to the host-specific
`boot.cfg`. The `boot.cfg` adds a Kickstart URL while the rest of the installer
is retrieved over HTTP.

## Build the Windows services

Install WDS and IIS. Configure WDS to respond to UEFI x64 clients, disable DHCP
option 60 because DHCP is remote, and confirm UDP 67, 69, and 4011 are
listening. Keep the PXE adapter without a default gateway.

The DHCP appliance needs the WDS/PXE server address and an x64 UEFI boot file:
`Boot\\x64\\ipxe.efi`. If WDS sends `wdsmgfw.efi` instead, serve the custom iPXE
binary under that filename as well.

## Serve ESXi correctly

Extract—not merely upload—the approved ESXi ISO to the IIS content directory.
Add IIS MIME maps for every module extension used by the installer, including
`.v00`, `.v01`, `.v02`, `.t00`, `.b00`, `.gz`, and `.tgz`. Missing MIME types
produce IIS 404.3 responses and ESXi fatal error 15.

For the UEFI host `boot.cfg`, copy `EFI/BOOT/BOOT.CFG` from the extracted image.
Set the HTTP image prefix and Kickstart URL, then remove leading slashes from
the `kernel=` and `modules=` filenames.

## Make per-host installations deterministic

Use a dispatcher that checks all iPXE interface indices, not only `net0`, since
adapter enumeration can vary by server. On a match, set `bootmac`, chain to the
host launcher, and start the ESXi UEFI loader with
`BOOTIF=01-${bootmac}`. That parameter avoids the ESXi “MAC address not found”
message.

Keep a distinct Kickstart for each host. Specify the actual management adapter,
network settings, boot-disk policy, and management VLAN. Remove old
`ignoredrives` directives if their referenced USB device is no longer present.

## Validate before the next boot

Test WDS listeners, then test each installer module over HTTP. Every required
module must return HTTP 200 before booting a physical server. If a boot fails,
the IIS logs reveal the last requested module and make the fault clear.

Once a host finishes installing, remove PXE priority or disconnect the PXE VLAN
to prevent accidental reinstalls.

Source scripts and a reusable reference layout are available in the associated
GitHub repository. Never commit real root passwords, ESXi ISO files, private
credentials, or environment-specific network details.
