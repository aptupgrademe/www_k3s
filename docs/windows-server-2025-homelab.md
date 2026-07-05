# Windows Server 2025 – Homelab-Einrichtung

**Hostname:** win25k1  
**Domain:** MUENCH / muench.home.arpa  
**IP:** 192.168.10.50 (LAN)  
**Datum:** 2026-07-01

**Alle Schritte als PowerShell-Skripte:** siehe separates Repo
[aptupgrademe/powershell_NAS](https://github.com/aptupgrademe/powershell_NAS)
(inkl. englischer README)

---

## Hardware

| Komponente | Details |
|---|---|
| Modell | HP MicroServer Gen10 Plus V2 |
| CPU | (AMD/Intel, je nach Konfiguration) |
| RAM | 31 GB |
| OS-Disk | WDC WDS500G1R0A-68A4W0 (500 GB SSD, Laufwerk C:) |
| Datendisks | 3× WD Red SA500 2.5 2TB → Storage Pool |
| Zusatzdisk | Intenso Speed Line 60 GB (nicht im Pool) |

---

## 1. Storage Spaces Pool mit ReFS

3× WD Red SA500 2TB zu einem Storage Pool mit Parity-Layout (RAID5-äquivalent) zusammengefasst.

```powershell
# Physische Disks fuer den Pool ermitteln
$disks = Get-PhysicalDisk | Where-Object { $_.FriendlyName -like "WD Red SA500*" }

# Storage Pool anlegen
$subsystem = Get-StorageSubSystem
New-StoragePool `
    -FriendlyName "DataPool" `
    -StorageSubSystemUniqueId $subsystem.UniqueId `
    -PhysicalDisks $disks

# Virtuelle Disk mit Parity (RAID5) erstellen
New-VirtualDisk `
    -StoragePoolFriendlyName "DataPool" `
    -FriendlyName "DataVol" `
    -ResiliencySettingName Parity `
    -UseMaximumSize

# Disk initialisieren, Partition anlegen, mit ReFS formatieren
Initialize-Disk -FriendlyName "DataVol" -PartitionStyle GPT -PassThru | Out-Null
New-Partition -DiskNumber 5 -UseMaximumSize -DriveLetter D | Out-Null
Format-Volume -DriveLetter D -FileSystem ReFS -NewFileSystemLabel "DataPool" -Confirm:$false
```

**Ergebnis:** ~3,6 TB nutzbar auf D:\, ReFS-Dateisystem (Checksummen + Selbstheilung)

**Wichtig:** VSS Shadow Copies funktionieren NICHT auf ReFS. Backup via Windows Server Backup
oder `Checkpoint-Volume` statt VSS.

---

## 2. OpenSSH Server

SSH-Zugang für Remote-Verwaltung (auch mit Ansible nutzbar).

```powershell
# Feature installieren
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Dienst konfigurieren
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# PowerShell als Standard-Shell fuer SSH-Sessions
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force

# Firewall-Regel auf alle Netzwerkprofile erweitern
# (Standard-Regel gilt nur fuer "Private" – bei DomainAuthenticated-Netzen noetig)
Set-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -Profile Any
```

**SSH Public Key hinterlegen** (fuer Administratoren gilt ein eigener Pfad):
```powershell
# Inhalt der id_rsa.pub in diese Datei schreiben:
$path = "C:\ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $path -Value "ssh-rsa AAAA...dein-key..." -Encoding UTF8

# Berechtigungen setzen (kein Vererben, nur SYSTEM + Administrators)
$acl = Get-Acl $path
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "NT AUTHORITY\SYSTEM", "FullControl", "Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators", "FullControl", "Allow")))
Set-Acl $path $acl
Restart-Service sshd
```

---

## 3. Active Directory Domain Users

Domain: `muench.home.arpa` (MUENCH)

AD-Benutzer mit `PasswordNeverExpires` – alle mit UPN `benutzername@muench.home.arpa`:

```powershell
$pw = ConvertTo-SecureString "PASSWORT" -AsPlainText -Force
$domain = (Get-ADDomain).DNSRoot

@(
    @{Sam="raphael";  First="Raphael";  Last="Muench"},
    @{Sam="angelika"; First="Angelika"; Last="Muench"},
    @{Sam="emilia";   First="Emilia";   Last="Muench"},
    @{Sam="marlon";   First="Marlon";   Last="Muench"},
    @{Sam="kerstin";  First="Kerstin";  Last="Muench"}
) | ForEach-Object {
    New-ADUser `
        -Name                  "$($_.First) $($_.Last)" `
        -SamAccountName        $_.Sam `
        -GivenName             $_.First `
        -Surname               $_.Last `
        -UserPrincipalName     "$($_.Sam)@$domain" `
        -AccountPassword       $pw `
        -Enabled               $true `
        -PasswordNeverExpires  $true `
        -ChangePasswordAtLogon $false
}
```

---

## 4. Windows Update GPO (ohne WSUS)

GPO-Name: **Windows11-UpdatePolicy**, verknüpft mit der gesamten Domain.

```powershell
New-GPO -Name "Windows11-UpdatePolicy" -Comment "Windows Update Steuerung fuer Win11 Clients"

$regAU = "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$regWU = "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

# Taeglich um 19:00 Uhr installieren, kein Zwangs-Neustart
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regAU -ValueName "AUOptions"                       -Type DWord -Value 4
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regAU -ValueName "ScheduledInstallDay"             -Type DWord -Value 0
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regAU -ValueName "ScheduledInstallTime"            -Type DWord -Value 19
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regAU -ValueName "NoAutoRebootWithLoggedOnUsers"   -Type DWord -Value 1

# Sicherheitspatches 7 Tage, Feature-Updates 60 Tage verzoegern
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "DeferQualityUpdates"             -Type DWord -Value 1
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 7
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "DeferFeatureUpdates"             -Type DWord -Value 1
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 60

# Aktive Stunden 07:00-20:00 (kein Neustart waehrend Nutzungszeit)
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "SetActiveHours"                  -Type DWord -Value 1
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "ActiveHoursStart"                -Type DWord -Value 7
Set-GPRegistryValue -Name "Windows11-UpdatePolicy" -Key $regWU -ValueName "ActiveHoursEnd"                  -Type DWord -Value 20

# GPO mit Domain verknuepfen
$domain = (Get-ADDomain).DistinguishedName
New-GPLink -Name "Windows11-UpdatePolicy" -Target $domain -LinkEnabled Yes
```

---

## 5. Server-Hardening & Performance

Vollständiges Skript: [05-Set-ServerHardeningHomelab.ps1](https://github.com/aptupgrademe/powershell_NAS/blob/main/05-Set-ServerHardeningHomelab.ps1)

```powershell
# Power Plan: Ausbalanciert (skaliert CPU mit Last)
powercfg /setactive SCHEME_BALANCED
powercfg /change disk-timeout-ac 0     # SSDs nie abschalten
powercfg /change monitor-timeout-ac 1  # Display sofort (headless)

# Print Spooler deaktivieren (PrintNightmare & Nachfolger)
Stop-Service Spooler -Force
Set-Service  Spooler -StartupType Disabled

# LLMNR deaktivieren (verhindert MITM-Relay-Angriffe im LAN)
$path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
Set-ItemProperty -Path $path -Name "EnableMulticast" -Value 0 -Type DWord

# NetBIOS ueber TCP/IP deaktivieren
Get-WmiObject Win32_NetworkAdapterConfiguration |
    Where-Object { $_.TcpipNetbiosOptions -ne $null } |
    ForEach-Object { $_.SetTcpipNetbios(2) | Out-Null }

# Pagefile: 8 GB fix (statt auto ~1,5x RAM = 46 GB auf 31-GB-System)
$cs = Get-WmiObject Win32_ComputerSystem
$cs.AutomaticManagedPagefile = $false
$cs.Put() | Out-Null
Set-ItemProperty `
    "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" `
    -Name "PagingFiles" -Value "C:\pagefile.sys 8192 8192" -Type MultiString
# Neustart erforderlich!

# SMB Multichannel + groessere Credits (besser fuer mehrere parallele Clients)
Set-SmbServerConfiguration -EnableMultiChannel $true `
    -Smb2CreditsMin 128 -Smb2CreditsMax 2048 -Confirm:$false

# Eventlog-Groessen erhoehen (Standard 20 MB reicht nicht)
wevtutil sl Security    /ms:104857600  # 100 MB
wevtutil sl System      /ms:52428800   # 50 MB
wevtutil sl Application /ms:52428800   # 50 MB
```

---

## Benchmark-Ergebnisse (Storage Pool D:\)

Gemessen mit diskspd (Microsoft), direktes I/O ohne OS-Cache:

| Test | Ergebnis |
|---|---|
| Sequentielles Schreiben (1M Blöcke) | ~89 MB/s |
| 4K Random Write | ~1.318 IOPS |
| Sequentielles Lesen | > GbE-Limit (625 MB/s max über Netzwerk) |

Sequentielles Schreiben mit Storage Spaces Parity ist typischerweise langsamer als
ein einzelnes SSD (Read-Modify-Write-Zyklus für jede Parity-Berechnung). Für ein
Heimnetz-NAS über Gigabit-Ethernet (125 MB/s theoretisches Limit) ist 89 MB/s
mehr als ausreichend.

---

## Bekannte Einschränkungen

| Thema | Einschränkung |
|---|---|
| VSS Shadow Copies | Nicht kompatibel mit ReFS – alternative: Windows Server Backup |
| Pagefile-Änderung | Wirkt erst nach Neustart |
| SMB Linux-Clients | Explizit `vers=3.1.1,rsize=16777216,wsize=16777216` beim Mounten angeben |
