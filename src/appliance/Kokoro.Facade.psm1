# Accessible, state-driven phone facade for the Kokoro downstream engine.
Set-StrictMode -Version Latest

function ConvertTo-KokoroFacadeColor {
    param([byte] $Red, [byte] $Green, [byte] $Blue, [byte] $Alpha = 255)
    [BitConverter]::ToInt32([byte[]]@($Blue, $Green, $Red, $Alpha), 0)
}

function Get-KokoroFacadePalette {
    [pscustomobject]@{
        Background = ConvertTo-KokoroFacadeColor 4 16 31
        Panel = ConvertTo-KokoroFacadeColor 10 28 46
        PanelRaised = ConvertTo-KokoroFacadeColor 14 39 62
        Primary = ConvertTo-KokoroFacadeColor 94 246 255
        OnPrimary = ConvertTo-KokoroFacadeColor 1 22 32
        Text = ConvertTo-KokoroFacadeColor 245 250 255
        Muted = ConvertTo-KokoroFacadeColor 184 202 219
        Ready = ConvertTo-KokoroFacadeColor 121 242 166
        Busy = ConvertTo-KokoroFacadeColor 255 209 102
        Error = ConvertTo-KokoroFacadeColor 255 107 129
    }
}

function New-KokoroFacadeState {
    param(
        [ValidateSet('Initializing', 'Ready', 'Speaking', 'Error')]
        [string] $Phase = 'Initializing',
        [ValidateLength(0, 240)][string] $Prompt = 'Waiting for a speech request.',
        [ValidateLength(0, 120)][string] $Detail = 'Kokoro engine setup',
        [ValidateRange(0.0, 1.0)][double] $Progress = 0.0,
        [ValidateLength(1, 32)][string] $ActionLabel = 'RUN SYSTEM CHECK'
    )
    [pscustomobject]@{
        Phase = $Phase
        Prompt = $Prompt
        Detail = $Detail
        Progress = $Progress
        ActionLabel = $ActionLabel
    }
}

function Get-KokoroFacadeLayout {
    param(
        [ValidateRange(320, 10000)][int] $Width,
        [ValidateRange(480, 10000)][int] $Height,
        [ValidateRange(0, 2000)][int] $InsetLeft = 0,
        [ValidateRange(0, 2000)][int] $InsetTop = 0,
        [ValidateRange(0, 2000)][int] $InsetRight = 0,
        [ValidateRange(0, 2000)][int] $InsetBottom = 0
    )
    $contentWidth = $Width - $InsetLeft - $InsetRight
    $contentHeight = $Height - $InsetTop - $InsetBottom
    if ($contentWidth -lt 320 -or $contentHeight -lt 480) {
        throw 'System insets leave insufficient facade drawing space.'
    }
    $short = [Math]::Min($contentWidth, $contentHeight)
    $margin = [Math]::Max(24, [Math]::Round($short * 0.045))
    $left = $InsetLeft + $margin
    $right = $InsetLeft + $contentWidth - $margin
    $top = $InsetTop + $margin
    $bottom = $InsetTop + $contentHeight - $margin
    $headerHeight = [Math]::Max(112, [Math]::Round($contentHeight * 0.12))
    $cardTop = $top + $headerHeight + $margin
    $buttonHeight = [Math]::Max(96, [Math]::Round($contentHeight * 0.085))
    $buttonTop = $bottom - $buttonHeight
    $cardBottom = $buttonTop - $margin
    if ($cardBottom - $cardTop -lt 220) { throw 'Facade content cards do not fit the available window.' }
    [pscustomobject]@{
        Width = $Width; Height = $Height
        Content = [pscustomobject]@{ Left = $InsetLeft; Top = $InsetTop; Right = $InsetLeft + $contentWidth; Bottom = $InsetTop + $contentHeight }
        Margin = $margin
        Header = [pscustomobject]@{ Left = $left; Top = $top; Right = $right; Bottom = $top + $headerHeight }
        Status = [pscustomobject]@{ Left = $left; Top = $cardTop; Right = $right; Bottom = $cardTop + [Math]::Round(($cardBottom - $cardTop) * 0.30) }
        Prompt = [pscustomobject]@{ Left = $left; Top = $cardTop + [Math]::Round(($cardBottom - $cardTop) * 0.30) + $margin; Right = $right; Bottom = $cardBottom }
        Action = [pscustomobject]@{ Left = $left; Top = $buttonTop; Right = $right; Bottom = $bottom }
        TitleSize = [float][Math]::Max(34, [Math]::Round($short * 0.052))
        BodySize = [float][Math]::Max(26, [Math]::Round($short * 0.036))
        LabelSize = [float][Math]::Max(22, [Math]::Round($short * 0.030))
    }
}

function Split-KokoroFacadeText {
    param([string] $Text, [ValidateRange(8, 120)][int] $MaximumCharacters)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @('') }
    $words = @($Text.Trim() -split '\s+')
    $lines = [Collections.Generic.List[string]]::new()
    $line = ''
    foreach ($word in $words) {
        $candidate = if ($line.Length -eq 0) { $word } else { $line + ' ' + $word }
        if ($candidate.Length -le $MaximumCharacters) { $line = $candidate; continue }
        if ($line.Length -gt 0) { $lines.Add($line); $line = '' }
        $remaining = $word
        while ($remaining.Length -gt $MaximumCharacters) {
            $lines.Add($remaining.Substring(0, $MaximumCharacters))
            $remaining = $remaining.Substring($MaximumCharacters)
        }
        $line = $remaining
    }
    if ($line.Length -gt 0) { $lines.Add($line) }
    @($lines)
}

function Test-KokoroFacadeHit {
    param([Parameter(Mandatory)] $Rectangle, [float] $X, [float] $Y)
    $X -ge $Rectangle.Left -and $X -le $Rectangle.Right -and
        $Y -ge $Rectangle.Top -and $Y -le $Rectangle.Bottom
}

function Add-KokoroFacadeMark {
    param([Parameter(Mandatory)][IntPtr] $Canvas, [Parameter(Mandatory)] $Box, [int] $Color)
    $size = [Math]::Min($Box.Bottom - $Box.Top, ($Box.Right - $Box.Left) * 0.22)
    $x = [float]$Box.Left
    $y = [float]($Box.Top + (($Box.Bottom - $Box.Top - $size) / 2))
    $unit = [float]($size / 7)
    Add-CanvasRect $Canvas ($x + 2*$unit) $y ($x + 5*$unit) ($y + $unit) -Color $Color
    Add-CanvasRect $Canvas $x ($y + 2*$unit) ($x + 2*$unit) ($y + 5*$unit) -Color $Color
    Add-CanvasRect $Canvas ($x + 5*$unit) ($y + 2*$unit) ($x + 7*$unit) ($y + 5*$unit) -Color $Color
    Add-CanvasRect $Canvas ($x + 2*$unit) ($y + 6*$unit) ($x + 5*$unit) ($y + 7*$unit) -Color $Color
}

function Write-KokoroFacadeFrame {
    param(
        [Parameter(Mandatory)][IntPtr] $Canvas,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Layout
    )
    $palette = Get-KokoroFacadePalette
    Clear-Canvas $Canvas -Color $palette.Background
    Add-KokoroFacadeMark -Canvas $Canvas -Box $Layout.Header -Color $palette.Primary
    $titleX = [float]($Layout.Header.Left + (($Layout.Header.Bottom - $Layout.Header.Top) * 0.27))
    Add-CanvasText $Canvas 'KOKORO' $titleX ([float]($Layout.Header.Top + $Layout.TitleSize)) $Layout.TitleSize -Color $palette.Text
    Add-CanvasText $Canvas 'HEXAGON SPEECH ENGINE' $titleX ([float]($Layout.Header.Top + $Layout.TitleSize + $Layout.LabelSize + 12)) $Layout.LabelSize -Color $palette.Muted

    Add-CanvasRect $Canvas $Layout.Status.Left $Layout.Status.Top $Layout.Status.Right $Layout.Status.Bottom -Color $palette.Panel
    $phaseColor = switch ($State.Phase) { 'Ready' { $palette.Ready } 'Speaking' { $palette.Busy } 'Error' { $palette.Error } default { $palette.Primary } }
    $pad = [float]($Layout.Margin * 0.70)
    Add-CanvasText $Canvas ([string]$State.Phase).ToUpperInvariant() ([float]($Layout.Status.Left + $pad)) ([float]($Layout.Status.Top + $pad + $Layout.BodySize)) $Layout.BodySize -Color $phaseColor
    Add-CanvasText $Canvas ([string]$State.Detail) ([float]($Layout.Status.Left + $pad)) ([float]($Layout.Status.Bottom - $pad)) $Layout.LabelSize -Color $palette.Muted
    $progressRight = [float]($Layout.Status.Left + (($Layout.Status.Right - $Layout.Status.Left) * [double]$State.Progress))
    Add-CanvasRect $Canvas $Layout.Status.Left ([float]($Layout.Status.Bottom - 8)) $progressRight $Layout.Status.Bottom -Color $phaseColor

    Add-CanvasRect $Canvas $Layout.Prompt.Left $Layout.Prompt.Top $Layout.Prompt.Right $Layout.Prompt.Bottom -Color $palette.PanelRaised
    Add-CanvasText $Canvas 'CURRENT UTTERANCE' ([float]($Layout.Prompt.Left + $pad)) ([float]($Layout.Prompt.Top + $pad + $Layout.LabelSize)) $Layout.LabelSize -Color $palette.Primary
    $characters = [Math]::Max(12, [Math]::Floor(($Layout.Prompt.Right - $Layout.Prompt.Left - 2*$pad) / ($Layout.BodySize * 0.62)))
    $lineY = [float]($Layout.Prompt.Top + 2*$pad + $Layout.LabelSize + $Layout.BodySize)
    $lineStep = [float]($Layout.BodySize * 1.35)
    foreach ($line in @(Split-KokoroFacadeText -Text ([string]$State.Prompt) -MaximumCharacters $characters)) {
        if ($lineY -gt $Layout.Prompt.Bottom - $pad) { break }
        Add-CanvasText $Canvas $line ([float]($Layout.Prompt.Left + $pad)) $lineY $Layout.BodySize -Color $palette.Text
        $lineY += $lineStep
    }

    Add-CanvasRect $Canvas $Layout.Action.Left $Layout.Action.Top $Layout.Action.Right $Layout.Action.Bottom -Color $palette.Primary
    $labelWidth = ([string]$State.ActionLabel).Length * $Layout.LabelSize * 0.61
    Add-CanvasText $Canvas ([string]$State.ActionLabel) ([float](($Layout.Action.Left + $Layout.Action.Right - $labelWidth) / 2)) ([float]($Layout.Action.Top + (($Layout.Action.Bottom - $Layout.Action.Top + $Layout.LabelSize) / 2))) $Layout.LabelSize -Color $palette.OnPrimary
}

function Start-KokoroFacade {
    param(
        [Parameter(Mandatory)][IntPtr] $NativeActivity,
        [Parameter(Mandatory)][string] $AndroidCanvasModulePath,
        [scriptblock] $OnActivate = {},
        $InitialState = (New-KokoroFacadeState)
    )
    $binding = (Resolve-Path -LiteralPath $AndroidCanvasModulePath).Path
    Import-Module $binding -Force -ErrorAction Stop
    Initialize-AndroidCanvas -NativeActivity $NativeActivity
    $shared = @{ State = $InitialState; Layout = $null }
    $draw = {
        param([IntPtr] $Canvas)
        $size = Get-CanvasSize -Canvas $Canvas
        $insets = Get-SystemBarInsets
        $shared.Layout = Get-KokoroFacadeLayout -Width $size.Width -Height $size.Height `
            -InsetLeft $insets.Left -InsetTop $insets.Top -InsetRight $insets.Right -InsetBottom $insets.Bottom
        Write-KokoroFacadeFrame -Canvas $Canvas -State $shared.State -Layout $shared.Layout
    }.GetNewClosure()
    Register-WindowDrawHandler -Draw $draw
    Register-InputHandler -Handle {
        param($Event)
        if ($Event.Type -ceq 'motion' -and $Event.Action -eq 1 -and $null -ne $shared.Layout -and
            (Test-KokoroFacadeHit -Rectangle $shared.Layout.Action -X $Event.X -Y $Event.Y)) {
            Invoke-HapticFeedback -Constant 1
            & $OnActivate $shared.State
            return $true
        }
        $false
    }.GetNewClosure() -AfterInput { Request-WindowDraw }
    [pscustomobject]@{
        GetState = { $shared.State }.GetNewClosure()
        SetState = {
            param($NextState)
            if ($null -eq $NextState -or [string]$NextState.Phase -notin @('Initializing','Ready','Speaking','Error')) {
                throw 'Invalid Kokoro facade state.'
            }
            $shared.State = New-KokoroFacadeState -Phase ([string]$NextState.Phase) `
                -Prompt ([string]$NextState.Prompt) -Detail ([string]$NextState.Detail) `
                -Progress ([double]$NextState.Progress) -ActionLabel ([string]$NextState.ActionLabel)
            Request-WindowDraw
        }.GetNewClosure()
        RequestDraw = { Request-WindowDraw }.GetNewClosure()
    }
}

Export-ModuleMember -Function Get-KokoroFacadePalette, New-KokoroFacadeState,
    Get-KokoroFacadeLayout, Split-KokoroFacadeText, Test-KokoroFacadeHit,
    Write-KokoroFacadeFrame, Start-KokoroFacade
