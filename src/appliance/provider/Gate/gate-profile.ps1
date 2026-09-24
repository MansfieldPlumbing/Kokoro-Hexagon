$global:KokoroProviderHandle = {
    param([string] $Text)
    ,([Text.Encoding]::UTF8.GetBytes($Text.ToUpperInvariant()))
}
