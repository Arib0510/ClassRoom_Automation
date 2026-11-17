param(
    [string]$BrokerAddress = "10.247.68.155",
    [string]$Subnet = "10.247.68.0/24",
    [string]$InterfaceAlias = "Wi-Fi"
)
$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}
$exe = "C:\Program Files\Mosquitto\mosquitto.exe"
$passwdExe = "C:\Program Files\Mosquitto\mosquitto_passwd.exe"
$config = "C:\Program Files\Mosquitto\mosquitto.conf"
$store = Join-Path $env:ProgramData "ClassroomMQTT"
if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $passwdExe)) {
    throw "Mosquitto 2.x executables were not found in Program Files."
}
if ((Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias).NetworkCategory -ne "Private") {
    throw "The selected network interface must have a Private profile."
}
$activeAddress = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -eq $BrokerAddress -and $_.PrefixOrigin -ne "WellKnown" }
if (-not $activeAddress) { throw "The broker address is not assigned to the selected interface." }

New-Item -ItemType Directory -Path $store -Force | Out-Null
$systemSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-18")
$adminsSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($systemSid, $adminsSid)) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
}
Set-Acl -LiteralPath $store -AclObject $acl

$names = @("pi-vision", "flutter-app", "esp32-board01", "esp32-board02", "esp32-board03", "esp32-ac")
$credentialPath = Join-Path $store "client-credentials.txt"
$credentials = [ordered]@{}
if (Test-Path -LiteralPath $credentialPath) {
    foreach ($line in [IO.File]::ReadAllLines($credentialPath)) {
        $pair = $line.Trim().TrimStart([char]0xFEFF).Split('=', 2)
        if ($pair.Count -eq 2) { $credentials[$pair[0]] = $pair[1] }
    }
    if ((@($credentials.Keys | Sort-Object) -join ',') -ne (@($names | Sort-Object) -join ',')) {
        throw "Existing broker credential file is incomplete; preserve it and review before provisioning."
    }
} else {
    foreach ($name in $names) {
        $bytes = [byte[]]::new(32)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $credentials[$name] = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','A').Replace('/','B')
    }
}
$passwordFile = Join-Path $store "passwords.txt"
$firstUser = $true
foreach ($name in $names) {
    if ($firstUser) {
        & $passwdExe -b -c $passwordFile $name $credentials[$name] 2>$null
        $firstUser = $false
    } else {
        & $passwdExe -b $passwordFile $name $credentials[$name] 2>$null
    }
    if ($LASTEXITCODE -ne 0) { throw "Mosquitto password provisioning failed." }
}

$aclLines = [System.Collections.Generic.List[string]]::new()
$aclLines.Add("user pi-vision")
# Pi vision runtime: telemetry and app exchange only. Default deny protects all
# physical ruet commands and the controllers/<id>/command route at broker level.
$aclLines.Add("topic read ruet/classroom/reb_room_301/status/#")
$aclLines.Add("topic read ruet/classroom/reb_room_301/zone/+/status")
$aclLines.Add("topic read ruet/classroom/reb_room_301/zone/+/ac/status")
$aclLines.Add("topic read ruet/classroom/reb_room_301/board/+/status")
$aclLines.Add("topic read classpulse/reb_room_301/app/requests")
$aclLines.Add("topic write classpulse/reb_room_301/app/state")
$aclLines.Add("topic write classpulse/reb_room_301/app/results")
$aclLines.Add("topic read classpulse/reb_room_301/controllers/+/status")
$aclLines.Add("topic read classpulse/reb_room_301/controllers/+/ack")
$aclLines.Add("topic write classpulse/reb_room_301/controllers/+/hello")
$aclLines.Add("topic write classpulse/reb_room_301/controllers/+/dry_run/command")
$aclLines.Add("topic readwrite classpulse/reb_room_301/diagnostics/non_actuating/#")
$aclLines.Add("user flutter-app")
$aclLines.Add("topic readwrite ruet/classroom/reb_room_301/#")
$aclLines.Add("topic readwrite classpulse/reb_room_301/#")
$aclLines.Add("topic readwrite home/#")
foreach ($board in 1..3) {
    $id = "board0$board"
    $user = "esp32-$id"
    $aclLines.Add("user $user")
    $aclLines.Add("topic read ruet/classroom/reb_room_301/zone/$board/#")
    $aclLines.Add("topic read ruet/classroom/reb_room_301/board/$board/#")
    $aclLines.Add("topic read ruet/classroom/reb_room_301/command/#")
    $aclLines.Add("topic read ruet/classroom/reb_room_301/controllers/$id/#")
    $aclLines.Add("topic read classpulse/reb_room_301/controllers/$id/#")
    $aclLines.Add("topic read home/discovery/query")
    $aclLines.Add("topic read home/zone_$board/#")
    $aclLines.Add("topic write ruet/classroom/reb_room_301/zone/$board/#")
    $aclLines.Add("topic write ruet/classroom/reb_room_301/board/$board/#")
    $aclLines.Add("topic write ruet/classroom/reb_room_301/status/board/$board/#")
    $aclLines.Add("topic write ruet/classroom/reb_room_301/controllers/$id/#")
    $aclLines.Add("topic write classpulse/reb_room_301/controllers/$id/#")
    $aclLines.Add("topic write home/discovery")
    $aclLines.Add("topic write home/zone_$board/#")
}
$aclLines.Add("user esp32-ac")
$aclLines.Add("topic read ruet/classroom/reb_room_301/#")
$aclLines.Add("topic read home/discovery/query")
$aclLines.Add("topic write ruet/classroom/reb_room_301/#")
$aclLines.Add("topic write home/discovery")
$aclPath = Join-Path $store "acl.txt"
if (Test-Path -LiteralPath $aclPath) {
    $aclBackup = "$aclPath.pre-pi-vision-hardening.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $aclPath -Destination $aclBackup
    Write-Output "Existing ACL backed up to $aclBackup"
}
[IO.File]::WriteAllLines($aclPath, $aclLines, [Text.Encoding]::ASCII)
$credentialLines = foreach ($name in $names) { "$name=$($credentials[$name])" }
[IO.File]::WriteAllLines($credentialPath, $credentialLines, [Text.Encoding]::UTF8)
$fileAcl = [Security.AccessControl.FileSecurity]::new()
$fileAcl.SetAccessRuleProtection($true, $false)
foreach ($sid in @($systemSid, $adminsSid)) {
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, "FullControl", "Allow"))
}
foreach ($path in @($passwordFile, $aclPath, $credentialPath)) {
    Set-Acl -LiteralPath $path -AclObject $fileAcl
}

$lines = @(
    "listener 1883 $BrokerAddress",
    "protocol mqtt",
    "allow_anonymous false",
    "password_file $($passwordFile -replace '\\','/')",
    "acl_file $($aclPath -replace '\\','/')",
    "persistence_location $($store -replace '\\','/')/",
    "persistence true",
    "log_type error",
    "log_type warning"
)
$backup = "$config.pre-classroom.bak"
if ((Test-Path -LiteralPath $config) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $config -Destination $backup
}
[IO.File]::WriteAllLines($config, $lines, [Text.Encoding]::ASCII)
$firewallName = "Classroom Mosquitto MQTT (Wi-Fi subnet only)"
Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 1883 -LocalAddress $BrokerAddress -RemoteAddress $Subnet `
    -InterfaceAlias $InterfaceAlias -Profile Private | Out-Null
Restart-Service -Name mosquitto
Start-Sleep -Seconds 2
$listeners = Get-NetTCPConnection -State Listen -LocalPort 1883 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty LocalAddress
if ($BrokerAddress -notin $listeners) { throw "Mosquitto did not bind to the configured LAN address." }
Write-Output "Mosquitto now listens on the selected private interface."
Write-Output "Restricted firewall rule: Private / $InterfaceAlias / $Subnet / TCP 1883."
Write-Output "Credential file stored with SYSTEM and Administrators access: $credentialPath"
