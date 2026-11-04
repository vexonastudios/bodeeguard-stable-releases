# This script intentionally installs software. NEVER run it on a family/development PC.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (!$env:BG_CHANNEL) { $env:BG_CHANNEL='stable' }
if ($env:BG_CHANNEL -notin @('stable','test')) { throw 'Invalid release channel' }
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'vexonastudios/bodeeguard-stable-releases') { throw 'Disposable GitHub-hosted release VM required' }
if ($env:BG_VERSION -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}$' -or $env:BG_EXPECTED_SHA -notmatch '^[a-f0-9]{64}$' -or $env:BG_EXPECTED_SIZE -notmatch '^\d{4,9}$') { throw 'Invalid artifact identity' }
$out = Join-Path $env:GITHUB_WORKSPACE 'acceptance-output'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$receipt = [ordered]@{ schemaVersion=1; purpose='bodeeguard-real-installer-smoke'; channel=$env:BG_CHANNEL; version=$env:BG_VERSION; sha256=$env:BG_EXPECTED_SHA; size=[long]$env:BG_EXPECTED_SIZE; runUrl="https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"; runnerImage=$env:ImageVersion; checkedAt=(Get-Date).ToUniversalTime().ToString('o'); status='failed'; checks=@(); limitations=@('Windows Server VM; Windows 10/11 physical hardware and reboot not covered','No household pairing, lesson or automatic-update claim') }
$root = Join-Path $env:ProgramFiles 'BodeeGuard Cloud Child'
$state = $root + '.InstallState'
try {
  if ((Test-Path $root) -or (Get-Service BodeeGuardCloudGuardian -ErrorAction SilentlyContinue)) { throw 'Fresh VM already contains BodeeGuard' }
  $file = Join-Path $env:RUNNER_TEMP ("BodeeGuard-Cloud-Child-Setup-" + $env:BG_VERSION + '.exe')
  $url = ('https://bodeeguard-cloud-assets.james-7f8.workers.dev/v1/updates/' + $env:BG_CHANNEL + '/') + [IO.Path]::GetFileName($file)
  Invoke-WebRequest -UseBasicParsing -Uri $url -UserAgent 'BodeeGuard-ReleaseVerifier/1.0' -OutFile $file -TimeoutSec 180
  if ((Get-Item $file).Length -ne $receipt.size -or (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $receipt.sha256) { throw 'Downloaded installer differs from exact build receipt' }
  Write-Host 'Verified exact public installer bytes.'

  # GitHub uses an elevated administrative desktop. Create a disposable standard
  # desktop using loopback RDP, then transfer it to the console for the REAL
  # service's WTS launch. Do not replace, patch or mock product code or IPC.
  $testUser = 'bgaccept'
  $testPassword = 'Bg!' + [Guid]::NewGuid().ToString('N') + 'a7'
  Write-Host "::add-mask::$testPassword"
  New-LocalUser -Name $testUser -Password (ConvertTo-SecureString $testPassword -AsPlainText -Force) -AccountNeverExpires | Out-Null
  Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $testUser
  Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $testUser
  if (@(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object Name -EQ "$env:COMPUTERNAME\$testUser").Count -ne 0) { throw 'Test desktop must not be administrator' }
  # Keep external RDP blocked: only this VM's loopback client is used.
  Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 0
  New-NetFirewallRule -DisplayName 'BodeeGuard acceptance loopback only' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -LocalAddress 127.0.0.0/8 -RemoteAddress 127.0.0.0/8 | Out-Null
  Start-Service TermService
  Get-NetTCPConnection -LocalPort 3389 -State Listen | Select-Object LocalAddress,LocalPort | ConvertTo-Json | Set-Content (Join-Path $out 'rdp-listener.json')
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public sealed class BgRdpHost : AxHost {
 public BgRdpHost(string clsid) : base(clsid) {} public object Client { get { return GetOcx(); } }
}
public static class BgWindow {
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,System.Text.StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
 public static string Text(IntPtr h) {var s=new System.Text.StringBuilder(512);GetWindowText(h,s,512);return s.ToString();}
 public static IntPtr SetupWindow(int pid) { IntPtr found=IntPtr.Zero; EnumWindows((h,l)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==pid&&Text(h)=="BodeeGuard Setup")found=h;return true;},IntPtr.Zero);return found; }
}
"@
  $clsid = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\MsRDP.MsRDP.9\CLSID').'(default)'
  $form = New-Object Windows.Forms.Form
  $form.Width=1024; $form.Height=768
  $rdp = New-Object BgRdpHost($clsid)
  $rdp.Dock='Fill'; $form.Controls.Add($rdp); $form.Show()
  $client=$rdp.Client
  $client.Server='127.0.0.2'; $client.Domain=$env:COMPUTERNAME; $client.UserName=$testUser
  $client.DesktopWidth=1280; $client.DesktopHeight=800
  $client.AdvancedSettings9.AuthenticationLevel=0
  $client.AdvancedSettings9.EnableCredSspSupport=$true
  $client.AdvancedSettings9.ClearTextPassword=$testPassword
  $client.Connect()
  $desktopSession=$null
  $deadline=(Get-Date).AddSeconds(90)
  do {
    [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500
    foreach ($explorer in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'")) {
      $owner=Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
      if ($owner.User -eq $testUser) { $desktopSession=[int]$explorer.SessionId; break }
    }
  } until ($null -ne $desktopSession -or (Get-Date) -gt $deadline)
  if ($null -eq $desktopSession) {
    @{connected=$client.Connected;extendedDisconnectReason=$client.ExtendedDisconnectReason} | ConvertTo-Json | Set-Content (Join-Path $out 'rdp-client.json')
    & query user 2>&1 | Out-File (Join-Path $out 'desktop-sessions.txt')
    foreach ($log in @('Microsoft-Windows-TerminalServices-LocalSessionManager/Operational','Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational','Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational')) {
      Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=(Get-Date).AddMinutes(-3)} -MaxEvents 12 -ErrorAction SilentlyContinue | Select-Object Id,Message | ConvertTo-Json -Depth 4 | Out-File (Join-Path $out (($log -replace '[^a-zA-Z0-9]','-') + '.json'))
    }
    & secedit /export /cfg (Join-Path $env:RUNNER_TEMP 'rights.inf') /areas USER_RIGHTS | Out-Null
    Select-String -Path (Join-Path $env:RUNNER_TEMP 'rights.inf') -Pattern 'RemoteInteractiveLogonRight' | ForEach-Object Line | Set-Content (Join-Path $out 'remote-logon-rights.txt')
    Add-Type -AssemblyName System.Drawing
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save((Join-Path $out 'desktop-preparation.png'));$bitmap.Dispose()
    throw 'Could not establish standard-user desktop in disposable VM'
  }
  & "$env:SystemRoot\System32\tscon.exe" $desktopSession /dest:console "/password:$testPassword"
  if ($LASTEXITCODE -ne 0) { throw 'Could not transfer disposable desktop to console' }
  $form.Close()
  if ([BgWindow]::WTSGetActiveConsoleSessionId() -ne $desktopSession) { throw 'Standard user is not active console' }
  Write-Host 'Standard-user console ready; beginning actual setup wizard.'

  function Invoke-Installer([string]$stage) {
    # GUI installer; /S is reserved for authentic signed automatic-update tickets.
    $proc=Start-Process -FilePath $file -PassThru -WindowStyle Hidden
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $clicked=@()
    while (!$proc.HasExited -and $watch.Elapsed.TotalSeconds -lt 240) {
      $window=[BgWindow]::SetupWindow($proc.Id)
      if ($window -ne [IntPtr]::Zero) {
        $next=[BgWindow]::GetDlgItem($window,1)
        if ($next -ne [IntPtr]::Zero -and [BgWindow]::IsWindowEnabled($next)) {
          $text=[BgWindow]::Text($next)
          if ($text -match '(?i)next|install|finish|close') {
            $clicked+=$text
            [BgWindow]::PostMessage($next,0xF5,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
          }
        }
      }
      Start-Sleep -Milliseconds 600
      $proc.Refresh()
    }
    if (!$proc.HasExited) { throw "$stage installer timed out; no acceptance recorded" }
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "$stage installer exited $($proc.ExitCode)" }
    $service=Get-Service BodeeGuardCloudGuardian
    if ($service.Status -ne 'Running') { throw "$stage service not running" }
    if (Test-Path (Join-Path $state 'active.json')) { throw "$stage left unfinished install transaction" }
    $commits=@(Get-ChildItem -LiteralPath $state -Filter committed.json -Recurse | Sort-Object LastWriteTimeUtc -Descending)
    if (!$commits.Count) { throw "$stage no committed install receipt" }
    $journal=Get-Content $commits[0].FullName -Raw | ConvertFrom-Json
    $healthFile=Join-Path $commits[0].DirectoryName 'health.json'
    if (!(Test-Path $healthFile)) { throw "$stage no real application-health confirmation" }
    $health=Get-Content $healthFile -Raw | ConvertFrom-Json
    if ($health.challenge -ne $journal.healthId -or $health.manifestHash -ne $journal.candidateHash) { throw "$stage mismatched app health" }
    $app=Get-Process -Id $health.processId
    if ($app.Path -ne (Join-Path $root 'BodeeGuard Cloud Child.exe') -or $app.SessionId -ne $desktopSession) { throw "$stage wrong app/session" }
    $installedVersion=(Get-Item $app.Path).VersionInfo.ProductVersion
    if ($installedVersion -ne $env:BG_VERSION) { throw "$stage wrong installed version: $installedVersion" }
    $entry=@{name=$stage;status='passed';installerExitCode=$proc.ExitCode;service='Running';applicationHealth='confirmed';standardUser=$true;installedVersion=$installedVersion;buttons=$clicked;transactionId=$journal.id}
    $receipt.checks+=$entry
    Write-Host "$stage installer committed and real app confirmed UI/storage/recovery health."
  }
  Invoke-Installer 'fresh-install'
  # This synthetic marker is not a child file; it verifies repair preserves
  # the standard user's profile. Never pair this disposable user to a family.
  $profile=Join-Path 'C:\Users' $testUser
  $marker=Join-Path $profile 'Documents\BodeeGuard-acceptance.txt'
  New-Item -ItemType Directory -Path (Split-Path $marker) -Force | Out-Null
  Set-Content -LiteralPath $marker -Value 'synthetic acceptance work; preserve during repair'
  $markerHash=(Get-FileHash $marker).Hash
  # No enrolled/locked child exists. Stop only this disposable app before repair.
  Get-Process -Name 'BodeeGuard Cloud Child' -ErrorAction SilentlyContinue | Stop-Process -Force
  Invoke-Installer 'same-version-repair'
  if ((Get-FileHash $marker).Hash -ne $markerHash) { throw 'Repair changed synthetic saved work' }
  $receipt.checks+=@{name='repair-preserves-synthetic-work';status='passed'}
  $receipt.status='passed'
} catch {
  $receipt.error=$_.Exception.Message
  Write-Host ('Acceptance failed: ' + $_.Exception.Message)
  throw
} finally {
  # Preserve only machine-install diagnostics. No accounts, secrets or pairing codes.
  if (Test-Path $state) {
    foreach ($name in @('startup.json','active.json','diagnostic-reference.json')) {
      $source=Join-Path $state $name
      if (Test-Path $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $out $name) }
    }
  }
  $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'acceptance.json') -Encoding UTF8
}
