$ErrorActionPreference = 'Stop'

if ($global:KokoroAoa -and -not $global:KokoroAoa[2].IsCompleted) {
    [void][Android.Util.Log]::Info('KokoroAoa', 'AOA APPLIANCE REUSED')
    return
}

if ($global:KokoroAoa) {
    try { $global:KokoroAoa[1].Dispose() } catch {}
    try { $global:KokoroAoa[0].Dispose() } catch {}
    $global:KokoroAoa = $null
}

$aoaWorker = {
    param($Activity)

    $ErrorActionPreference = 'Stop'
    $manager = [Android.Hardware.Usb.UsbManager]$Activity.GetSystemService(
        [Android.Content.Context]::UsbService
    )

    [void][Android.Util.Log]::Info(
        'KokoroAoa',
        "AOA APPLIANCE ARMED PID=$([Environment]::ProcessId)"
    )

    [bool]$reportedAccessoryState = $false
    while ($true) {
        $pfd = $null
        $input = $null
        $output = $null

        try {
            $accessories = @($manager.AccessoryList)
            if (-not $reportedAccessoryState) {
                [void][Android.Util.Log]::Info(
                    'KokoroAoa',
                    "AOA ACCESSORY COUNT=$($accessories.Count) FIRST_NULL=$($null -eq $accessories[0])"
                )
                $reportedAccessoryState = $true
            }
            if ($accessories.Count -eq 0 -or $null -eq $accessories[0]) {
                [Threading.Thread]::Sleep(100)
                continue
            }

            $accessory = $accessories[0]
            if (-not $manager.HasPermission($accessory)) {
                [void][Android.Util.Log]::Warn('KokoroAoa', 'AOA WAITING FOR ACCESSORY PERMISSION')
                [Threading.Thread]::Sleep(500)
                continue
            }

            $pfd = $manager.OpenAccessory($accessory)
            if ($null -eq $pfd) {
                throw 'OpenAccessory returned null.'
            }

            $input = [Java.IO.FileInputStream]::new($pfd.FileDescriptor)
            $output = [Java.IO.FileOutputStream]::new($pfd.FileDescriptor)

            [void][Android.Util.Log]::Info(
                'KokoroAoa',
                "AOA APPLIANCE READY FD=$($pfd.Fd)"
            )

            while ($true) {
                [byte[]]$header = [byte[]]::new(4)
                [int]$offset = 0
                while ($offset -lt 4) {
                    [int]$n = $input.Read($header, $offset, 4 - $offset)
                    if ($n -lt 0) { throw 'AOA disconnected while reading a frame header.' }
                    if ($n -eq 0) { continue }
                    $offset += $n
                }

                [uint32]$length = [BitConverter]::ToUInt32($header, 0)
                if ($length -gt 262144) {
                    throw "AOA control frame is $length bytes; maximum is 262144."
                }

                [byte[]]$payload = [byte[]]::new([int]$length)
                $offset = 0
                while ($offset -lt $payload.Length) {
                    [int]$n = $input.Read($payload, $offset, $payload.Length - $offset)
                    if ($n -lt 0) { throw 'AOA disconnected while reading a frame body.' }
                    if ($n -eq 0) { continue }
                    $offset += $n
                }

                $document = $null
                try {
                    $document = [System.Text.Json.JsonDocument]::Parse($payload)
                    $request = $document.RootElement
                    [int]$schema = $request.GetProperty('schema').GetInt32()
                    [string]$id = $request.GetProperty('id').GetString()
                    [string]$operation = $request.GetProperty('operation').GetString()
                    if ($schema -ne 1) { throw "Unsupported AOA schema $schema." }
                    if ($id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid request id.' }

                    [string]$dataJson = switch ($operation) {
                        'status' {
                            '{"protocol":"kokoro-aoa/1","pid":' + [Environment]::ProcessId + ',"operations":["status","ping","receipt"],"speakReady":false}'
                            break
                        }
                        'ping' {
                            $nonce = $request.GetProperty('payload').GetProperty('nonce').GetString()
                            if ($null -eq $nonce -or $nonce.Length -gt 128) { throw 'Ping nonce is missing or too long.' }
                            $nonceJson = [System.Text.Json.JsonSerializer]::Serialize([object]$nonce, [Type][string], $null)
                            '{"nonce":' + $nonceJson + '}'
                            break
                        }
                        'receipt' {
                            $receiptPath = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl', 'receipt.txt')
                            [string]$receipt = if ([IO.File]::Exists($receiptPath)) { [IO.File]::ReadAllText($receiptPath) } else { '' }
                            if ($receipt.Length -gt 65536) { throw 'Receipt exceeds 65536 characters.' }
                            $receiptJson = [System.Text.Json.JsonSerializer]::Serialize([object]$receipt, [Type][string], $null)
                            '{"receipt":' + $receiptJson + '}'
                            break
                        }
                        default { throw "Operation '$operation' is not admitted." }
                    }
                    $idJson = [System.Text.Json.JsonSerializer]::Serialize([object]$id, [Type][string], $null)
                    $replyJson = '{"schema":1,"id":' + $idJson + ',"ok":true,"data":' + $dataJson + '}'
                }
                catch {
                    $errorText = "$(($_.Exception.GetType()).FullName): $($_.Exception.Message)"
                    $errorJson = [System.Text.Json.JsonSerializer]::Serialize([object]$errorText, [Type][string], $null)
                    $replyJson = '{"schema":1,"ok":false,"error":' + $errorJson + '}'
                }
                finally {
                    if ($null -ne $document) { $document.Dispose() }
                }

                [byte[]]$body = [Text.Encoding]::UTF8.GetBytes($replyJson)
                [byte[]]$replyHeader = [BitConverter]::GetBytes([uint32]$body.Length)
                $output.Write($replyHeader, 0, $replyHeader.Length)
                if ($body.Length -gt 0) {
                    $output.Write($body, 0, $body.Length)
                }
                $output.Flush()
            }
        }
        catch {
            [void][Android.Util.Log]::Error(
                'KokoroAoa',
                "AOA APPLIANCE $($_.Exception.Message)"
            )
            [Threading.Thread]::Sleep(250)
        }
        finally {
            try { $input.Dispose() } catch {}
            try { $output.Dispose() } catch {}
            try { $pfd.Close() } catch {}
        }
    }
}

$initial = [System.Management.Automation.Runspaces.InitialSessionState]::Create()
$initial.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
$initial.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread

$runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initial)
$runspace.Open()

$powershell = [System.Management.Automation.PowerShell]::Create()
$powershell.Runspace = $runspace
[void]$powershell.AddScript($aoaWorker.ToString()).AddArgument($Activity)
$async = $powershell.BeginInvoke()

$global:KokoroAoa = @($runspace, $powershell, $async)
