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
$receipt = [ordered]@{ schemaVersion=1; purpose='bodeeguard-real-installer-smoke'; channel=$env:BG_CHANNEL; version=$env:BG_VERSION; sha256=$env:BG_EXPECTED_SHA; size=[long]$env:BG_EXPECTED_SIZE; runUrl="https://github.com/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"; runnerImage=$env:ImageVersion; checkedAt=(Get-Date).ToUniversalTime().ToString('o'); status='failed'; checks=@(); limitations=@('Windows Server VM; Windows 10/11 physical hardware and reboot not covered','No household pairing, lesson or automatic-update claim','Hosted console belongs to the runner; app is opened in the standard user desktop, not by automatic console launch') }
$root = Join-Path $env:ProgramFiles 'BodeeGuard Cloud Child'
$state = $root + '.InstallState'
try {
  if ((Test-Path $root) -or (Get-Service BodeeGuardCloudGuardian -ErrorAction SilentlyContinue)) { throw 'Fresh VM already contains BodeeGuard' }
  $file = Join-Path $env:RUNNER_TEMP ("BodeeGuard-Cloud-Child-Setup-" + $env:BG_VERSION + '.exe')
  $url = ('https://bodeeguard-cloud-assets.james-7f8.workers.dev/v1/updates/' + $env:BG_CHANNEL + '/') + [IO.Path]::GetFileName($file)
  Invoke-WebRequest -UseBasicParsing -Uri $url -UserAgent 'BodeeGuard-ReleaseVerifier/1.0' -OutFile $file -TimeoutSec 180
  if ((Get-Item $file).Length -ne $receipt.size -or (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $receipt.sha256) { throw 'Downloaded installer differs from exact build receipt' }
  Write-Host 'Verified exact public installer bytes.'

  # Use a separate standard-user desktop. The hosted console belongs to the
  # administrative runner; opening the app here models its Start-menu launch.
  # Do not patch product files, authentication, service or installation checks.
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
public static class BgWindow {
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,uint data,IntPtr extra);
 public static void Click(int x,int y){SetCursorPos(x,y);mouse_event(2,0,0,0,IntPtr.Zero);mouse_event(4,0,0,0,IntPtr.Zero);}
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb,IntPtr l);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,System.Text.StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 public static string Text(IntPtr h) {var s=new System.Text.StringBuilder(512);GetWindowText(h,s,512);return s.ToString();}
 public static IntPtr SetupWindow(int pid) { IntPtr found=IntPtr.Zero; EnumWindows((h,l)=>{uint p;GetWindowThreadProcessId(h,out p);if(p==pid&&Text(h).Trim()=="BodeeGuard Setup")found=h;return true;},IntPtr.Zero);return found; }
}
"@
  # Use Windows' supported RDP client, with a disposable loopback credential.
  & cmdkey /generic:TERMSRV/127.0.0.2 "/user:$env:COMPUTERNAME\$testUser" "/pass:$testPassword" | Out-Null
  $rdpProcess=Start-Process -FilePath "$env:SystemRoot\System32\mstsc.exe" -ArgumentList @('/v:127.0.0.2','/w:1280','/h:800') -WindowStyle Hidden -PassThru
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $desktopSession=$null
  $deadline=(Get-Date).AddSeconds(90)
  do {
    [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 500
    $rdpControls=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,[int]$rdpProcess.Id)))
    $rdpConsent=@($rdpControls | Where-Object { $_.Current.Name -eq 'I understand and allow RDP files to open on this device for my account' })
    if ($rdpConsent.Count -eq 1) {
      $toggle=$rdpConsent[0].GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
      if ($toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) { $toggle.Toggle() }
      $okay=@($rdpControls | Where-Object { $_.Current.Name -eq 'OK' -and $_.Current.IsEnabled })
      if ($okay.Count -eq 1) { $point=$okay[0].GetClickablePoint(); [BgWindow]::Click([int]$point.X,[int]$point.Y); Write-Host 'Accepted first-use RDP prompt inside disposable VM.' }
    }
    # Trust only this disposable VM's self-signed RDP certificate, reached on
    # 127.0.0.2. No trust store or product certificate policy is changed.
    $rdpIds=@(Get-Process mstsc -ErrorAction SilentlyContinue | ForEach-Object Id)
    $desktopControls=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    $certificateControls=@($desktopControls | Where-Object { $_.Current.ProcessId -in $rdpIds })
    $names=@($certificateControls | ForEach-Object { $_.Current.Name })
    if ($names -contains 'Do you want to connect despite these certificate errors?' -and $names -contains $env:COMPUTERNAME) {
      $yes=@($certificateControls | Where-Object { $_.Current.Name -eq 'Yes' -and $_.Current.IsEnabled })
      if ($yes.Count -eq 1) { $point=$yes[0].GetClickablePoint();[BgWindow]::Click([int]$point.X,[int]$point.Y);Write-Host 'Confirmed this disposable VM certificate on loopback.' }
    }
    foreach ($explorer in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'")) {
      $owner=Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
      if ($owner.User -eq $testUser) { $desktopSession=[int]$explorer.SessionId; break }
    }
  } until ($null -ne $desktopSession -or (Get-Date) -gt $deadline)
  if ($null -eq $desktopSession) {
    Get-Process mstsc,CredentialUIBroker -ErrorAction SilentlyContinue | Select-Object Id,MainWindowTitle | ConvertTo-Json | Set-Content (Join-Path $out 'rdp-client.json')
    Add-Type -AssemblyName UIAutomationClient
    [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Select-Object -First 140 | Set-Content (Join-Path $out 'rdp-dialog.txt')
    & query user 2>&1 | Out-File (Join-Path $out 'desktop-sessions.txt')
    foreach ($log in @('Microsoft-Windows-TerminalServices-LocalSessionManager/Operational','Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational','Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational')) {
      Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=(Get-Date).AddMinutes(-3)} -MaxEvents 12 -ErrorAction SilentlyContinue | Select-Object Id,Message | ConvertTo-Json -Depth 4 | Out-File (Join-Path $out (($log -replace '[^a-zA-Z0-9]','-') + '.json'))
    }
    & secedit /export /cfg (Join-Path $env:RUNNER_TEMP 'rights.inf') /areas USER_RIGHTS | Out-Null
    Select-String -Path (Join-Path $env:RUNNER_TEMP 'rights.inf') -Pattern 'RemoteInteractiveLogonRight' | ForEach-Object Line | Set-Content (Join-Path $out 'remote-logon-rights.txt')
    throw 'Could not establish standard-user desktop in disposable VM'
  }
  & cmdkey /delete:TERMSRV/127.0.0.2 | Out-Null
  $launchAction=New-ScheduledTaskAction -Execute (Join-Path $root 'BodeeGuard Cloud Child.exe')
  $launchPrincipal=New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$testUser" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'BodeeGuardAcceptanceOpenApp' -Action $launchAction -Principal $launchPrincipal -Force | Out-Null
  Write-Host 'Standard-user desktop ready; beginning actual setup wizard.'

  function Invoke-Installer([string]$stage) {
    # GUI installer; /S is reserved for authentic signed automatic-update tickets.
    $proc=Start-Process -FilePath $file -PassThru -WindowStyle Hidden
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $clicked=@()
    $opened=$false
    while (!$proc.HasExited -and $watch.Elapsed.TotalSeconds -lt 240) {
      # Open the real installed app as this standard user, as from Start.
      # Wait until the installer has activated its actual service and health phase.
      $activePath=Join-Path $state 'active.json'
      if (!$opened -and (Test-Path $activePath)) {
        try { $pending=Get-Content $activePath -Raw | ConvertFrom-Json } catch { $pending=$null }
        $pendingService=Get-Service BodeeGuardCloudGuardian -ErrorAction SilentlyContinue
        if ($pending -and $pending.phase -eq 'health-pending' -and $pendingService -and $pendingService.Status -eq 'Running') {
          Start-ScheduledTask -TaskName 'BodeeGuardAcceptanceOpenApp'
          $opened=$true
          Write-Host "$stage opened installed app in standard-user desktop."
        }
      }
      $window=[BgWindow]::SetupWindow($proc.Id)
      if ($window -ne [IntPtr]::Zero) {
        $next=[BgWindow]::GetDlgItem($window,1)
        if ($next -ne [IntPtr]::Zero -and [BgWindow]::IsWindowEnabled($next)) {
          $text=[BgWindow]::Text($next)
          if ($text -match '(?i)next|install|finish|close') {
            $clicked+=$text
            [BgWindow]::PostMessage($window,0x111,[IntPtr]1,$next) | Out-Null
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
    $windowsProductVersion=(Get-Item $app.Path).VersionInfo.ProductVersion
    if ($windowsProductVersion -ne $env:BG_VERSION -and $windowsProductVersion -ne ($env:BG_VERSION + '.0')) { throw "$stage wrong installed version: $windowsProductVersion" }
    $installedVersion=$env:BG_VERSION
    $entry=@{name=$stage;status='passed';installerExitCode=$proc.ExitCode;service='Running';applicationHealth='confirmed';standardUser=$true;launchMode='standard-user-start-menu';installedVersion=$installedVersion;windowsProductVersion=$windowsProductVersion;buttons=$clicked;transactionId=$journal.id}
    $receipt.checks+=$entry
    Write-Host "$stage installer committed and real app confirmed UI/storage/recovery health."
  }
  Invoke-Installer 'fresh-install'
  # This synthetic marker is not a child file; it verifies repair preserves
  # the standard user's profile. Never pair this disposable user to a family.
  $profile=Join-Path 'C:\Users' $testUser
  $profileName=if ($env:BG_CHANNEL -eq 'test') { 'BodeeGuard-Cloud-Child-Validation' } else { 'BodeeGuard-Cloud-Child' }
  $marker=Join-Path $profile ("AppData\Roaming\" + $profileName + '\Acceptance\synthetic-draft.txt')
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
  Get-Process | Where-Object { $_.ProcessName -like 'BodeeGuard*' } | Select-Object Id,ProcessName,SessionId,MainWindowTitle | ConvertTo-Json | Set-Content (Join-Path $out 'test-processes.json')
  if (Test-Path $state) {
    foreach ($name in @('startup.json','active.json','diagnostic-reference.json')) {
      $source=Join-Path $state $name
      if (Test-Path $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $out $name) }
    }
  }
  $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'acceptance.json') -Encoding UTF8
}
