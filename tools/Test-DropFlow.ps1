# One real user flow in a signed-in session: classic Outlook starts with the add-in, an e-mail
# is dragged with the mouse onto tools/drop-inspector.html in Edge, and what the page read is
# compared with the add-in's own log and the file it wrote.
#
# Runs under Windows PowerShell in the interactive session (deploy.just, lab-flow). The mouse
# is the real one: SendInput presses, moves and releases it, so nobody may be using the desktop.
#
#   -Hook on    the add-in as installed. PASS needs every check below.
#   -Hook off   the control: HKCU EnableHook=0. PASS needs the add-in to stay out of the drag.
#
# Prints one VERDICT line. flow.json in -Work holds the whole record, flow.png the screen
# as it stood when the page had answered.
param(
    [string] $Page = 'C:\ProgramData\ofd-probe\drop-inspector.html',
    [string] $Work = (Join-Path $env:LOCALAPPDATA 'ofd-flow'),
    [string] $MailProfile = 'OFD Flow',
    [ValidateSet('on', 'off')] [string] $Hook = 'on',
    # The file version OutlookFileDrag.dll must have, e.g. 1.0.14.0. Empty accepts any.
    [string] $WantFileVersion = '',
    [int] $Port = 9333
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Drawing, System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OfdUi {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint msg, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr obj, int index, StringBuilder buffer, int length, out int needed);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);

    // The desktop that receives input now: "Default" when signed in and unlocked.
    public static string InputDesktop() {
        IntPtr d = OpenInputDesktop(0, false, 0x0001);
        if (d == IntPtr.Zero) return "";
        try {
            StringBuilder name = new StringBuilder(256);
            int needed;
            return GetUserObjectInformation(d, 2, name, name.Capacity * 2, out needed) ? name.ToString() : "";
        } finally { CloseDesktop(d); }
    }
    static uint Send(uint flags, int dx, int dy) {
        INPUT[] one = new INPUT[1];
        one[0].type = 0;
        one[0].mi.dx = dx; one[0].mi.dy = dy; one[0].mi.dwFlags = flags;
        return SendInput(1, one, Marshal.SizeOf(typeof(INPUT)));
    }
    public static uint Move(int x, int y) {
        int left = GetSystemMetrics(76), top = GetSystemMetrics(77), width = GetSystemMetrics(78), height = GetSystemMetrics(79);
        int nx = (int)Math.Round((x - left) * 65535.0 / (width - 1));
        int ny = (int)Math.Round((y - top) * 65535.0 / (height - 1));
        return Send(0x0001 | 0x8000 | 0x4000, nx, ny);
    }
    public static uint Down() { return Send(0x0002, 0, 0); }
    public static uint Up() { return Send(0x0004, 0, 0); }
    public static bool ButtonIsDown() { return (GetAsyncKeyState(0x01) & 0x8000) != 0; }
    // Returns once the window's thread has taken a message from its queue.
    public static bool Pump(IntPtr window) {
        IntPtr result;
        return SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 0x0002, 5000, out result) != IntPtr.Zero;
    }
}
'@

New-Item -ItemType Directory -Force -Path $Work | Out-Null
# An earlier run's record and picture must not be read as this run's.
foreach ($old in 'flow.json', 'flow.png') { Remove-Item -LiteralPath (Join-Path $Work $old) -Force -ErrorAction SilentlyContinue }
$record = [ordered]@{
    hook = $Hook; computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"
    started = (Get-Date).ToUniversalTime().ToString('o'); steps = @(); checks = [ordered]@{}
}
$script:outlook = $null
# The process Wait-Until waits on between attempts: Edge until Outlook starts, then Outlook.
$script:pace = $null
$subjectPrefix = 'OFD flow '
$script:outlookWindow = [IntPtr]::Zero
$script:cdpId = 0
$script:nudge = 0

function Step([string] $Text) {
    $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $Text
    $record.steps += $line
    $line
}

# Repeats a test until it answers. Between attempts it waits on Outlook's process handle, so
# an Outlook that exits ends the wait at once; the attempts are counted and running out throws.
function Wait-Until([scriptblock] $Test, [string] $Waiting, [int] $Attempts = 80, [int] $PaceMs = 250) {
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        $answer = & $Test
        if ($answer) { return $answer }
        if ($script:pace.WaitForExit($PaceMs)) { throw "process $($script:pace.Id) exited while waiting for: $Waiting" }
    }
    throw "gave up after $Attempts attempts waiting for: $Waiting"
}

$uia = [Windows.Automation.AutomationElement]
$scope = [Windows.Automation.TreeScope]
function New-Is($Property, $Value) { New-Object Windows.Automation.PropertyCondition($Property, $Value) }
function New-Both($A, $B) { New-Object Windows.Automation.AndCondition($A, $B) }

function Get-OutlookWindow([int] $ProcessId) {
    $uia::RootElement.FindFirst($scope::Children, (New-Both (New-Is $uia::ProcessIdProperty $ProcessId) (New-Is $uia::ClassNameProperty 'rctrl_renwnd32')))
}

# Office's own surfaces over Outlook: the boxes (sign-in, licence notice, privacy notice) and
# the tips it points at parts of the window ("New location for Outlook modules and apps"),
# which sit on top of the message list.
function Get-OfficePrompts([int] $ProcessId) {
    $kind = New-Object Windows.Automation.OrCondition((New-Is $uia::ClassNameProperty 'NUIDialog'), (New-Is $uia::ClassNameProperty 'NetUIBeakToolWindow'))
    @($uia::RootElement.FindAll($scope::Descendants, (New-Both (New-Is $uia::ProcessIdProperty $ProcessId) $kind)))
}

function Close-OfficePrompt($Dialog) {
    $name = $Dialog.Current.Name
    foreach ($press in @(@([Windows.Automation.ControlType]::Hyperlink, 'Skip for now'), @([Windows.Automation.ControlType]::Button, 'Close'), @([Windows.Automation.ControlType]::Button, 'Got it'))) {
        $element = $Dialog.FindFirst($scope::Descendants, (New-Both (New-Is $uia::ControlTypeProperty $press[0]) (New-Is $uia::NameProperty $press[1])))
        $pattern = $null
        if ($element -and $element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref] $pattern)) { $pattern.Invoke(); return "$name ($($press[1]))" }
    }
    $pattern = $null
    if ($Dialog.TryGetCurrentPattern([Windows.Automation.WindowPattern]::Pattern, [ref] $pattern)) { $pattern.Close(); return "$name (window closed)" }
    throw "Office shows '$name' and offers nothing this test knows how to press"
}

# Dismisses the boxes one at a time. After each, Outlook either opens the next or takes input
# again; that is waited for before looking for another.
function Clear-OfficePrompts([int] $ProcessId, $Window) {
    $closed = @()
    for ($round = 0; $round -lt 8; $round++) {
        $open = @(Get-OfficePrompts $ProcessId)
        if (-not $open.Count) { return $closed }
        $id = $open[0].GetRuntimeId() -join '.'
        $closed += Close-OfficePrompt $open[0]
        [void] (Wait-Until -Waiting "Outlook to move on from '$($closed[-1])'" -Test {
            $still = @(Get-OfficePrompts $ProcessId)
            $same = @($still | Where-Object { ($_.GetRuntimeId() -join '.') -eq $id })
            (-not $same.Count) -and ($still.Count -or (-not $Window) -or $Window.Current.IsEnabled)
        })
    }
    throw "Office kept opening boxes: $($closed -join ', ')"
}

# Closes an Outlook the way a person would; a box left open over it is dismissed first.
function Close-Outlook($Process) {
    $before = $script:pace
    $script:pace = $Process
    try {
        [void] @(Clear-OfficePrompts $Process.Id (Get-OutlookWindow $Process.Id))
        [void] $Process.CloseMainWindow()
        if (-not $Process.WaitForExit(60000)) { $Process.Kill(); [void] $Process.WaitForExit(15000); Step "Outlook $($Process.Id) did not close in 60 s and was ended" }
    } finally { $script:pace = $before }
}

function Save-Screen {
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $shot = New-Object Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($shot)
    try {
        $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
        $shot.Save((Join-Path $Work 'flow.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $shot.Dispose() }
}

function Split-Lines([string] $Text) {
    @($Text.Split([string[]] @("`r`n", "`n"), [StringSplitOptions]::RemoveEmptyEntries))
}

function Read-Shared([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
}

function Open-Cdp {
    $target = Wait-Until -Waiting 'the drop page to open in Edge' -Test {
        try {
            # Assigned before it is piped: Windows PowerShell hands a JSON array down the pipeline whole.
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 5
            $pages = @($targets | Where-Object { $_.type -eq 'page' })
            if (@($pages | Where-Object { $_.url -like 'edge://force-signin*' }).Count) {
                throw 'Edge opened its forced sign-in page in place of the drop page: policy BrowserSignin is 2 on this machine and nobody is signed in to Edge'
            }
            @($pages | Where-Object { $_.url -like '*drop-inspector.html*' })[0]
        } catch [System.Net.WebException] { $null }
    }
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    if (-not $socket.ConnectAsync([Uri] $target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(10000)) {
        throw "no DevTools connection to $($target.url)"
    }
    $socket
}

# One DevTools call. A reply that does not come within the limit is a TimeoutException.
function Invoke-Cdp($Socket, [string] $Method, [hashtable] $Params = @{}, [int] $TimeoutMs = 30000) {
    $script:cdpId++
    $id = $script:cdpId
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress))
    $none = [Threading.CancellationToken]::None
    $out = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
    if (-not $Socket.SendAsync($out, 'Text', $true, $none).Wait($TimeoutMs)) { throw (New-Object TimeoutException "DevTools did not take $Method") }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $buffer = New-Object byte[] 65536
    while ($true) {
        $message = New-Object IO.MemoryStream
        do {
            $left = $TimeoutMs - [int] $clock.ElapsedMilliseconds
            if ($left -le 0) { throw (New-Object TimeoutException "DevTools did not answer $Method in $TimeoutMs ms") }
            $task = $Socket.ReceiveAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buffer)), $none)
            if (-not $task.Wait($left)) { throw (New-Object TimeoutException "DevTools did not answer $Method in $TimeoutMs ms") }
            $message.Write($buffer, 0, $task.Result.Count)
        } while (-not $task.Result.EndOfMessage)
        $reply = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
        if ($reply.id -eq $id) {
            if ($reply.error) { throw "DevTools $Method failed: $($reply.error.message)" }
            return $reply.result
        }
    }
}

function Invoke-Js($Socket, [string] $Expression, [switch] $Await, [int] $TimeoutMs = 30000) {
    $r = Invoke-Cdp $Socket 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true; awaitPromise = [bool] $Await } $TimeoutMs
    if ($r.exceptionDetails) { throw "page script failed: $($r.exceptionDetails.text) $($r.exceptionDetails.exception.description)" }
    $r.result.value
}

# One mouse event, then wait until Windows reports it and Outlook's window thread has run.
function Send-Mouse([string] $What, [int] $X = 0, [int] $Y = 0) {
    switch ($What) {
        'move' { if ([OfdUi]::Move($X, $Y) -ne 1) { throw "SendInput refused a move to $X,$Y" } }
        'down' { if ([OfdUi]::Down() -ne 1) { throw 'SendInput refused the button press' } }
        'up'   { if ([OfdUi]::Up() -ne 1) { throw 'SendInput refused the button release' } }
    }
    [void] (Wait-Until -Waiting "the mouse to report '$What' $X,$Y" -Attempts 200 -PaceMs 10 -Test {
        switch ($What) {
            'move' { $p = New-Object OfdUi+POINT; [void] [OfdUi]::GetCursorPos([ref] $p); ([Math]::Abs($p.X - $X) -le 1 -and [Math]::Abs($p.Y - $Y) -le 1) }
            'down' { [OfdUi]::ButtonIsDown() }
            'up'   { -not [OfdUi]::ButtonIsDown() }
        }
    })
    if ($script:outlookWindow -ne [IntPtr]::Zero) {
        if (-not ([OfdUi]::Pump($script:outlookWindow) -and [OfdUi]::Pump($script:outlookWindow))) { throw "Outlook's window stopped answering during '$What'" }
    }
}

$socket = $null; $edge = $null; $ol = $null
$hookKey = 'HKCU:\Software\OutlookFileDrag'
$pageState = '({ dropped: false, status: document.getElementById("status").className, statusText: document.getElementById("status").textContent, log: document.getElementById("log").textContent })'
try {
    [void] [OfdUi]::SetProcessDPIAware()
    $desktop = [OfdUi]::InputDesktop()
    if ($desktop -ne 'Default') { throw "the input desktop is '$desktop': the session is locked, disconnected or on the secure desktop" }
    $screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $half = [int] ($screen.Width / 2)
    $tall = $screen.Height - 48
    Step "session $($record.user) on $($record.computer), screen $($screen.Width)x$($screen.Height), hook $Hook"

    $outlookExe = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE').'(default)'
    $edgeExe = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe').'(default)'
    $addinLog = Join-Path $env:APPDATA 'OutlookFileDrag\OutlookFileDrag.log'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) 'OutlookFileDrag'
    $edgeData = Join-Path $Work 'edge'

    # A previous run's Outlook and test browser.
    foreach ($p in @(Get-Process OUTLOOK -ErrorAction SilentlyContinue)) { Close-Outlook $p }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$edgeData*" })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }

    # Edge first: a machine that forces browser sign-in shows that here, before anything else runs.
    $edge = Start-Process -FilePath $edgeExe -PassThru -ArgumentList @(
        "--user-data-dir=`"$edgeData`"", '--no-first-run', '--no-default-browser-check', "--remote-debugging-port=$Port",
        '--new-window', "--window-position=$half,0", "--window-size=$half,$tall", ([Uri] $Page).AbsoluteUri)
    $script:pace = $edge
    [void] $edge.WaitForInputIdle(60000)
    $socket = Open-Cdp
    $record.browser = (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 5).Browser
    $title = Invoke-Js $socket 'new Promise(r => document.readyState === "complete" ? r(document.title) : window.addEventListener("load", () => r(document.title)))' -Await
    Step "$($record.browser) shows '$title'"

    if ($Hook -eq 'off') {
        New-Item $hookKey -Force | Out-Null
        Set-ItemProperty $hookKey EnableHook 0 -Type DWord
    } elseif (Test-Path $hookKey) {
        Remove-ItemProperty $hookKey EnableHook -ErrorAction SilentlyContinue
    }

    # /PIM makes a profile with a data file and no mail account; the item below lives in it.
    $logBefore = (Read-Shared $addinLog).Length
    $switch = '/PIM'
    if (Test-Path "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\$MailProfile") { $switch = '/profile' }
    $script:outlook = Start-Process -FilePath $outlookExe -ArgumentList $switch, "`"$MailProfile`"" -PassThru
    $script:pace = $script:outlook
    if (-not $script:outlook.WaitForInputIdle(180000)) { throw 'Outlook did not finish starting in 180 s' }

    # Office with no account signed in puts a sign-in box over Outlook some seconds after every
    # start, a licence and a privacy notice behind it, and tips over the window. When the title
    # bar already shows its Sign in button, the box is waited for; the button can also arrive
    # after this look, so its absence proves nothing and the boxes are cleared again before the
    # first automation call answers and before the drag. This comes before anything is asked of
    # Outlook: with a box up it does not answer automation at all (CO_E_SERVER_EXEC_FAILURE),
    # which is how a profile's first start failed.
    $main = Wait-Until -Waiting 'the Outlook window' -Attempts 240 -Test { Get-OutlookWindow $script:outlook.Id }
    $script:outlookWindow = [IntPtr] $main.Current.NativeWindowHandle
    [void] (Wait-Until -Waiting "Outlook's title bar" -Attempts 240 -Test { $main.FindFirst($scope::Descendants, (New-Is $uia::ClassNameProperty 'NetUISimpleButton')) })
    $signInShown = [bool] $main.FindFirst($scope::Descendants, (New-Both (New-Is $uia::ClassNameProperty 'NetUISimpleButton') (New-Is $uia::NameProperty 'Sign in')))
    if ($signInShown) {
        [void] (Wait-Until -Waiting "Office's sign-in box (the title bar offers Sign in)" -Attempts 120 -PaceMs 1000 -Test {
            @(Get-OfficePrompts $script:outlook.Id).Count
        })
    }
    $record.officePrompts = @(Clear-OfficePrompts $script:outlook.Id $main)
    Step "title bar offered Sign in at start: $signInShown; boxes dismissed: $($record.officePrompts -join ', ')"

    $ol = Wait-Until -Waiting 'Outlook to answer automation' -Attempts 4 -Test {
        try { New-Object -ComObject Outlook.Application }
        catch [Runtime.InteropServices.COMException] {
            # A box opened since; it goes, and Outlook is asked again.
            $record.officePrompts += @(Clear-OfficePrompts $script:outlook.Id $main)
            $null
        }
    }
    $ns = $ol.GetNamespace('MAPI')
    Step "Outlook $($ol.Version) pid $($script:outlook.Id), profile '$($ns.CurrentProfileName)'"
    $record.outlookVersion = $ol.Version

    $addin = $null
    foreach ($a in $ol.COMAddIns) { if ($a.ProgId -eq 'OutlookFileDrag') { $addin = $a } }
    $record.checks['add-in registered with Outlook'] = [bool] $addin
    $record.checks['add-in connected'] = [bool] ($addin -and $addin.Connect)
    if (-not ($addin -and $addin.Connect)) { throw 'Outlook did not load the OutlookFileDrag add-in' }

    $startup = Wait-Until -Waiting 'the add-in to log its startup' -Test {
        $text = Read-Shared $addinLog
        if ($text.Length -le $logBefore) { return $null }
        $new = $text.Substring($logBefore)
        if ($new.Contains('import slot') -or $new.Contains('EnableHook=false')) { $new }
    }
    $record.addinStartup = Split-Lines $startup
    $versionLine = "$(@($record.addinStartup | Where-Object { $_.Contains(' - Version: ') })[-1])"
    $record.addinVersion = $versionLine.Substring($versionLine.IndexOf(' - Version: ') + 12).Trim()
    # The assembly itself, by path, file version and hash: what ties this run to one build.
    # Outlook's module list names it when the loader mapped it; otherwise the registration does.
    $script:outlook.Refresh()
    $module = @($script:outlook.Modules | Where-Object { $_.ModuleName -eq 'OutlookFileDrag.dll' })[0]
    $dll = $null
    $from = 'the modules Outlook has loaded'
    if ($module) { $dll = $module.FileName }
    else {
        $from = 'the registered manifest'
        $manifest = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\OutlookFileDrag').Manifest
        $dll = Join-Path (Split-Path -Parent ([Uri] $manifest.Split('|')[0]).LocalPath) 'OutlookFileDrag.dll'
    }
    $record.addinFile = [ordered]@{
        path        = $dll
        from        = $from
        fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion
        sha256      = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Step "add-in connected, logged version $($record.addinVersion); $dll is file version $($record.addinFile.fileVersion) (from $from)"
    if ($WantFileVersion) { $record.checks["OutlookFileDrag.dll is file version $WantFileVersion"] = ($record.addinFile.fileVersion -eq $WantFileVersion) }
    $redirected = @($record.addinStartup | Where-Object { $_.Contains('Redirected ') -and $_.Contains('import slot') }).Count -gt 0
    $disabled = @($record.addinStartup | Where-Object { $_.Contains('EnableHook=false') }).Count -gt 0
    if ($Hook -eq 'on') { $record.checks['add-in installed its drag hook at startup'] = $redirected }
    else { $record.checks['add-in logged that its hook is switched off'] = ($disabled -and -not $redirected) }

    # The item to drag: a saved e-mail with an attachment, in the Inbox of the data file.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $subject = "$subjectPrefix$stamp"
    $attachment = Join-Path $Work 'flow-attachment.txt'
    Set-Content -LiteralPath $attachment -Value "Outlook File Drag flow test $stamp" -Encoding ASCII
    $inbox = $ns.GetDefaultFolder(6)
    $draft = $ol.CreateItem(0)
    $draft.Subject = $subject
    $draft.Body = "Dragged by tools/Test-DropFlow.ps1 at $stamp."
    [void] $draft.Attachments.Add($attachment)
    $draft.Save()
    [void] $draft.Move($inbox)
    $record.subject = $subject

    $explorer = $ol.ActiveExplorer()
    if (-not $explorer) { throw 'Outlook has no folder window' }
    $explorer.CurrentFolder = $inbox
    $explorer.WindowState = 2
    $explorer.Left = 0; $explorer.Top = 0; $explorer.Width = $half; $explorer.Height = $tall
    $explorer.Activate()
    Step "Outlook window '$($explorer.Caption)' on the left half"

    # Where the drop zone is on the screen: the web area's own window gives the origin, the
    # page gives the zone inside it.
    $web = Wait-Until -Waiting "Edge's web area" -Test {
        $edge.Refresh()
        if ($edge.MainWindowHandle -eq [IntPtr]::Zero) { return $null }
        $h = [OfdUi]::FindWindowEx($edge.MainWindowHandle, [IntPtr]::Zero, 'Chrome_RenderWidgetHostHWND', [NullString]::Value)
        if ($h -ne [IntPtr]::Zero) { $h }
    }
    $origin = New-Object OfdUi+RECT
    [void] [OfdUi]::GetWindowRect($web, [ref] $origin)
    $zone = Invoke-Js $socket '(() => { const r = document.getElementById("zone").getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, scale: window.devicePixelRatio }; })()'
    $toX = [int] ($origin.Left + $zone.x * $zone.scale)
    $toY = [int] ($origin.Top + $zone.y * $zone.scale)

    # Where the e-mail's row is: Outlook's own accessibility tree.
    $isRow = New-Is $uia::ControlTypeProperty ([Windows.Automation.ControlType]::DataItem)
    try {
        $row = Wait-Until -Waiting "the row for '$subject' in the message list" -Test {
            @($main.FindAll($scope::Descendants, $isRow) | Where-Object { $_.Current.Name -like "*$subject*" })[0]
        }
    } catch {
        # What the window does expose, for whoever reads the failure: every row it lists, and
        # anything of any kind under that subject.
        $record.rowsListed = @($main.FindAll($scope::Descendants, $isRow) | ForEach-Object { "$($_.Current.ClassName): $($_.Current.Name)" })
        $record.rowsSeen = @($main.FindAll($scope::Descendants, [Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.Name -like "*$subject*" } |
            ForEach-Object { "$($_.Current.ControlType.ProgrammaticName) $($_.Current.ClassName): $($_.Current.Name)" })
        $record.inboxSubjects = @($inbox.Items | ForEach-Object { "$($_.Subject)" })
        $record.explorerFolder = "$($explorer.CurrentFolder.FolderPath) view=$($explorer.CurrentView.Name) state=$($explorer.WindowState)"
        throw
    }
    $late = @(Clear-OfficePrompts $script:outlook.Id $main)
    if ($late.Count) { $record.officePrompts += $late; Step "boxes dismissed before the drag: $($late -join ', ')" }
    # Nothing may sit on the row where the mouse will press. Whatever Windows reports at that
    # point is followed up to Outlook's window; another window on the way is a cover.
    $mainId = $main.GetRuntimeId() -join '.'
    $walker = [Windows.Automation.TreeWalker]::RawViewWalker
    for ($e = $uia::FromPoint((New-Object Windows.Point($fromX, $fromY))); $e; $e = $walker.GetParent($e)) {
        if (($e.GetRuntimeId() -join '.') -eq $mainId) { break }
        if ($e.Current.ControlType -eq [Windows.Automation.ControlType]::Window) {
            throw "the e-mail's row is covered at $fromX,$fromY by $($e.Current.ClassName): $($e.Current.Name)"
        }
    }
    $box = $row.Current.BoundingRectangle
    $fromX = [int] ($box.Left + [Math]::Min($box.Width / 3, 150))
    $fromY = [int] ($box.Top + $box.Height / 2)
    Step "row at $fromX,$fromY ($([int] $box.Width)x$([int] $box.Height)); drop zone at $toX,$toY"
    $record.from = "$fromX,$fromY"; $record.to = "$toX,$toY"

    # The page answers through this promise: what its drop event carried, the bytes read from
    # each file, and the page's own status and log once it has settled on green or red.
    [void] (Invoke-Js $socket @'
window.__flow = new Promise(resolve => {
  const zone = document.getElementById('zone');
  const status = document.getElementById('status');
  const hex = b => Array.from(new Uint8Array(b)).map(x => x.toString(16).padStart(2, '0')).join('');
  zone.addEventListener('drop', e => {
    const types = Array.from(e.dataTransfer.types || []);
    const files = Array.from(e.dataTransfer.files || []);
    const settled = new Promise(done => {
      const look = () => { if (status.className === 'ok' || status.className === 'no') { done(); return true; } return false; };
      if (!look()) new MutationObserver((m, o) => { if (look()) o.disconnect(); }).observe(status, { attributes: true, childList: true, characterData: true, subtree: true });
    });
    Promise.all(files.map(async f => {
      const buf = await f.arrayBuffer();
      return { name: f.name, size: f.size, read: buf.byteLength, head: hex(buf.slice(0, 8)), sha256: hex(await crypto.subtle.digest('SHA-256', buf)) };
    })).then(read => settled.then(() => read), err => [{ error: String(err) }])
      .then(read => resolve({ dropped: true, types, files: read, status: status.className, statusText: status.textContent, log: document.getElementById('log').textContent }));
  }, { capture: true, once: true });
});
'armed'
'@)
    $dragStart = Get-Date
    $logAtDrag = (Read-Shared $addinLog).Length

    [void] [OfdUi]::SetForegroundWindow($script:outlookWindow)
    Send-Mouse move $fromX $fromY
    Send-Mouse down
    $over = $false
    try {
        $steps = 30
        for ($i = 1; $i -le $steps; $i++) {
            Send-Mouse move ([int] ($fromX + ($toX - $fromX) * $i / $steps)) ([int] ($fromY + ($toY - $fromY) * $i / $steps))
        }
        # The page marks its zone while a drag is over it; nudging the pointer keeps dragover coming.
        [void] (Wait-Until -Waiting 'the page to see a drag over its drop zone' -Attempts 40 -Test {
            $script:nudge = 1 - $script:nudge
            Send-Mouse move ($toX + $script:nudge) $toY
            Invoke-Js $socket 'document.getElementById("zone").classList.contains("hot")'
        })
        $over = $true
    } finally {
        Send-Mouse up
    }
    Step "button released over the drop zone (page saw the drag: $over)"

    $seen = $null
    try { $seen = Invoke-Js $socket 'window.__flow' -Await -TimeoutMs 20000 }
    catch [TimeoutException] { Step 'the page reported no drop within 20 s' }
    if (-not $seen) { $seen = Invoke-Js $socket $pageState }
    $record.page = $seen
    Step "page: dropped=$($seen.dropped) status='$($seen.statusText)'"

    Save-Screen

    $record.addinDrag = Split-Lines (Read-Shared $addinLog).Substring($logAtDrag)
    $written = @()
    if (Test-Path -LiteralPath $tempRoot) {
        $written = @(Get-ChildItem -LiteralPath $tempRoot -Recurse -File | Where-Object { $_.LastWriteTime -ge $dragStart } | ForEach-Object {
            [ordered]@{ path = $_.FullName; size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
    }
    $record.addinFiles = $written

    # The add-in names the real file itself (ReplaceSpecialChars in its App.config), so the name
    # the page must show is the name of the file the add-in wrote, not the subject.
    $got = @($seen.files)
    $logged = { param($text) @($record.addinDrag | Where-Object { $_.Contains($text) }).Count -gt 0 }
    if ($Hook -eq 'on') {
        $record.checks['add-in logged the drag'] = (& $logged 'Drag started')
        $record.checks['add-in found the e-mail as a virtual file and added a real one'] = ((& $logged 'Virtual files found') -and (& $logged "Files: $subject.msg"))
        $record.checks['add-in wrote one file to its temp folder'] = ($written.Count -eq 1)
        $record.checks['add-in logged a completed copy drop (effect 1)'] = (& $logged 'DoDragDrop effect: 1 ')
        $record.checks['page received a drop of one file'] = [bool] ($seen.dropped -and $got.Count -eq 1)
        $same = [bool] ($written.Count -eq 1 -and $got.Count -eq 1)
        $record.checks['page shows the file under the name the add-in gave it'] = ($same -and $got[0].name -eq (Split-Path -Leaf $written[0].path))
        $record.checks['page read the file as an Outlook message (OLE header d0cf11e0)'] = [bool] ($got.Count -eq 1 -and $got[0].read -gt 0 -and "$($got[0].head)".StartsWith('d0cf11e0'))
        $record.checks['the bytes the page read are the file the add-in wrote (SHA-256)'] = ($same -and $got[0].sha256 -eq $written[0].sha256)
        $record.checks['page status is green'] = ($seen.status -eq 'ok')
    } else {
        $record.checks['add-in stayed out of the drag (no log line)'] = ($record.addinDrag.Count -eq 0)
        $record.checks['add-in wrote no file'] = ($written.Count -eq 0)
        $record.withoutAddin = "page received a drop: $([bool] $seen.dropped); files: $($got.Count); status: $($seen.statusText)"
    }
}
catch {
    $record.error = "$($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]"
    Step "ERROR $($record.error)"
    # The screen and Outlook's windows as the failure left them, before anything is closed.
    try {
        Save-Screen
        if ($script:outlook -and -not $script:outlook.HasExited) {
            $record.windowsAtError = @($uia::RootElement.FindAll($scope::Descendants, (New-Is $uia::ProcessIdProperty $script:outlook.Id)) |
                Where-Object { $_.Current.ControlType -eq [Windows.Automation.ControlType]::Window } |
                ForEach-Object { "$($_.Current.ClassName) enabled=$($_.Current.IsEnabled): $($_.Current.Name)" })
        }
    } catch { Step "could not record the failure state: $($_.Exception.Message)" }
}
finally {
    if ([OfdUi]::ButtonIsDown()) { [void] [OfdUi]::Up() }
    if (Test-Path $hookKey) { Remove-ItemProperty $hookKey EnableHook -ErrorAction SilentlyContinue }
    try {
        if ($ol) {
            # Every e-mail this test ever left in the Inbox, this run's included.
            $left = $ol.GetNamespace('MAPI').GetDefaultFolder(6).Items
            for ($n = $left.Count; $n -ge 1; $n--) { $item = $left.Item($n); if ("$($item.Subject)".StartsWith($subjectPrefix)) { $item.Delete() } }
        }
    } catch { Step "could not delete the test e-mail: $($_.Exception.Message)" }
    try { if ($socket) { [void] (Invoke-Cdp $socket 'Browser.close' @{} 5000) } } catch { Step "Edge did not take the close: $($_.Exception.Message)" }
    if ($edge -and -not $edge.WaitForExit(15000)) { Stop-Process -Id $edge.Id -Force -ErrorAction SilentlyContinue }
    try { if ($script:outlook -and -not $script:outlook.HasExited) { Close-Outlook $script:outlook } } catch { Step "Outlook did not close: $($_.Exception.Message)" }

    $failed = @($record.checks.Keys | Where-Object { -not $record.checks[$_] })
    $verdict = 'FAIL'
    if (-not $record.error -and $record.checks.Count -gt 0 -and $failed.Count -eq 0) { $verdict = 'PASS' }
    $record.verdict = $verdict
    $record.finished = (Get-Date).ToUniversalTime().ToString('o')
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Work 'flow.json') -Encoding UTF8
    foreach ($k in $record.checks.Keys) { '  [{0}] {1}' -f $(if ($record.checks[$k]) { 'ok' } else { 'NO' }), $k }
    if ($record.page) { "  page status: $($record.page.statusText)" }
    foreach ($l in @($record.addinDrag)) { "  add-in: $l" }
    $why = ''
    if ($record.error) { $why = "error: $($record.error)" } elseif ($failed) { $why = "failed: $($failed -join '; ')" }
    "VERDICT: $verdict hook=$Hook file-version=$($record.addinFile.fileVersion) sha256=$($record.addinFile.sha256) $why"
}
