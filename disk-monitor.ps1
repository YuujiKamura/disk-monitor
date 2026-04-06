# Disk Space Monitor — tray resident, threshold + growth alert
# Usage: powershell -WindowStyle Hidden -File disk-monitor.ps1
# Config: edit $config below

$config = @{
    ThresholdGB = 30
    GrowthAlertGB = 10      # alert if usage grows this much since last check
    CheckIntervalMin = 60   # check every N minutes
    StateFile = "$env:LOCALAPPDATA\disk-monitor-state.json"
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 4x7 pixel font (NES-style) for digits 0-9
$pixelFont = @{
    '0' = @(0x6,0x9,0x9,0x9,0x9,0x9,0x6)
    '1' = @(0x2,0x6,0x2,0x2,0x2,0x2,0x7)
    '2' = @(0x6,0x9,0x1,0x2,0x4,0x8,0xF)
    '3' = @(0x6,0x9,0x1,0x6,0x1,0x9,0x6)
    '4' = @(0x9,0x9,0x9,0xF,0x1,0x1,0x1)
    '5' = @(0xF,0x8,0xE,0x1,0x1,0x9,0x6)
    '6' = @(0x6,0x8,0xE,0x9,0x9,0x9,0x6)
    '7' = @(0xF,0x1,0x1,0x2,0x4,0x4,0x4)
    '8' = @(0x6,0x9,0x9,0x6,0x9,0x9,0x6)
    '9' = @(0x6,0x9,0x9,0x7,0x1,0x1,0x6)
}

function Draw-PixelDigit($g, $digit, $x, $y, $color) {
    $rows = $pixelFont[$digit.ToString()]
    if (-not $rows) { return }
    $brush = New-Object System.Drawing.SolidBrush($color)
    for ($row = 0; $row -lt 7; $row++) {
        for ($col = 0; $col -lt 4; $col++) {
            if ($rows[$row] -band (0x8 -shr $col)) {
                $g.FillRectangle($brush, $x + $col * 2, $y + $row * 2, 2, 2)
            }
        }
    }
    $brush.Dispose()
}

function Make-Icon($text, $color) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)

    $digits = $text.ToCharArray()
    if ($digits.Count -eq 1) {
        Draw-PixelDigit $g $digits[0] 4 1 $color
    } elseif ($digits.Count -eq 2) {
        Draw-PixelDigit $g $digits[0] 0 1 $color
        Draw-PixelDigit $g $digits[1] 8 1 $color
    } elseif ($digits.Count -ge 3) {
        # 3 digits: show first 2 + small dot (e.g. 100+ = "99+")
        Draw-PixelDigit $g $digits[0] 0 1 $color
        Draw-PixelDigit $g $digits[1] 8 1 $color
    }

    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($hIcon)
    return $ico
}

# Create tray icon
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = Make-Icon "?" ([System.Drawing.Color]::Gray)
$icon.Text = "Disk Monitor"
$icon.Visible = $true

# Context menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$checkNow = $menu.Items.Add("Check Now")
$checkNow.add_Click({ Check-Disks -Force })
$exit = $menu.Items.Add("Exit")
$exit.add_Click({ $icon.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$icon.ContextMenuStrip = $menu

# Load previous state
function Load-State {
    if (Test-Path $config.StateFile) {
        Get-Content $config.StateFile -Raw | ConvertFrom-Json
    } else {
        @{}
    }
}

function Save-State($state) {
    $state | ConvertTo-Json | Set-Content $config.StateFile -Encoding UTF8
}

function Show-Alert($title, $msg, $type) {
    # Use None icon to suppress notification sound
    $icon.BalloonTipTitle = $title
    $icon.BalloonTipText = $msg
    $icon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::None
    $icon.ShowBalloonTip(10000)
}

function Check-Disks {
    param([switch]$Force)
    $state = Load-State
    $alerts = @()
    $newState = @{}

    $allDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Free -ne $null -and ($_.Used + $_.Free) -gt 50GB }
    foreach ($drive in $allDrives) {
        $letter = $drive.Name

        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        $usedGB = [math]::Round($drive.Used / 1GB, 1)

        $newState[$letter] = @{ UsedGB = $usedGB; CheckedAt = (Get-Date -Format "o") }

        # Threshold check
        if ($freeGB -lt $config.ThresholdGB) {
            $alerts += "${letter}: Free ${freeGB}GB (threshold: $($config.ThresholdGB)GB)"
        }

        # Growth check
        $prevKey = $letter
        if ($state.PSObject -and $state.$prevKey) {
            $prevUsed = $state.$prevKey.UsedGB
            $growth = [math]::Round($usedGB - $prevUsed, 1)
            if ($growth -gt $config.GrowthAlertGB) {
                $alerts += "${letter}: +${growth}GB since last check"
            }
        }
    }

    Save-State $newState

    # Update tooltip and icon number (63 char limit)
    $tip = ($allDrives | ForEach-Object {
        "$($_.Name):$([math]::Floor($_.Free/1GB))G"
    }) -join " "
    $icon.Text = $tip.Substring(0, [math]::Min($tip.Length, 63))

    # Show C: free GB as icon number
    $cDrive = Get-PSDrive C -ErrorAction SilentlyContinue
    if ($cDrive) {
        $cFree = [math]::Min([math]::Floor($cDrive.Free / 1GB), 99)
        $color = if ($cFree -lt $config.ThresholdGB) { [System.Drawing.Color]::Red } else { [System.Drawing.Color]::LimeGreen }
        $icon.Icon = Make-Icon "$cFree" $color
    }

    if ($alerts.Count -gt 0) {
        Show-Alert "Disk Alert" ($alerts -join "`n") "warning"
    } elseif ($Force) {
        Show-Alert "Disk OK" $tip "info"
    }
}

# Initial check
Check-Disks -Force

# Timer for periodic checks
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $config.CheckIntervalMin * 60 * 1000
$timer.add_Tick({ Check-Disks })
$timer.Start()

# Run message loop
[System.Windows.Forms.Application]::Run()
