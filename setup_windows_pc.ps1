# One-time setup of the Windows render PC for remote/remote_render.sh.
# Run in PowerShell *as Administrator* on the PC:
#   powershell -ExecutionPolicy Bypass -File setup_windows_pc.ps1
#
# Installs and starts the OpenSSH server, opens port 22 on private networks, authorises the
# Mac's SSH key, creates the render folder and the render queue the BlenderRender app uses
# (scheduled task BlenderRenderQueue), then prints what goes into remote_render.env / the app.
$ErrorActionPreference = "Stop"

# The BlenderRender app fills this in with the Mac's own public key when it copies or saves the script.
$MacKey = "__MAC_PUBLIC_KEY__"
# Filled in when the PC fetches the script from Add PC, so the pairing code goes straight back to the Mac.
$PairUrl = "__PAIR_URL__"
# Where to fetch the BlenderRender PC tray app when this runs from PowerShell; when the tray app itself
# runs this script, it sets $TrayExe to its own path first.
$TrayUrl = "__TRAY_URL__"
$RenderRoot = "C:\GeysierRender"
if ($MacKey -like "__MAC*") { throw "Use Copy Script in BlenderRender (Help > Set Up a Render PC), or put the Mac's ~/.ssh/id_ed25519.pub in `$MacKey." }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an Administrator PowerShell (right-click > Run as administrator)."
}

Write-Host "== OpenSSH server"
$cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name "GeysierRender-SSH" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "GeysierRender-SSH" -DisplayName "OpenSSH (Geysier render)" -Enabled True `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Private,Domain | Out-Null
}

Write-Host "== Authorising the Mac's key"
# Admin accounts read ProgramData\ssh\administrators_authorized_keys; others read ~\.ssh\authorized_keys.
$adminKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path $adminKeys) -or -not (Select-String -Path $adminKeys -SimpleMatch $MacKey -Quiet)) {
    Add-Content -Path $adminKeys -Value $MacKey
}
icacls $adminKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
$userSsh = "$env:USERPROFILE\.ssh"
New-Item -ItemType Directory -Force -Path $userSsh | Out-Null
$userKeys = "$userSsh\authorized_keys"
if (-not (Test-Path $userKeys) -or -not (Select-String -Path $userKeys -SimpleMatch $MacKey -Quiet)) {
    Add-Content -Path $userKeys -Value $MacKey
}

New-Item -ItemType Directory -Force -Path $RenderRoot | Out-Null

$blender = Get-ChildItem "C:\Program Files\Blender Foundation\*\blender.exe", `
    "C:\Program Files (x86)\Steam\steamapps\common\Blender\blender.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1
if ($blender) {
    Write-Host "== Render queue (for the BlenderRender Mac app)"
    # rq.py and its helpers are copied here by the Mac app; this sets up how they run.
    $queue = "$RenderRoot\queue"
    New-Item -ItemType Directory -Force -Path $queue | Out-Null
    $py = Get-ChildItem (Split-Path $blender.FullName) -Recurse -Depth 4 -Filter python.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -like "*\python\bin\python.exe" | Select-Object -First 1
    if (-not $py) { throw "Blender's bundled python.exe not found under $(Split-Path $blender.FullName)" }
    @{ blender = $blender.FullName; gpu = $true } | ConvertTo-Json | Set-Content "$queue\rq_config.json" -Encoding ascii
    "@`"$($py.FullName)`" `"%~dp0rq.py`" %*" | Set-Content "$queue\rq.cmd" -Encoding ascii
    # The worker renders queued jobs one at a time; it starts at logon and the Mac app starts it on demand.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -WorkingDirectory $queue `
        -Argument "-NoProfile -WindowStyle Hidden -Command & '$($py.FullName)' '$queue\rq.py' worker"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "BlenderRenderQueue" -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Force | Out-Null

    Write-Host "== BlenderRender PC (taskbar app with the on/off switch)"
    $tray = "$queue\BlenderRenderPC.exe"
    try {
        if ($TrayExe -or ($TrayUrl -notlike "__TRAY*")) {
            # Windows lets a running exe be renamed but not overwritten.
            if (Test-Path $tray) { Move-Item $tray "$tray.$(Get-Date -Format yyyyMMddHHmmss).old" -Force }
            if ($TrayExe) { Copy-Item $TrayExe $tray -Force } else { Invoke-WebRequest $TrayUrl -OutFile $tray -UseBasicParsing }
        }
        if (Test-Path $tray) {
            Unblock-File $tray  # downloaded in a browser: no "are you sure" every time it starts
            $trayAction = New-ScheduledTaskAction -Execute $tray -Argument "--tray"
            $traySettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName "BlenderRenderPC" -Action $trayAction -Trigger $trigger -Settings $traySettings `
                -Principal $principal -Force | Out-Null
            if (-not $TrayExe) { Start-ScheduledTask -TaskName "BlenderRenderPC" }  # the tray app starts its own copy
        }
    } catch {
        Write-Host "!! Couldn't install the BlenderRender PC app: $($_.Exception.Message). Rendering works without it." -ForegroundColor Yellow
    }
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -First 1).IPAddress
$gpu = (Get-CimInstance Win32_VideoController | Where-Object Name -like "*NVIDIA*" | Select-Object -First 1).Name

Write-Host ""
Write-Host "== Done. Send these back:"
Write-Host "WIN_HOST=$ip   (computer name: $env:COMPUTERNAME)"
Write-Host "WIN_USER=$env:USERNAME"
Write-Host "WIN_BLENDER=$(if ($blender) { $blender.FullName } else { 'NOT FOUND - where is blender.exe?' })"
Write-Host "GPU=$gpu"
if ($blender) {
    $pairing = @{ host = $ip; user = $env:USERNAME; name = $env:COMPUTERNAME } | ConvertTo-Json -Compress
    Write-Host ""
    Write-Host "== Pairing code. Copy this line into Add PC in BlenderRender:"
    $pairCode = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pairing))
    Write-Host "BR1:$pairCode"
    if ($PairUrl -and $PairUrl -notlike "__PAIR*") {
        try {
            Invoke-RestMethod "$PairUrl/$pairCode" -TimeoutSec 5 | Out-Null
            Write-Host "== Sent to the Mac. No need to copy it."
        } catch {
            Write-Host "== Couldn't reach the Mac. Copy the line above into Add PC."
        }
    }
}

# The firewall rule above only covers Private networks, so the Mac can't connect on a Public one.
$public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object NetworkCategory -eq "Public")
foreach ($net in $public) {
    Write-Host ""
    Write-Host "!! '$($net.InterfaceAlias)' is set to Public, so the Mac can't connect through it." -ForegroundColor Yellow
    Write-Host "!! Fix: Settings > Network & internet > $($net.InterfaceAlias) > Properties > Private network." -ForegroundColor Yellow
}
