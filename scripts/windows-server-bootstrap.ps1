# Windows Server lab bootstrap — run ONCE in an elevated PowerShell inside the
# fresh Windows Server VM (Parallels console). After this, everything else is
# done remotely over SSH.
#
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   irm https://raw.githubusercontent.com/glupa-claude/claude/main/scripts/windows-server-bootstrap.ps1 | iex
#
# Does: hostname -> Windows-Server, local admin user glupa (password prompted,
# never stored here), RDP enabled, OpenSSH server installed + firewall opened.
# Reboots at the end to apply the rename.

$ErrorActionPreference = "Stop"

Write-Host "== lab bootstrap: hostname, user, RDP, OpenSSH ==" -ForegroundColor Cyan

$pw = Read-Host -AsSecureString "Password for new admin user 'glupa'"

# --- local admin user (becomes Domain Admin later, when AD is set up) ---
if (-not (Get-LocalUser -Name glupa -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name glupa -Password $pw -PasswordNeverExpires -FullName "glupa"
    Write-Host "user glupa created"
} else {
    Set-LocalUser -Name glupa -Password $pw
    Write-Host "user glupa already exists - password reset"
}
Add-LocalGroupMember -Group Administrators -Member glupa -ErrorAction SilentlyContinue

# --- RDP ---
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
    -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Write-Host "RDP enabled"

# --- OpenSSH server: try the built-in capability, fall back to GitHub MSI ---
$sshOk = $false
try {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" |
        Select-Object -First 1
    if ($cap -and $cap.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    if ($cap) { $sshOk = $true }
} catch {
    Write-Host "capability install failed, using GitHub MSI fallback"
}
if (-not $sshOk) {
    $msi = "$env:TEMP\OpenSSH-ARM64.msi"
    Invoke-WebRequest -Uri ("https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-ARM64.msi") -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i", $msi, "/qn" -Wait
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (TCP 22)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
# make PowerShell (not cmd) the default shell for SSH sessions
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Host "OpenSSH server running"

ipconfig | Select-String IPv4
Write-Host "== done - renaming to Windows-Server and rebooting ==" -ForegroundColor Cyan
Rename-Computer -NewName "Windows-Server" -Force -Restart
