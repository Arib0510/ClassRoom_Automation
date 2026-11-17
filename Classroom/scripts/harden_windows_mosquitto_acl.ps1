param(
    [string]$Store = (Join-Path $env:ProgramData "ClassroomMQTT"),
    [string]$Config = "C:\Program Files\Mosquitto\mosquitto.conf"
)
$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run from elevated PowerShell on the broker host."
}

$aclPath = Join-Path $Store "acl.txt"
if (-not (Test-Path -LiteralPath $aclPath) -or -not (Test-Path -LiteralPath $Config)) {
    throw "Expected current Mosquitto ACL/config was not found; no files changed."
}
if (-not (Select-String -LiteralPath $Config -Pattern 'acl_file\s+C:/ProgramData/ClassroomMQTT/acl.txt' -Quiet)) {
    throw "Configured ACL path differs from $aclPath; no files changed."
}

$piRules = @(
    "user pi-vision",
    "topic read ruet/classroom/reb_room_301/status/#",
    "topic read ruet/classroom/reb_room_301/zone/+/status",
    "topic read ruet/classroom/reb_room_301/zone/+/ac/status",
    "topic read ruet/classroom/reb_room_301/board/+/status",
    "topic read classpulse/reb_room_301/app/requests",
    "topic write classpulse/reb_room_301/app/state",
    "topic write classpulse/reb_room_301/app/results",
    "topic read classpulse/reb_room_301/controllers/+/status",
    "topic read classpulse/reb_room_301/controllers/+/ack",
    "topic write classpulse/reb_room_301/controllers/+/hello",
    "topic write classpulse/reb_room_301/controllers/+/dry_run/command",
    "topic readwrite classpulse/reb_room_301/diagnostics/non_actuating/#"
)
if ($piRules | Where-Object { $_ -match '^topic write ruet/' }) {
    throw "Safety check failed: pi-vision rules may not write ruet topics."
}
if ($piRules | Where-Object { $_ -match '^topic (write|readwrite) classpulse/reb_room_301/#' }) {
    throw "Safety check failed: pi-vision rules may not grant a room-wide write."
}

$lines = [IO.File]::ReadAllLines($aclPath)
$updated = [System.Collections.Generic.List[string]]::new()
$found = $false
$skipOldPiBlock = $false
foreach ($line in $lines) {
    if ($line -match '^\s*user\s+pi-vision\s*$') {
        if ($found) { throw "Duplicate pi-vision ACL blocks found; no files changed." }
        $found = $true
        $skipOldPiBlock = $true
        foreach ($rule in $piRules) { $updated.Add($rule) }
        continue
    }
    if ($skipOldPiBlock -and $line -match '^\s*user\s+') { $skipOldPiBlock = $false }
    if (-not $skipOldPiBlock) { $updated.Add($line) }
}
if (-not $found) { throw "No existing pi-vision ACL block found; no files changed." }

$backup = "$aclPath.pre-pi-vision-hardening.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
Copy-Item -LiteralPath $aclPath -Destination $backup
$temporary = "$aclPath.hardening.tmp"
[IO.File]::WriteAllLines($temporary, $updated, [Text.Encoding]::ASCII)
Move-Item -LiteralPath $temporary -Destination $aclPath -Force

try {
    Restart-Service -Name mosquitto -ErrorAction Stop
    $service = Get-Service -Name mosquitto
    if ($service.Status -ne "Running") { throw "Mosquitto did not return to Running state." }
} catch {
    Copy-Item -LiteralPath $backup -Destination $aclPath -Force
    throw "Mosquitto ACL reload failed; previous ACL restored from backup. $($_.Exception.Message)"
}

Write-Output "Pi vision ACL narrowed and Mosquitto restarted."
Write-Output "Backup: $backup"
Write-Output "No MQTT publish or appliance command was sent."
