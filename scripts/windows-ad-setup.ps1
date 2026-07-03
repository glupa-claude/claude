# Promote the Windows Server VM to a domain controller for the lab domain.
# Run over SSH (or locally) in elevated PowerShell AFTER windows-server-bootstrap.ps1.
#
#   .\windows-ad-setup.ps1
#
# Creates forest macos-lab.local (NetBIOS: MACOS-LAB) with DNS, forwarding
# unresolved queries to the Parallels gateway so internet names keep working.
# The machine's local accounts (incl. glupa) become domain accounts during
# promotion; a follow-up step adds glupa to Domain Admins.

$ErrorActionPreference = "Stop"

$DomainFqdn = "macos-lab.local"
$DomainNetbios = "MACOS-LAB"
$UpstreamDns = "10.211.55.1"   # Parallels shared-network gateway/DNS

Write-Host "== installing AD DS + DNS roles ==" -ForegroundColor Cyan
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools

$dsrm = Read-Host -AsSecureString "Choose a DSRM (recovery) password"

Write-Host "== promoting to domain controller for $DomainFqdn ==" -ForegroundColor Cyan
Import-Module ADDSDeployment
Install-ADDSForest `
    -DomainName $DomainFqdn `
    -DomainNetbiosName $DomainNetbios `
    -SafeModeAdministratorPassword $dsrm `
    -InstallDns `
    -NoRebootOnCompletion:$false `
    -Force
# The server reboots itself when promotion finishes.
# AFTER the reboot, run these two lines (SSH back in):
#   Add-ADGroupMember -Identity "Domain Admins" -Members glupa
#   Set-DnsServerForwarder -IPAddress 10.211.55.1
