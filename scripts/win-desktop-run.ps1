# Runs a command in the signed-in user's desktop session (SSH sessions have no visible desktop),
# waits for it, and prints its output. Used to test captures and the app from the Mac:
#   ssh rnwin -File C:/dev/rasternest/scripts/win-desktop-run.ps1 "rnest capture --fullscreen -o C:/dev/out/x.png"
param([Parameter(Mandatory)][string]$Command, [int]$TimeoutSeconds = 120)
$ErrorActionPreference = 'Stop'
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$out = Join-Path $env:TEMP "rn-desktop-$id.log"
$script = Join-Path $env:TEMP "rn-desktop-$id.cmd"
Set-Content -Path $script -Encoding ASCII -Value "@echo off`r`n($Command) > `"$out`" 2>&1`r`necho EXIT=%ERRORLEVEL% >> `"$out`""
$name = "RasterNestDesktopRun-$id"
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$script`""
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $name
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do { Start-Sleep -Milliseconds 300 } while (((Get-ScheduledTask -TaskName $name).State -eq 'Running' -or -not (Test-Path $out)) -and (Get-Date) -lt $deadline)
    Start-Sleep -Milliseconds 200
    if (Test-Path $out) { Get-Content $out -Encoding UTF8 } else { "No output (is someone signed in to the desktop?)" }
} finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Remove-Item $script, $out -ErrorAction SilentlyContinue
}
