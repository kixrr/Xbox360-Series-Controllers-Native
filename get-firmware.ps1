# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads the Xbox Wireless Adapter firmware from Microsoft's own driver packages
# (Windows Update catalog) and saves it in Apps\xadapter\ next to this script:
# xone_dongle_02fe.bin for the slim adapter and xone_dongle_02e6.bin for the original one.
# Same sources and checksums as the Linux xone driver uses.
#
# The firmware is subject to Microsoft's Terms of Use:
# https://www.microsoft.com/en-us/legal/terms-of-use
#
# WHY OPTION [E] EXISTS: the plugin used to read the firmware file at boot, and on some
# consoles (observed on an RGH Phat Falcon, kernel 17559) that read destroyed the file's
# FATX directory entry - no delete API involved, the file simply vanished and the next
# boot had no firmware. [E] puts the slim adapter's firmware into the XAFWSLOT inside the
# xex instead: the plugin reads it from its own mapped image at start-up, with zero file
# I/O - nothing is ever opened, read or destroyed on the disk. The slot is patched on THIS
# machine; the repo and the shipped xex contain no firmware bytes.
#
# Run:  double-click get-firmware.cmd, or
#       powershell -ExecutionPolicy Bypass -File get-firmware.ps1 [-Mode Original|Embed]
param(
    [ValidateSet('Original', 'Embed', '')]
    [string]$Mode = ''
)
$ErrorActionPreference = 'Stop'

$firmware = @(
    @{ name = 'xone_dongle_02fe.bin'; adapter = 'slim adapter (045e:02fe)'; file = 'FW_ACC_00U.bin'
       hash = '48084D9FA53B9BB04358F3BB127B7495DC8F7BB0B3CA1437BD24EF2B6EABDF66'
       url  = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2017/07/1cd6a87c-623f-4407-a52d-c31be49e925c_e19f60808bdcbfbd3c3df6be3e71ffc52e43261e.cab' },
    @{ name = 'xone_dongle_02e6.bin'; adapter = 'original adapter (045e:02e6)'; file = 'FW_ACC_00U.bin'
       hash = '080CE4091E53A4EF3E5FE29939F51FD91F46D6A88BE6D67EB6E99A5723B3A223'
       url  = 'https://catalog.s.download.windowsupdate.com/d/msdownload/update/driver/drvs/2017/03/2ea9591b-f751-442c-80ce-8f4692cdc67b_6b555a3a288153cf04aec6e03cba360afe2fce34.cab' }
)
$slim_fw = Join-Path $PSScriptRoot 'Apps\xadapter\xone_dongle_02fe.bin'

# --- choose the variant (interactive when started without -Mode) ---
if (-not $Mode) {
    Write-Host ''
    Write-Host 'Adapter firmware - choose a variant:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [E] Embedded (new) -> patch the xa.xex firmware slot (XAFWSLOT): the plugin'
    Write-Host '              reads the slim adapter''s firmware from its own mapped image at'
    Write-Host '              boot - zero file I/O, no FATX risk, no loose 02fe file needed.'
    Write-Host '              (The original adapter keeps its file - the slot holds 02fe only.)'
    Write-Host ''
    Write-Host '  [O] Original -> keep one_dongle_02fe.bin next to xa.xex, exactly as always.'
    Write-Host '              Heads-up: on some consoles a firmware file read at boot loses its'
    Write-Host '              FATX directory entry (observed: RGH Phat Falcon / kernel 17559) -'
    Write-Host '              if yours vanishes, just run this again and use [E].'
    Write-Host ''
    do {
        $c = (Read-Host 'Choice [O/E]').Trim().ToUpper()
    } while ($c -notin @('O', 'E'))
    $Mode = if ($c -eq 'O') { 'Original' } else { 'Embed' }
}
Write-Host "Mode: $Mode"

$dir = Join-Path $PSScriptRoot 'Apps\xadapter'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('xadapter-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$ok = $false
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($fw in $firmware) {
        Write-Host "Downloading the firmware for the $($fw.adapter) from Microsoft..."
        $cab = Join-Path $tmp ($fw.name + '.cab')
        $out = Join-Path $tmp $fw.name
        New-Item -ItemType Directory -Path $out | Out-Null
        Invoke-WebRequest -Uri $fw.url -OutFile $cab -UseBasicParsing

        # tar.exe ships with Windows 10 1803 and later and reads CAB files
        & "$env:SystemRoot\System32\tar.exe" -xf $cab -C $out $fw.file
        if ($LASTEXITCODE -ne 0) { throw "could not extract $($fw.file) from the driver package" }

        $got = (Get-FileHash (Join-Path $out $fw.file) -Algorithm SHA256).Hash
        if ($got -ne $fw.hash) { throw "checksum mismatch for $($fw.name): $got" }

        $dest = Join-Path $dir $fw.name
        Move-Item -Force (Join-Path $out $fw.file) $dest
        Write-Host "Saved $dest"
    }
    $ok = $true
} catch {
    Write-Host "Failed: $_" -ForegroundColor Red
} finally {
    Remove-Item -Recurse -Force $tmp
}

# --- embed variant: firmware into the XAFWSLOT (memory read at boot, no file I/O) ---
$PatchedXexPath = $null
if ($ok -and $Mode -eq 'Embed') {
    # dev build first, then the shipped distribution xex (empty slot)
    $candidates = @(
        (Join-Path $PSScriptRoot 'xbox360\out\xa.xex'),
        (Join-Path $PSScriptRoot 'dist\xa.xex')
    )
    $slotPatcher = Join-Path $PSScriptRoot 'tools\patch_slot.py'
    $py = $null
    try {
        $py = (Get-Command python -ErrorAction Stop).Source
    } catch {
        Write-Host 'Patching skipped (python not found on PATH)' -ForegroundColor Yellow
    }
    if ($py -and (Test-Path $slotPatcher)) {
        foreach ($xex in $candidates) {
            if (-not (Test-Path $xex)) { continue }
            Write-Host "Patching firmware slot in $xex ..."
            & $py $slotPatcher $xex $slim_fw
            if ($LASTEXITCODE -eq 0) {
                $PatchedXexPath = $xex
                break
            }
            Write-Host "Slot patch failed (exit $LASTEXITCODE)" -ForegroundColor Yellow
        }
    } elseif (-not $py) {
        # already reported above
    } else {
        Write-Host 'Patching skipped (need tools\patch_slot.py)' -ForegroundColor Yellow
    }
    if ($PatchedXexPath) {
        Write-Host 'Patched: the firmware lives in the xex image slot - the plugin reads it' -ForegroundColor Green
        Write-Host 'from mapped memory at boot (zero file I/O, no FATX risk, no loose 02fe file).' -ForegroundColor Green
        # the slot replaces the slim adapter's file; the original adapter's file stays
        Remove-Item -Force $slim_fw -ErrorAction SilentlyContinue
        Write-Host 'Loose 02fe file removed (the slot holds it now); 02e6 file kept.' -ForegroundColor Green
    } else {
        Write-Host 'Keeping the downloaded files - use them in Original style.' -ForegroundColor Yellow
        Write-Host 'Hint: build xbox360\out\xa.xex (build.sh) or take dist\xa.xex from the' -ForegroundColor Yellow
        Write-Host '      preview branch - both carry the firmware slot to patch.' -ForegroundColor Yellow
    }
}

# keep the window open when started by double-click
if ($ok) {
    Write-Host ''
    if ($Mode -eq 'Original') {
        Write-Host 'Done. Copy the Apps folder to your console (original workflow).' -ForegroundColor Green
    } elseif ($PatchedXexPath) {
        Write-Host "Done. Copy the patched $PatchedXexPath to \Hdd1\Apps\xadapter\xa.xex on the console." -ForegroundColor Green
    } else {
        Write-Host 'Done. Copy the Apps folder to your console (patch unavailable).' -ForegroundColor Green
    }
}
Read-Host 'Press Enter to close' | Out-Null
if (-not $ok) { exit 1 }