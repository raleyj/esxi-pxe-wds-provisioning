# Step-by-step setup

## 1. Prepare the Windows Server

Run `scripts/Install-EsxiPxeProvisioningPrereqs.ps1` as Administrator. It
installs WDS and IIS without installing a local DHCP scope. Keep DHCP on the
router or dedicated DHCP service.

Use `scripts/New-TftpServerVlanAdapters.ps1` with a copy of
`config/network.example.json` tailored to the environment. The PXE/TFTP
adapter must not receive a default gateway.

## 2. Configure the DHCP/PXE network

On the DHCP appliance, configure the provisioning VLAN to provide the WDS
server IP as the TFTP server and `Boot\\x64\\ipxe.efi` as the UEFI x64 boot
file. When WDS and DHCP are separate, do not enable DHCP option 60 on WDS.

Validate listener and WDS settings with:

```powershell
.\scripts\Test-WdsPxeEndpoint.ps1 -RequireUnattendedPxe
```

## 3. Configure WDS and iPXE

Place the custom UEFI iPXE binary in `D:\RemoteInstall\Boot\x64\ipxe.efi`.
For WDS environments that direct UEFI clients to `wdsmgfw.efi`, copy the same
binary to `D:\RemoteInstall\Boot\x64\wdsmgfw.efi` and restart `WDSServer`.

Configure WDS to use iPXE for x64 UEFI clients:

```powershell
wdsutil /Set-Server /BootProgram:Boot\x64\ipxe.efi /Architecture:x64uefi
wdsutil /Set-Server /N12BootProgram:Boot\x64\ipxe.efi /Architecture:x64uefi
Restart-Service WDSServer
```

Disable Secure Boot unless the iPXE binary is signed by a trusted key.

## 4. Configure IIS content

Create `D:\ESXiProvisioning` and expose it as the IIS virtual directory
`/esxi`. Extract the approved ESXi ISO beneath `images\<image-name>`. Do not
serve the ISO as a single file; serve the extracted image tree.

Add static-content MIME mappings for `.ipxe`, `.cfg`, `.b00`, `.v00`, `.v01`,
`.v02`, `.t00`, `.efi`, `.gz`, and `.tgz` using
`application/octet-stream` where appropriate.

## 5. Add host mappings

Put the central MAC dispatcher at `D:\ESXiProvisioning\boot.ipxe`. Each
dispatcher match must explicitly continue on a non-match and set `bootmac`
before chaining to a host launcher. Use the included `ipxe/` examples.

Each host launcher loads `EFI/BOOT/BOOTX64.EFI` with the host boot config and
passes `BOOTIF=01-${bootmac}`. This tells ESXi which PXE NIC was used.

Create a `hosts\<host>\boot.cfg` by copying the image's `EFI\BOOT\BOOT.CFG`.
Update only `prefix=` and `kernelopt=`. For HTTP boot, remove leading `/`
characters from all `kernel=` and `modules=` file names.

Store Kickstarts at `D:\ESXiProvisioning\kickstarts`. Use a dedicated
Kickstart per host and avoid stale `ignoredrives` entries from removed USB
devices.

## 6. Validate before booting hosts

Run:

```powershell
.\scripts\Test-EsxiInstallerContent.ps1 -HostName <host>
```

Every result must be HTTP 200. If ESXi reports fatal error 15, inspect the IIS
logs to find the first missing or blocked module. A 404.3 normally means a
missing MIME map, not a corrupt ISO.

## 7. Install and hand off

Set the one-gig PXE NIC to the provisioning VLAN and UEFI PXE boot first. Keep
the management NIC on its intended management VLAN. After an install completes,
remove PXE boot priority or disconnect the provisioning VLAN to avoid a
reinstall loop.
