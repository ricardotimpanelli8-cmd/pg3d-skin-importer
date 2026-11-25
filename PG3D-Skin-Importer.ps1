<#
  Skin Importer for Pixel Gun 3D (PC / Steam) - v2
  Start it with "PG3D Skin Importer.cmd". Windows PowerShell 5.1 + WPF, nothing to install.

  Where skins go: Pixel Gun 3D still loads "local skins" (kept on this PC, shown with a phone icon in
  Wear > Skins) from two Unity PlayerPrefs values under HKCU\Software\Pixel Gun Team\Pixel Gun 3D:
    User Skins_h1196497400       {"<id>":"<base64 64x32 PNG>", ...}
    User Name Skins_h1318731231  {"<id>":"<name>", ...}
  Both are UTF-8 JSON + NUL stored as REG_BINARY. Ids are .NET DateTime ticks, never in the future
  (ids near the 64-bit limit are reported to break creating new skins in-game).
  Opening a local skin in the in-game Skin Editor and saving it makes the game upload it to the account.

  Account skins live on the game's servers; the registry only caches them in
  CustomSkin_Slot_Nov2018_h4263895761 ({"<id>":{"c":<base64 PNG>,"h":..,"n":<name>}}), which the game
  rewrites from the server at every login - so this tool only ever reads that one.
  The game writes its prefs back when it exits, so it must be closed while we write.

  Web: skins can come from a Minecraft username (Mojang's public profile API), a MinecraftSkins.net skin page
  ("<page>/download" is the raw PNG) or any direct PNG link. Sites that refuse app requests (The Skindex,
  NameMC, Planet Minecraft, NovaSkin) are opened in the browser instead, and new skin-sized PNGs that land in
  Downloads are queued automatically. App data (backups, settings) lives in %LOCALAPPDATA%\PG3D Skin Importer.
  Build-Exe.ps1 packs this script into a standalone .exe.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:RegKeyPath  = 'Software\Pixel Gun Team\Pixel Gun 3D'
$script:SkinsKey    = 'User Skins'
$script:NamesKey    = 'User Name Skins'
$script:CloudKey    = 'CustomSkin_Slot_Nov2018'
$script:GameProcess = 'Pixel Gun 3D'
$script:DataDir     = Join-Path $env:LOCALAPPDATA 'PG3D Skin Importer'   # same place whether run from the .exe or the .ps1
$script:BackupDir   = Join-Path $script:DataDir 'backups'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:Version     = '2.1'
$script:Dash        = [string][char]0x2014
$script:Times       = [string][char]0x00D7
$script:Arrow       = [string][char]0x2192
$script:Bullet      = [string][char]0x2022
$script:GameRunningMessage = 'Close Pixel Gun 3D first. It rewrites its saved skins when it exits, which would undo the change.'

# Faces (x, y, w, h) of the 64x32 layout that the game draws: head, then leg, body, arm.
$script:HeadRects = @(8, 0, 16, 8), @(0, 8, 32, 8)
$script:LimbRects = @(4, 16, 8, 4), @(0, 20, 16, 12), @(20, 16, 16, 4), @(16, 20, 24, 12), @(44, 16, 8, 4), @(40, 20, 16, 12)

# ================================================================ pixels (BGRA byte arrays)

function New-Canvas([int]$w, [int]$h) {
  [pscustomobject]@{ W = $w; H = $h; Px = (New-Object byte[] ($w * $h * 4)) }
}

function Copy-Canvas($img) {
  $copy = New-Canvas $img.W $img.H
  [Array]::Copy($img.Px, $copy.Px, $img.Px.Length)
  $copy
}

function Read-Pixels([byte[]]$bytes) {
  $options = [Windows.Media.Imaging.BitmapCreateOptions]'IgnoreColorProfile, PreservePixelFormat'
  $frame = [Windows.Media.Imaging.BitmapDecoder]::Create([IO.MemoryStream]::new($bytes), $options, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad).Frames[0]
  $bgra = [Windows.Media.Imaging.FormatConvertedBitmap]::new($frame, [Windows.Media.PixelFormats]::Bgra32, $null, 0)
  $img = New-Canvas $bgra.PixelWidth $bgra.PixelHeight
  $bgra.CopyPixels($img.Px, $img.W * 4, 0)
  $img
}

function ConvertTo-Bitmap($img) {
  [Windows.Media.Imaging.BitmapSource]::Create($img.W, $img.H, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $img.Px, $img.W * 4)
}

function ConvertTo-UpscaledBitmap($img, [int]$factor) {
  $bitmap = ConvertTo-Bitmap (Resize-Nearest $img $factor)
  $bitmap.Freeze()
  $bitmap
}

function Resize-Nearest($img, [int]$factor) {
  # Every pixel becomes a factor x factor block, so later smoothing (3D texture filtering, icons) can't blur the pixel art.
  $out = New-Canvas ($img.W * $factor) ($img.H * $factor)
  $rowBytes = $out.W * 4; $block = $factor * 4
  $row = New-Object byte[] $rowBytes
  for ($y = 0; $y -lt $img.H; $y++) {
    for ($x = 0; $x -lt $img.W; $x++) {
      $d = $x * $block
      [Array]::Copy($img.Px, ($y * $img.W + $x) * 4, $row, $d, 4)
      for ($n = 4; $n -lt $block; $n *= 2) { [Array]::Copy($row, $d, $row, $d + $n, [Math]::Min($n, $block - $n)) }
    }
    for ($r = 0; $r -lt $factor; $r++) { [Array]::Copy($row, 0, $out.Px, ($y * $factor + $r) * $rowBytes, $rowBytes) }
  }
  $out
}

function ConvertTo-Png($img) {
  $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
  $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create((ConvertTo-Bitmap $img)))
  $stream = [IO.MemoryStream]::new()
  $encoder.Save($stream)
  , $stream.ToArray()
}

function Copy-Rect($src, [int]$sx, [int]$sy, $dst, [int]$dx, [int]$dy, [int]$w, [int]$h, [switch]$FlipX) {
  for ($y = 0; $y -lt $h; $y++) {
    $srow = (($sy + $y) * $src.W + $sx) * 4
    $drow = (($dy + $y) * $dst.W + $dx) * 4
    if (-not $FlipX) { [Array]::Copy($src.Px, $srow, $dst.Px, $drow, $w * 4); continue }
    for ($x = 0; $x -lt $w; $x++) { [Array]::Copy($src.Px, $srow + ($w - 1 - $x) * 4, $dst.Px, $drow + $x * 4, 4) }
  }
}

function Get-AlphaRange($img, [int]$x0, [int]$y0, [int]$w, [int]$h) {
  $min = 255; $max = 0
  for ($y = $y0; $y -lt $y0 + $h; $y++) {
    for ($x = $x0; $x -lt $x0 + $w; $x++) {
      $a = $img.Px[($y * $img.W + $x) * 4 + 3]
      if ($a -lt $min) { $min = $a }
      if ($a -gt $max) { $max = $a }
    }
  }
  @{ Min = $min; Max = $max }
}

function Merge-Overlay($img, [int]$ox, [int]$oy, [int]$bx, [int]$by, [int]$w, [int]$h) {
  # Paints an outer-layer area onto the base layer (normal alpha blending). Returns how many pixels it painted.
  $p = $img.Px; $painted = 0
  for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
      $o = (($oy + $y) * $img.W + $ox + $x) * 4
      $a = [int]$p[$o + 3]
      if ($a -eq 0) { continue }
      $b = (($by + $y) * $img.W + $bx + $x) * 4
      for ($c = 0; $c -lt 3; $c++) { $p[$b + $c] = [byte][Math]::Round(($p[$o + $c] * $a + $p[$b + $c] * (255 - $a)) / 255) }
      $p[$b + 3] = 255
      $painted++
    }
  }
  $painted
}

function Set-Opaque($img, $r) {
  for ($y = $r[1]; $y -lt $r[1] + $r[3]; $y++) {
    for ($x = $r[0]; $x -lt $r[0] + $r[2]; $x++) { $img.Px[($y * $img.W + $x) * 4 + 3] = 255 }
  }
}

# ================================================================ skin conversion

function Convert-SlimArm($img) {
  # Slim (Alex) arms are 3px wide but the 64x32 layout only has 4px arms, so the middle column is repeated.
  $src = Copy-Canvas $img
  $widen = 0, 1, 1, 2
  foreach ($f in @(44, 44, 16, 4), @(47, 48, 16, 4), @(44, 44, 20, 12), @(51, 52, 20, 12)) {   # top, bottom, front, back: srcX, dstX, y, h
    for ($i = 0; $i -lt 4; $i++) { Copy-Rect $src ($f[0] + $widen[$i]) $f[2] $img ($f[1] + $i) $f[2] 1 $f[3] }
  }
  Copy-Rect $src 47 20 $img 48 20 4 12   # inner side moves one column right
}

function Convert-ToPg3dSkin($source) {
  $w = $source.W; $h = $source.H
  $size = "$w$($script:Times)$h"
  if ($w -lt 64 -or $w % 64 -ne 0 -or ($h -ne $w -and $h * 2 -ne $w)) {
    throw "the image is $size, but a skin has to be 64$($script:Times)32 or 64$($script:Times)64 (or an HD size like 128$($script:Times)128)."
  }
  $notes = New-Object Collections.Generic.List[string]
  $img = Copy-Canvas $source
  if ($w -gt 64) {
    # HD skin: keep the centre pixel of each block
    $f = [int]($w / 64); $c = [int][Math]::Floor($f / 2)
    $small = New-Canvas 64 ([int]($h / $f))
    for ($y = 0; $y -lt $small.H; $y++) {
      for ($x = 0; $x -lt 64; $x++) { [Array]::Copy($img.Px, (($y * $f + $c) * $w + $x * $f + $c) * 4, $small.Px, ($y * 64 + $x) * 4, 4) }
    }
    $img = $small
    $notes.Add('scaled the HD skin down to 64px')
  }
  $modern = $img.H -eq 64
  $slim = $modern -and ((Get-AlphaRange $img 50 16 2 4).Max -eq 0) -and ((Get-AlphaRange $img 54 20 2 12).Max -eq 0)

  # Old editors filled the unused hat area with a solid colour. Minecraft ignores a hat area without
  # any see-through pixels, so we do too; otherwise the hat layer is painted onto the head.
  if ((Get-AlphaRange $img 32 0 32 16).Min -lt 128) {
    $painted = 0
    foreach ($r in $script:HeadRects) { $painted += Merge-Overlay $img ($r[0] + 32) $r[1] $r[0] $r[1] $r[2] $r[3] }
    if ($painted) { $notes.Add('flattened the hat layer onto the head') }
  }
  if ($modern) {
    # 64x64 skins keep a 2nd layer for legs, body and arms 16px further down; Pixel Gun 3D has none.
    $painted = 0
    foreach ($r in $script:LimbRects) { $painted += Merge-Overlay $img $r[0] ($r[1] + 16) $r[0] $r[1] $r[2] $r[3] }
    if ($painted) { $notes.Add('flattened the 2nd layer (jacket, sleeves, trousers)') }
    if ($slim) { Convert-SlimArm $img; $notes.Add('widened the slim 3px arms to 4px') }
    # Pixel Gun 3D draws the top face of the arms mirrored compared with Minecraft.
    Copy-Rect (Copy-Canvas $img) 44 16 $img 44 16 4 4 -FlipX
    $notes.Add('mirrored the shoulder tops the way Pixel Gun 3D draws them')
    $notes.Add('left arm and leg reuse the right ones (game limitation)')
  }

  $out = New-Canvas 64 32
  foreach ($r in $script:HeadRects + $script:LimbRects) {
    Copy-Rect $img $r[0] $r[1] $out $r[0] $r[1] $r[2] $r[3]
    # A 64x64 file can only be a Minecraft skin, and Minecraft draws the base layer fully opaque.
    # 64x32 files may be Pixel Gun 3D's own skins, so they keep their alpha untouched.
    if ($modern) { Set-Opaque $out $r }
  }

  $kind = if ($slim) { 'Minecraft skin, slim arms' } elseif ($modern) { 'Minecraft skin' } else { 'Pixel Gun 3D / classic skin' }
  if (-not $notes.Count) { $notes.Add('already in the Pixel Gun 3D format - imported as is') }
  [pscustomobject]@{ Skin = $out; Kind = $kind; Size = $size; Notes = $notes.ToArray() }
}

function New-Doll($skin, [switch]$Back) {
  # Flat 16x32 front or back view. The left arm and leg are mirrored copies of the right ones.
  $d = New-Canvas 16 32
  if (-not $Back) {
    Copy-Rect $skin 8 8 $d 4 0 8 8
    Copy-Rect $skin 20 20 $d 4 8 8 12
    Copy-Rect $skin 44 20 $d 0 8 4 12
    Copy-Rect $skin 44 20 $d 12 8 4 12 -FlipX
    Copy-Rect $skin 4 20 $d 4 20 4 12
    Copy-Rect $skin 4 20 $d 8 20 4 12 -FlipX
  } else {
    Copy-Rect $skin 24 8 $d 4 0 8 8
    Copy-Rect $skin 32 20 $d 4 8 8 12
    Copy-Rect $skin 52 20 $d 0 8 4 12 -FlipX
    Copy-Rect $skin 52 20 $d 12 8 4 12
    Copy-Rect $skin 12 20 $d 4 20 4 12 -FlipX
    Copy-Rect $skin 12 20 $d 8 20 4 12
  }
  $d
}

# ================================================================ 3D preview

function Add-Box($mesh, [double]$x0, [double]$y0, [double]$z0, [int]$w, [int]$h, [int]$d, [int]$u, [int]$v, [switch]$Mirror, [switch]$FlipTop) {
  # Minecraft-style box: each face lists its corners as seen from outside (top-left, top-right,
  # bottom-right, bottom-left) followed by its texture rectangle in skin pixels.
  $x1 = $x0 + $w; $y1 = $y0 + $h; $z1 = $z0 + $d
  $faces = @(
    @($x0, $y1, $z1, $x1, $y1, $z1, $x1, $y0, $z1, $x0, $y0, $z1, ($u + $d), ($v + $d), ($u + $d + $w), ($v + $d + $h)),                     # front
    @($x1, $y1, $z0, $x0, $y1, $z0, $x0, $y0, $z0, $x1, $y0, $z0, ($u + 2 * $d + $w), ($v + $d), ($u + 2 * $d + 2 * $w), ($v + $d + $h)),     # back
    @($x0, $y1, $z0, $x0, $y1, $z1, $x0, $y0, $z1, $x0, $y0, $z0, $u, ($v + $d), ($u + $d), ($v + $d + $h)),                                 # right side
    @($x1, $y1, $z1, $x1, $y1, $z0, $x1, $y0, $z0, $x1, $y0, $z1, ($u + $d + $w), ($v + $d), ($u + 2 * $d + $w), ($v + $d + $h)),             # left side
    @($x0, $y1, $z0, $x1, $y1, $z0, $x1, $y1, $z1, $x0, $y1, $z1, ($u + $d), $v, ($u + $d + $w), ($v + $d)),                                 # top
    @($x0, $y0, $z1, $x1, $y0, $z1, $x1, $y0, $z0, $x0, $y0, $z0, ($u + $d + $w), $v, ($u + $d + 2 * $w), ($v + $d))                          # bottom
  )
  for ($k = 0; $k -lt 6; $k++) {
    $f = $faces[$k]
    $i = $mesh.Positions.Count
    for ($c = 0; $c -lt 4; $c++) {
      $px = $f[$c * 3]; if ($Mirror) { $px = -$px }   # left limbs are mirror images of the right ones
      $mesh.Positions.Add([Windows.Media.Media3D.Point3D]::new($px, $f[$c * 3 + 1], $f[$c * 3 + 2]))
    }
    $u0 = $f[12] / 64; $v0 = $f[13] / 32; $u1 = $f[14] / 64; $v1 = $f[15] / 32
    if ($FlipTop -and $k -eq 4) { $t = $u0; $u0 = $u1; $u1 = $t }
    foreach ($uv in @($u0, $v0), @($u1, $v0), @($u1, $v1), @($u0, $v1)) { $mesh.TextureCoordinates.Add([Windows.Point]::new($uv[0], $uv[1])) }
    $tri = if ($Mirror) { 0, 2, 3, 0, 1, 2 } else { 0, 3, 2, 0, 2, 1 }   # mirroring flips the winding
    foreach ($t in $tri) { $mesh.TriangleIndices.Add($i + $t) }
  }
}

function New-SkinModel($skin) {
  $mesh = New-Object Windows.Media.Media3D.MeshGeometry3D
  Add-Box $mesh -4 8 -4 8 8 8 0 0                              # head
  Add-Box $mesh -4 -4 -2 8 12 4 16 16                          # body
  Add-Box $mesh -8 -4 -2 4 12 4 40 16 -FlipTop                 # right arm (Pixel Gun 3D mirrors the arm tops)
  Add-Box $mesh -8 -4 -2 4 12 4 40 16 -FlipTop -Mirror         # left arm
  Add-Box $mesh -4 -16 -2 4 12 4 0 16                          # right leg
  Add-Box $mesh -4 -16 -2 4 12 4 0 16 -Mirror                  # left leg
  $mesh.Freeze()
  $brush = New-Object Windows.Media.ImageBrush (ConvertTo-UpscaledBitmap $skin 8)
  # Absolute 0..1 viewport: otherwise WPF stretches the texture over the bounding box of the used coordinates.
  $brush.ViewportUnits = 'Absolute'
  $brush.Viewport = [Windows.Rect]::new(0, 0, 1, 1)
  [Windows.Media.RenderOptions]::SetBitmapScalingMode($brush, 'NearestNeighbor')
  $brush.Freeze()
  New-Object Windows.Media.Media3D.GeometryModel3D $mesh, (New-Object Windows.Media.Media3D.DiffuseMaterial $brush)
}

# ================================================================ game data

function Test-GameRunning { [bool](Get-Process -Name $script:GameProcess -ErrorAction SilentlyContinue) }

function Get-UnityPrefName([string]$key) {
  # Unity names each PlayerPrefs registry value "<key>_h<hash>" (djb2, xor variant, 32-bit).
  [uint64]$hash = 5381
  foreach ($ch in $key.ToCharArray()) { $hash = (($hash * [uint64]33) -band [uint64]4294967295) -bxor [uint64][int]$ch }
  '{0}_h{1}' -f $key, $hash
}

function Get-TicksDate([string]$id) {
  $ticks = 0L
  if ([long]::TryParse($id, [ref]$ticks) -and $ticks -gt 0 -and $ticks -le [DateTime]::MaxValue.Ticks) { New-Object DateTime $ticks }
}

function Read-PrefText([string]$key) {
  # One PlayerPrefs string. Text is $null when the value doesn't exist yet.
  $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RegKeyPath)
  if (-not $rk) { throw "Couldn't find Pixel Gun 3D's data. Start the game once on this PC first." }
  try {
    $name = $rk.GetValueNames() | Where-Object { $_ -like "$($key)_h*" } | Select-Object -First 1
    if (-not $name) { $name = Get-UnityPrefName $key }
    $raw = $rk.GetValue($name)
    $kind = $null; $text = $null
    if ($null -ne $raw) {
      $kind = $rk.GetValueKind($name)
      # Unity writes UTF-8 bytes; some other tools write plain strings - accept both.
      $text = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw).TrimEnd([char]0) } else { [string]$raw }
    }
    [pscustomobject]@{ Name = $name; Text = $text; Kind = $kind; Raw = $raw }
  } finally { $rk.Close() }
}

function Read-PrefMap([string]$key) {
  $map = [ordered]@{}
  $text = (Read-PrefText $key).Text
  if ($text -and $text.Trim()) {
    foreach ($p in ($text | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
  }
  $map
}

function ConvertTo-JsonText([string]$s) {
  if ($s -notmatch '["\\\x00-\x1f]') { return $s }
  $sb = New-Object Text.StringBuilder
  foreach ($c in $s.ToCharArray()) {
    if ($c -eq '"') { [void]$sb.Append('\"') }
    elseif ($c -eq '\') { [void]$sb.Append('\\') }
    elseif ([int]$c -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) }
    else { [void]$sb.Append($c) }
  }
  $sb.ToString()
}

function Write-PrefMap([string]$key, $map) {
  $parts = foreach ($k in @($map.Keys)) { '"' + (ConvertTo-JsonText $k) + '":"' + (ConvertTo-JsonText $map[$k]) + '"' }
  $json = '{' + (@($parts) -join ',') + '}'
  $name = (Read-PrefText $key).Name
  $rk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:RegKeyPath)
  try { $rk.SetValue($name, [Text.Encoding]::UTF8.GetBytes($json + [char]0), [Microsoft.Win32.RegistryValueKind]::Binary) } finally { $rk.Close() }
}

function Save-Backup {
  # A .reg file that puts the local-skin list back exactly as it was, with a double-click.
  New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
  $file = Join-Path $script:BackupDir ('local-skins-before-{0:yyyy-MM-dd_HH-mm-ss-fff}.reg' -f (Get-Date))
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("Windows Registry Editor Version 5.00`r`n`r`n[HKEY_CURRENT_USER\$($script:RegKeyPath)]`r`n")
  foreach ($key in $script:SkinsKey, $script:NamesKey) {
    $p = Read-PrefText $key
    if ($null -eq $p.Raw) { [void]$sb.Append("""$($p.Name)""=-`r`n"); continue }
    if ($p.Raw -is [byte[]]) {
      $hex = [BitConverter]::ToString($p.Raw).Replace('-', ',').ToLower()
      $lines = for ($i = 0; $i -lt $hex.Length; $i += 75) { $hex.Substring($i, [Math]::Min(75, $hex.Length - $i)) }
      [void]$sb.Append("""$($p.Name)""=hex:" + ($lines -join "\`r`n  ") + "`r`n")
    } else {
      [void]$sb.Append("""$($p.Name)""=""" + ([string]$p.Raw).Replace('\', '\\').Replace('"', '\"') + """`r`n")
    }
  }
  [IO.File]::WriteAllText($file, $sb.ToString(), [Text.Encoding]::Unicode)
  $file
}

function ConvertTo-DisplaySkin([string]$base64) {
  try {
    $img = Read-Pixels ([Convert]::FromBase64String($base64))
    if ($img.W -eq 64 -and $img.H -eq 32) { return $img }
    (Convert-ToPg3dSkin $img).Skin   # other tools also store HD or 64x64 images
  } catch { $null }
}

function Get-LocalSkins {
  $skins = Read-PrefMap $script:SkinsKey
  $names = Read-PrefMap $script:NamesKey
  foreach ($id in @($skins.Keys)) {
    [pscustomobject]@{ Id = $id; Name = [string]$names[$id]; Skin = (ConvertTo-DisplaySkin $skins[$id]); Kind = 'local'; Created = (Get-TicksDate $id) }
  }
}

function Get-CloudSkins {
  $text = (Read-PrefText $script:CloudKey).Text
  if (-not $text) { return }
  foreach ($p in ($text | ConvertFrom-Json).PSObject.Properties) {
    $img = ConvertTo-DisplaySkin $p.Value.c
    if (-not $img -or $p.Name -eq '-1') { continue }   # "-1" is the 12x16 custom cape, not a skin
    [pscustomobject]@{ Id = $p.Name; Name = [string]$p.Value.n; Skin = $img; Kind = 'cloud'; Created = (Get-TicksDate $p.Name) }
  }
}

function Add-LocalSkins($items) {
  if (Test-GameRunning) { throw $script:GameRunningMessage }
  $skins = Read-PrefMap $script:SkinsKey
  $names = Read-PrefMap $script:NamesKey
  $backup = Save-Backup
  $taken = New-Object 'Collections.Generic.HashSet[string]'
  foreach ($k in @($skins.Keys) + @($names.Keys)) { [void]$taken.Add([string]$k) }
  try { foreach ($c in @(Get-CloudSkins)) { [void]$taken.Add([string]$c.Id) } } catch { }
  $id = [DateTime]::Now.Ticks
  $added = New-Object Collections.Generic.List[string]
  foreach ($it in $items) {
    while ($taken.Contains([string]$id)) { $id-- }
    $key = [string]$id
    $skins[$key] = [Convert]::ToBase64String((ConvertTo-Png $it.Skin))
    $names[$key] = ($it.Name -replace '[\x00-\x1f]', '').Trim()
    [void]$taken.Add($key); $added.Add($key); $id--
  }
  Write-PrefMap $script:SkinsKey $skins
  Write-PrefMap $script:NamesKey $names
  [pscustomobject]@{ Ids = $added.ToArray(); Backup = $backup }
}

function Remove-LocalSkin([string]$id) {
  if (Test-GameRunning) { throw $script:GameRunningMessage }
  $skins = Read-PrefMap $script:SkinsKey
  $names = Read-PrefMap $script:NamesKey
  $backup = Save-Backup
  $skins.Remove($id); $names.Remove($id)
  Write-PrefMap $script:SkinsKey $skins
  Write-PrefMap $script:NamesKey $names
  $backup
}

# ================================================================ skins from the web

# No public site offers downloadable Pixel Gun 3D-only skins (the one PG3D skin site pushes skins through your game
# login, which risks the account), so the PG3D group points at the official community spaces where players share theirs.
$script:Sites = @(
  [pscustomobject]@{ Group = 'pg3d'; Name = 'Pixel Gun 3D Discord'; Url = 'https://discord.gg/pixelgun3d'; Domain = 'discord.gg/pixelgun3d'; Mark = 'DC'; How = 'share'
    About = 'The official Pixel Gun 3D server, linked from the game''s website, where players share fan art and their own skins.' },
  [pscustomobject]@{ Group = 'pg3d'; Name = 'Steam Community artwork'; Url = 'https://steamcommunity.com/app/2524890/images/'; Domain = 'steamcommunity.com'; Mark = 'ST'; How = 'share'
    About = 'Artwork and creations posted by Pixel Gun 3D: PC Edition players on Steam.' },
  [pscustomobject]@{ Group = 'minecraft'; Name = 'The Skindex'; Url = 'https://www.minecraftskins.com/'; Domain = 'minecraftskins.com'; Mark = 'SX'; How = 'download'
    About = 'One of the biggest libraries of player-made skins, with ratings, categories and search.' },
  [pscustomobject]@{ Group = 'minecraft'; Name = 'NameMC'; Url = 'https://namemc.com/minecraft-skins'; Domain = 'namemc.com'; Mark = 'NM'; How = 'username'
    About = 'Trending skins and the skins real players wear. Like someone''s look? Paste their username above.' },
  [pscustomobject]@{ Group = 'minecraft'; Name = 'Planet Minecraft'; Url = 'https://www.planetminecraft.com/skins/'; Domain = 'planetminecraft.com'; Mark = 'PM'; How = 'download'
    About = 'Millions of community skins with tags, search and comments.' },
  [pscustomobject]@{ Group = 'minecraft'; Name = 'MinecraftSkins.net'; Url = 'https://www.minecraftskins.net/'; Domain = 'minecraftskins.net'; Mark = 'MS'; How = 'paste'
    About = 'Hand-picked skins in tidy categories. Copy a skin page''s link and paste it above.' },
  [pscustomobject]@{ Group = 'minecraft'; Name = 'NovaSkin'; Url = 'https://minecraft.novaskin.me/gallery'; Domain = 'minecraft.novaskin.me'; Mark = 'NS'; How = 'download'
    About = 'A big gallery plus a skin editor in your browser, if you want to make your own.' }
)

function Get-HttpStatus($exception) {
  # Status code of the WebException somewhere in the chain; 0 = no response, -1 = not a web error.
  for ($ex = $exception; $ex; $ex = $ex.InnerException) {
    if ($ex -is [Net.WebException]) { if ($ex.Response) { return [int]$ex.Response.StatusCode } else { return 0 } }
  }
  -1
}

function Get-WebBytes([string]$url) {
  # A plain, honest request (no browser disguise). Skins are tiny, so anything over 2 MB is refused.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $req = [Net.HttpWebRequest]::Create($url)
  $req.UserAgent = "PG3D-Skin-Importer/$($script:Version)"
  $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
  $resp = $req.GetResponse()
  try {
    $stream = $resp.GetResponseStream(); $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536
    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
      $ms.Write($buf, 0, $n)
      if ($ms.Length -gt 2MB) { throw 'that file is far too big to be a skin.' }
    }
    , $ms.ToArray()
  } finally { $resp.Close() }
}

function Test-PngBytes([byte[]]$b) { $null -ne $b -and $b.Length -gt 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47 }

function Get-SkinFromWeb([string]$text) {
  $t = $text.Trim()
  if ($t -match '^[A-Za-z0-9_]{3,16}$') {
    # A Minecraft username: Mojang's public profile API hands out that player's current skin.
    try { $player = [Text.Encoding]::UTF8.GetString((Get-WebBytes "https://api.minecraftservices.com/minecraft/profile/lookup/name/$t")) | ConvertFrom-Json }
    catch {
      if ((Get-HttpStatus $_.Exception) -in 204, 404) { throw "there's no Minecraft player called ""$t""." }
      throw "couldn't reach Minecraft's servers ($($_.Exception.Message))."
    }
    if (-not $player.id) { throw "there's no Minecraft player called ""$t""." }
    $session = [Text.Encoding]::UTF8.GetString((Get-WebBytes "https://sessionserver.mojang.com/session/minecraft/profile/$($player.id)")) | ConvertFrom-Json
    $prop = @($session.properties) | Where-Object { $_.name -eq 'textures' } | Select-Object -First 1
    $skinUrl = $null
    if ($prop) { $skinUrl = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($prop.value)) | ConvertFrom-Json).textures.SKIN.url }
    if (-not $skinUrl) { throw "$($player.name) wears one of Minecraft's default skins, so there's no custom skin to import." }
    return [pscustomobject]@{ Bytes = (Get-WebBytes ($skinUrl -replace '^http:', 'https:')); Name = [string]$player.name; Source = "minecraft:$(([string]$player.name).ToLower())" }
  }
  if ($t -match '^[\w\-]+(\.[\w\-]+)+/') { $t = "https://$t" }   # a link pasted without https://
  if ($t -notmatch '^https?://') { throw 'paste a full link (starting with https://) or a Minecraft username.' }
  $uri = [Uri]$t
  $url = $t
  $name = [IO.Path]::GetFileNameWithoutExtension($uri.AbsolutePath.TrimEnd('/'))
  # MinecraftSkins.net serves the raw skin at "<skin page>/download".
  if ($uri.Host -match '(^|\.)minecraftskins\.net$' -and $uri.AbsolutePath -match '^/([A-Za-z0-9_\-]+)/?$') { $url = "https://www.minecraftskins.net/$($Matches[1])/download"; $name = $Matches[1] }
  try { $bytes = Get-WebBytes $url }
  catch {
    $code = Get-HttpStatus $_.Exception
    if ($code -eq 403) { throw "$($uri.Host) doesn't let apps download skins. Open the skin in your browser and click its Download button: with ""Catch skins I download"" on, it lands in your queue." }
    if ($code -eq 404) { throw 'nothing was found at that link.' }
    throw "couldn't download that link ($($_.Exception.Message))."
  }
  if (-not (Test-PngBytes $bytes)) { throw "that link is a web page, not a skin image. Paste a MinecraftSkins.net skin page, a direct .png link or a Minecraft username, or use the site's Download button." }
  if (-not $name) { $name = 'web skin' }
  [pscustomobject]@{ Bytes = $bytes; Name = $name; Source = $url }
}

function Get-DownloadsFolder {
  try {
    $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($v) { $p = [Environment]::ExpandEnvironmentVariables($v); if (Test-Path -LiteralPath $p) { return $p } }
  } catch { }
  Join-Path $env:USERPROFILE 'Downloads'
}

function Get-Settings {
  $s = $null
  try { if (Test-Path -LiteralPath $script:SettingsFile) { $s = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json } } catch { }
  if (-not $s -or $null -eq $s.catchDownloads) { $s = [pscustomobject]@{ catchDownloads = $true } }
  $s
}

function Save-Settings($s) {
  New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
  [IO.File]::WriteAllText($script:SettingsFile, ($s | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}

# ================================================================ window

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Skin Importer for Pixel Gun 3D" Width="1180" Height="760" MinWidth="1060" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0B0E1A" Foreground="#E9EDFF" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display" AllowDrop="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" CornerRadius="0" GlassFrameThickness="0,0,0,1" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Window.Resources>
    <FontFamily x:Key="IconFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <FontFamily x:Key="DisplayFont">Segoe UI Variable Display, Segoe UI</FontFamily>

    <LinearGradientBrush x:Key="AccentGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#7C5CFF" Offset="0"/>
      <GradientStop Color="#22D3EE" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="WarmGradient" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#F59E0B" Offset="0"/>
      <GradientStop Color="#EF4444" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="AccentGradientV" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#7C5CFF" Offset="0"/>
      <GradientStop Color="#22D3EE" Offset="1"/>
    </LinearGradientBrush>
    <RadialGradientBrush x:Key="StageBrush" GradientOrigin="0.5,0.32" Center="0.5,0.42" RadiusX="0.85" RadiusY="0.75">
      <GradientStop Color="#2B2C68" Offset="0"/>
      <GradientStop Color="#191C40" Offset="0.55"/>
      <GradientStop Color="#10132A" Offset="1"/>
    </RadialGradientBrush>
    <LinearGradientBrush x:Key="TileBrush" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#222859" Offset="0"/>
      <GradientStop Color="#161B3A" Offset="1"/>
    </LinearGradientBrush>
    <DrawingBrush x:Key="Checker" TileMode="Tile" Viewport="0,0,16,16" ViewportUnits="Absolute">
      <DrawingBrush.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="#161A33" Geometry="M0,0 H2 V2 H0 Z"/>
          <GeometryDrawing Brush="#1D2244" Geometry="M0,0 H1 V1 H0 Z M1,1 H2 V2 H1 Z"/>
        </DrawingGroup>
      </DrawingBrush.Drawing>
    </DrawingBrush>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource DisplayFont}"/>
      <Setter Property="FontSize" Value="28"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8C95BF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Overline" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7E88B5"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#141936"/>
      <Setter Property="BorderBrush" Value="#20264A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
    </Style>

    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border CornerRadius="3" Background="#323A6A" Margin="1,0"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Focusable="False">
              <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CaptionBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Foreground" Value="#AEB6DA"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E2442"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource CaptionBtn}">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#E5484D"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Foreground" Value="#8C95BF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="Bg" CornerRadius="10" Background="Transparent"/>
              <Border x:Name="Bar" Width="3" CornerRadius="2" HorizontalAlignment="Left" Margin="0,11" Background="{StaticResource AccentGradientV}" Opacity="0"/>
              <StackPanel Orientation="Horizontal" Margin="16,11">
                <TextBlock x:Name="Ico" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource IconFont}" FontSize="16" VerticalAlignment="Center" Width="22"/>
                <ContentPresenter VerticalAlignment="Center" Margin="10,0,0,0"/>
              </StackPanel>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="#151A33"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#1A1F3D"/>
                <Setter TargetName="Bar" Property="Opacity" Value="1"/>
                <Setter TargetName="Ico" Property="Foreground" Value="#22D3EE"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Height" Value="46"/>
      <Setter Property="Padding" Value="26,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="GlowBd" CornerRadius="12" Background="{StaticResource AccentGradient}" Opacity="0.35" Margin="4,6,4,-2">
                <Border.Effect><BlurEffect Radius="18"/></Border.Effect>
              </Border>
              <Border x:Name="Bd" CornerRadius="12" Background="{StaticResource AccentGradient}" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="Shine" CornerRadius="12" Background="#1FFFFFFF" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="GlowBd" Property="Opacity" Value="0.8"/>
                <Setter TargetName="Shine" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.3"/>
                <Setter TargetName="GlowBd" Property="Opacity" Value="0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#D6DCF5"/>
      <Setter Property="Background" Value="#181D3A"/>
      <Setter Property="BorderBrush" Value="#262D55"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" CornerRadius="10" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="Hover" CornerRadius="10" Background="#14FFFFFF" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="1"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource GhostBtn}">
      <Setter Property="Foreground" Value="#FCA5A5"/>
      <Setter Property="Background" Value="#2A1830"/>
      <Setter Property="BorderBrush" Value="#4A2340"/>
    </Style>
    <Style x:Key="LinkBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#22D3EE"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <ContentPresenter x:Name="Cp"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Cp" Property="Opacity" Value="0.75"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Foreground" Value="#7E88B5"/>
      <Setter Property="FontFamily" Value="{StaticResource IconFont}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A1830"/>
                <Setter Property="Foreground" Value="#FCA5A5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Foreground" Value="#E9EDFF"/>
      <Setter Property="CaretBrush" Value="#22D3EE"/>
      <Setter Property="SelectionBrush" Value="#7C5CFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="MaxLength" Value="20"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="#0F1326" BorderBrush="#262C4D" BorderThickness="1" CornerRadius="8" Padding="6,5">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4275"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#7C5CFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="26" Background="Transparent">
              <Border CornerRadius="13" Background="#262C4D"/>
              <Border x:Name="On" CornerRadius="13" Background="{StaticResource AccentGradient}" Opacity="0"/>
              <Ellipse x:Name="Knob" Width="20" Height="20" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="On" Property="Opacity" Value="1"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Background="#0B0E1A">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="44"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- title bar -->
      <Grid Background="#0B0E1A">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
          <Image x:Name="LogoImg" Width="24" Height="24" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
          <TextBlock Text="Skin Importer" FontWeight="SemiBold" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
          <TextBlock Text="for Pixel Gun 3D" Foreground="#5C6590" FontSize="13" Margin="6,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Border CornerRadius="11" Padding="11,4" VerticalAlignment="Center" Margin="0,0,10,0" Background="#141936" BorderBrush="#232A50" BorderThickness="1">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StatusDot" Width="8" Height="8" VerticalAlignment="Center" Fill="#5C6590"/>
              <TextBlock x:Name="StatusText" FontSize="12" Margin="8,0,0,0" VerticalAlignment="Center" Foreground="#AEB6DA"/>
            </StackPanel>
          </Border>
          <Button x:Name="BtnMin" Style="{StaticResource CaptionBtn}" Content="&#xE921;"/>
          <Button x:Name="BtnMax" Style="{StaticResource CaptionBtn}" Content="&#xE922;"/>
          <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="236"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- sidebar menu -->
        <Border Background="#0F1324" BorderBrush="#1A1F3A" BorderThickness="0,1,1,0">
          <DockPanel Margin="14,18,14,16">
            <StackPanel DockPanel.Dock="Bottom">
              <Border CornerRadius="12" Padding="14,12" Background="#141936" BorderBrush="#20264A" BorderThickness="1">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE753;" Style="{StaticResource Icon}" Foreground="#22D3EE" FontSize="14"/>
                    <TextBlock Text="Keep a skin forever" FontWeight="SemiBold" Margin="8,0,0,0"/>
                  </StackPanel>
                  <TextBlock Text="Open an imported skin in the in-game Skin Editor and save it. The game uploads it to your account." TextWrapping="Wrap" Foreground="#8C95BF" FontSize="12" Margin="0,6,0,0" LineHeight="17"/>
                </StackPanel>
              </Border>
              <TextBlock Text="v2.1  &#xB7;  unofficial fan-made tool" Foreground="#4C557E" FontSize="11" Margin="4,12,0,0"/>
            </StackPanel>
            <StackPanel>
              <TextBlock Text="MENU" Style="{StaticResource Overline}" Margin="12,0,0,10"/>
              <RadioButton x:Name="NavImport" Style="{StaticResource Nav}" Tag="&#xE898;" Content="Import" IsChecked="True"/>
              <RadioButton x:Name="NavWeb" Style="{StaticResource Nav}" Tag="&#xE774;" Content="Get skins"/>
              <RadioButton x:Name="NavLibrary" Style="{StaticResource Nav}" Tag="&#xE77B;" Content="My skins"/>
              <RadioButton x:Name="NavHelp" Style="{StaticResource Nav}" Tag="&#xE897;" Content="How it works"/>
            </StackPanel>
          </DockPanel>
        </Border>

        <Grid Grid.Column="1" Margin="30,24,30,24">

          <!-- ============ IMPORT ============ -->
          <Grid x:Name="PageImport">
            <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="0,0,0,20">
              <TextBlock Text="Import skins" Style="{StaticResource H1}"/>
              <TextBlock Text="Drop Minecraft or Pixel Gun 3D skins. They show up in the game as local skins." Style="{StaticResource Sub}"/>
            </StackPanel>

            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="370"/>
                <ColumnDefinition Width="22"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid x:Name="DropZone" Height="150" Cursor="Hand" Background="Transparent">
                  <Rectangle x:Name="DropRect" RadiusX="16" RadiusY="16" Stroke="#343C6E" StrokeThickness="2" StrokeDashArray="5 4" Fill="#10142A"/>
                  <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <Border Width="50" Height="50" CornerRadius="25" Background="{StaticResource AccentGradient}" HorizontalAlignment="Center">
                      <TextBlock Text="&#xE898;" Style="{StaticResource Icon}" FontSize="20" Foreground="White"/>
                    </Border>
                    <TextBlock Text="Drop skin PNGs here" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,3"/>
                    <TextBlock HorizontalAlignment="Center" Foreground="#8C95BF" FontSize="12"><Run Text="or "/><Run Text="browse your files" Foreground="#22D3EE"/><Run Text="  &#xB7;  64&#xD7;32, 64&#xD7;64, slim, HD"/></TextBlock>
                  </StackPanel>
                </Grid>
                <DockPanel Grid.Row="1" Margin="2,20,2,10">
                  <Button x:Name="ClearQueueBtn" DockPanel.Dock="Right" Style="{StaticResource LinkBtn}" Content="Clear all"/>
                  <TextBlock x:Name="QueueTitle" Text="QUEUE" Style="{StaticResource Overline}" VerticalAlignment="Center"/>
                </DockPanel>
                <TextBlock x:Name="QueueEmpty" Grid.Row="2" Text="Nothing queued yet. Add as many skins as you like, then import them all at once." Foreground="#5C6590" TextWrapping="Wrap" Margin="2,4,0,0" LineHeight="19"/>
                <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                  <StackPanel x:Name="QueueList" Margin="0,0,6,0"/>
                </ScrollViewer>
              </Grid>

              <Grid Grid.Column="2">
                <Grid.RowDefinitions>
                  <RowDefinition Height="*"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Border CornerRadius="18" Background="{StaticResource StageBrush}" BorderBrush="#20264A" BorderThickness="1">
                  <Grid>
                    <Ellipse Width="170" Height="26" VerticalAlignment="Bottom" Margin="0,0,0,26" IsHitTestVisible="False">
                      <Ellipse.Fill>
                        <RadialGradientBrush>
                          <GradientStop Color="#70000000" Offset="0"/>
                          <GradientStop Color="#00000000" Offset="1"/>
                        </RadialGradientBrush>
                      </Ellipse.Fill>
                    </Ellipse>
                    <Grid x:Name="Stage1" Background="Transparent" Cursor="SizeWE" Margin="0,30,0,10" Visibility="Collapsed">
                      <Viewport3D IsHitTestVisible="False">
                        <Viewport3D.Camera>
                          <PerspectiveCamera x:Name="Cam1" Position="0,6,74" LookDirection="0,-6,-74" UpDirection="0,1,0" FieldOfView="30"/>
                        </Viewport3D.Camera>
                        <ModelVisual3D>
                          <ModelVisual3D.Content>
                            <Model3DGroup>
                              <AmbientLight Color="#8C8C8C"/>
                              <DirectionalLight Color="#8C8C8C" Direction="-0.3,-1,-0.6"/>
                            </Model3DGroup>
                          </ModelVisual3D.Content>
                        </ModelVisual3D>
                        <ModelVisual3D x:Name="Model1">
                          <ModelVisual3D.Transform>
                            <RotateTransform3D>
                              <RotateTransform3D.Rotation>
                                <AxisAngleRotation3D x:Name="Spin1" Axis="0,1,0" Angle="25"/>
                              </RotateTransform3D.Rotation>
                            </RotateTransform3D>
                          </ModelVisual3D.Transform>
                        </ModelVisual3D>
                      </Viewport3D>
                    </Grid>
                    <StackPanel x:Name="PreviewEmpty" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
                      <Image x:Name="EmptyLogo" Width="72" Height="72" Opacity="0.5" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
                      <TextBlock Text="Your skin appears here in 3D" Foreground="#8C95BF" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,16,0,4"/>
                      <TextBlock Text="Drop a PNG on the left to get started" Foreground="#5C6590" HorizontalAlignment="Center"/>
                    </StackPanel>
                    <TextBlock Text="3D PREVIEW" Style="{StaticResource Overline}" Margin="20,18,0,0" HorizontalAlignment="Left" VerticalAlignment="Top"/>
                    <TextBlock x:Name="DragHint" Margin="0,18,20,0" HorizontalAlignment="Right" VerticalAlignment="Top" Foreground="#5C6590" FontSize="11" Visibility="Collapsed"><Run Text="&#xE7AD;" FontFamily="{StaticResource IconFont}"/><Run Text="  drag to spin"/></TextBlock>
                  </Grid>
                </Border>
                <Border Grid.Row="1" Margin="0,16,0,0" Style="{StaticResource Card}" Padding="16">
                  <DockPanel>
                    <Border DockPanel.Dock="Left" Background="{StaticResource Checker}" Width="256" Height="128" CornerRadius="6">
                      <Image x:Name="TexImg" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
                    </Border>
                    <StackPanel Margin="20,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="WHAT CHANGES" Style="{StaticResource Overline}"/>
                      <TextBlock x:Name="DetailKind" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,6,0,0" Text="Nothing selected"/>
                      <TextBlock x:Name="DetailNotes" Foreground="#8C95BF" Margin="0,6,0,0" TextWrapping="Wrap" LineHeight="19" Text="Pick a skin in the queue to see how it gets converted."/>
                    </StackPanel>
                  </DockPanel>
                </Border>
              </Grid>
            </Grid>

            <Border Grid.Row="2" Margin="0,18,0,0" CornerRadius="14" Background="#11152B" BorderBrush="#1C2244" BorderThickness="1" Padding="16,12">
              <DockPanel>
                <Button x:Name="ImportBtn" DockPanel.Dock="Right" Style="{StaticResource PrimaryBtn}" IsEnabled="False">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE7FC;" Style="{StaticResource Icon}" FontSize="16" Margin="0,0,10,0"/>
                    <TextBlock x:Name="ImportBtnText" Text="Add to Pixel Gun 3D" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <StackPanel x:Name="GameWarning" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed">
                  <TextBlock Text="&#xE7BA;" Style="{StaticResource Icon}" Foreground="#FBBF24" FontSize="15"/>
                  <TextBlock Text="Close Pixel Gun 3D to import " Foreground="#FBBF24" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
                  <TextBlock Text="&#x2014; it rewrites its saved skins when it exits." Foreground="#8C95BF" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel x:Name="ReadyHint" Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="&#xE8EA;" Style="{StaticResource Icon}" Foreground="#22D3EE" FontSize="15"/>
                  <TextBlock Text="Skins are added as local skins on this PC. A backup is saved first." Foreground="#8C95BF" Margin="10,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
              </DockPanel>
            </Border>
          </Grid>

          <!-- ============ GET SKINS ============ -->
          <ScrollViewer x:Name="PageWeb" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <ScrollViewer.RenderTransform><TranslateTransform/></ScrollViewer.RenderTransform>
            <StackPanel Margin="0,0,8,0">
              <TextBlock Text="Get skins" Style="{StaticResource H1}"/>
              <TextBlock Text="Skins shared by the Pixel Gun 3D community, plus millions of Minecraft skins (same layout, converted automatically)." Style="{StaticResource Sub}" Margin="0,4,0,22"/>

              <Border Style="{StaticResource Card}" Padding="20">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE71B;" Style="{StaticResource Icon}" Foreground="#22D3EE" FontSize="15"/>
                    <TextBlock Text="Import straight from the web" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0"/>
                  </StackPanel>
                  <TextBlock Text="Paste a direct skin image link (for example from Discord or Steam), a MinecraftSkins.net skin page, or any Minecraft player's username." Foreground="#8C95BF" Margin="0,5,0,14" TextWrapping="Wrap"/>
                  <DockPanel>
                    <Button x:Name="FetchBtn" DockPanel.Dock="Right" Style="{StaticResource PrimaryBtn}" Height="42" Margin="12,0,0,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE896;" Style="{StaticResource Icon}" Margin="0,0,10,0"/>
                        <TextBlock x:Name="FetchText" Text="Fetch skin" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Button>
                    <Grid>
                      <TextBox x:Name="WebBox" Style="{StaticResource Field}" MaxLength="400" Height="42" FontWeight="Normal"/>
                      <TextBlock x:Name="WebHint" Text="https://www.minecraftskins.net/...   or a Minecraft username" Foreground="#4C557E" Margin="12,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                    </Grid>
                  </DockPanel>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}" Padding="20,16" Margin="0,14,0,0">
                <DockPanel>
                  <CheckBox x:Name="CatchToggle" DockPanel.Dock="Right" Style="{StaticResource Switch}" VerticalAlignment="Center" Margin="16,0,0,0"/>
                  <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="10" Background="#1A2045" VerticalAlignment="Top">
                    <TextBlock Text="&#xE896;" Style="{StaticResource Icon}" Foreground="#34D399" FontSize="16"/>
                  </Border>
                  <StackPanel Margin="14,0,0,0">
                    <TextBlock Text="Catch skins I download" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock x:Name="CatchHint" Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,4,0,0" LineHeight="19"/>
                  </StackPanel>
                </DockPanel>
              </Border>

              <TextBlock Text="PIXEL GUN 3D COMMUNITY" Style="{StaticResource Overline}" Margin="2,26,0,4"/>
              <TextBlock Text="Where Pixel Gun 3D players share skins they made. Download a skin image and it lands in your queue." Foreground="#5C6590" FontSize="12" Margin="2,0,0,12" TextWrapping="Wrap"/>
              <UniformGrid x:Name="Pg3dGrid" Columns="2" Margin="0,0,-14,0"/>
              <TextBlock Text="MINECRAFT SKIN SITES" Style="{StaticResource Overline}" Margin="2,12,0,4"/>
              <TextBlock Text="Pixel Gun 3D uses the same skin layout, so these import too: the app converts them to the 64&#xD7;32 format." Foreground="#5C6590" FontSize="12" Margin="2,0,0,12" TextWrapping="Wrap"/>
              <UniformGrid x:Name="SiteGrid" Columns="2" Margin="0,0,-14,0"/>
              <TextBlock Text="Independent sites and communities, not affiliated with this tool. Their skins are made by their communities." Foreground="#4C557E" FontSize="11" Margin="2,2,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </ScrollViewer>

          <!-- ============ MY SKINS ============ -->
          <Grid x:Name="PageLibrary" Visibility="Collapsed">
            <Grid.RenderTransform><TranslateTransform/></Grid.RenderTransform>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,20">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="RefreshBtn" Style="{StaticResource GhostBtn}">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE72C;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                    <TextBlock Text="Refresh" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <Button x:Name="LibBackupsBtn" Style="{StaticResource GhostBtn}" Margin="8,0,0,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE838;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                    <TextBlock Text="Backups" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="My skins" Style="{StaticResource H1}"/>
                <TextBlock Text="Local skins on this PC, plus the skins saved to your account." Style="{StaticResource Sub}"/>
              </StackPanel>
            </DockPanel>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="22"/>
                <ColumnDefinition Width="320"/>
              </Grid.ColumnDefinitions>
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel Margin="0,0,6,0">
                  <DockPanel Margin="0,0,0,14">
                    <Border DockPanel.Dock="Left" Width="34" Height="34" CornerRadius="10" Background="#1A2045">
                      <TextBlock Text="&#xE8EA;" Style="{StaticResource Icon}" Foreground="#22D3EE" FontSize="15"/>
                    </Border>
                    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                      <TextBlock><Run Text="On this PC" FontWeight="SemiBold" FontSize="15"/><Run x:Name="LocalCount" Text="" Foreground="#7E88B5" FontSize="13"/></TextBlock>
                      <TextBlock Text="Local skins: phone icon in Wear &#x2192; Skins" Foreground="#7E88B5" FontSize="12" Margin="0,2,0,0"/>
                    </StackPanel>
                  </DockPanel>
                  <TextBlock x:Name="LocalEmpty" Text="No local skins yet. Import some on the Import page." Foreground="#5C6590" Margin="2,0,0,18"/>
                  <WrapPanel x:Name="LocalList" Margin="0,0,0,10"/>
                  <DockPanel Margin="0,8,0,14">
                    <Border DockPanel.Dock="Left" Width="34" Height="34" CornerRadius="10" Background="#1A2045">
                      <TextBlock Text="&#xE753;" Style="{StaticResource Icon}" Foreground="#A78BFA" FontSize="15"/>
                    </Border>
                    <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                      <TextBlock><Run Text="In your account" FontWeight="SemiBold" FontSize="15"/><Run x:Name="CloudCount" Text="" Foreground="#7E88B5" FontSize="13"/></TextBlock>
                      <TextBlock Text="Synced by the game (cloud icon). Read-only here, but you can export them." Foreground="#7E88B5" FontSize="12" Margin="0,2,0,0"/>
                    </StackPanel>
                  </DockPanel>
                  <TextBlock x:Name="CloudEmpty" Text="No account skins found." Foreground="#5C6590" Margin="2,0,0,18"/>
                  <WrapPanel x:Name="CloudList"/>
                </StackPanel>
              </ScrollViewer>

              <Border Grid.Column="2" CornerRadius="18" Background="{StaticResource StageBrush}" BorderBrush="#20264A" BorderThickness="1">
                <Grid>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <Ellipse Width="140" Height="22" VerticalAlignment="Bottom" Margin="0,0,0,8" IsHitTestVisible="False">
                    <Ellipse.Fill>
                      <RadialGradientBrush>
                        <GradientStop Color="#70000000" Offset="0"/>
                        <GradientStop Color="#00000000" Offset="1"/>
                      </RadialGradientBrush>
                    </Ellipse.Fill>
                  </Ellipse>
                  <Grid x:Name="Stage2" Background="Transparent" Cursor="SizeWE" Margin="0,24,0,0" Visibility="Collapsed">
                    <Viewport3D IsHitTestVisible="False">
                      <Viewport3D.Camera>
                        <PerspectiveCamera x:Name="Cam2" Position="0,6,74" LookDirection="0,-6,-74" UpDirection="0,1,0" FieldOfView="30"/>
                      </Viewport3D.Camera>
                      <ModelVisual3D>
                        <ModelVisual3D.Content>
                          <Model3DGroup>
                            <AmbientLight Color="#8C8C8C"/>
                            <DirectionalLight Color="#8C8C8C" Direction="-0.3,-1,-0.6"/>
                          </Model3DGroup>
                        </ModelVisual3D.Content>
                      </ModelVisual3D>
                      <ModelVisual3D x:Name="Model2">
                        <ModelVisual3D.Transform>
                          <RotateTransform3D>
                            <RotateTransform3D.Rotation>
                              <AxisAngleRotation3D x:Name="Spin2" Axis="0,1,0" Angle="25"/>
                            </RotateTransform3D.Rotation>
                          </RotateTransform3D>
                        </ModelVisual3D.Transform>
                      </ModelVisual3D>
                    </Viewport3D>
                  </Grid>
                  <TextBlock x:Name="LibEmpty" Text="Pick a skin to preview it" Foreground="#8C95BF" FontSize="14" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <StackPanel Grid.Row="1" Margin="20,0,20,20">
                    <TextBlock x:Name="LibName" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="LibKind" Foreground="#8C95BF" Margin="0,3,0,14" TextWrapping="Wrap"/>
                    <StackPanel x:Name="LibActions" Orientation="Horizontal" Visibility="Collapsed">
                      <Button x:Name="ExportBtn" Style="{StaticResource GhostBtn}">
                        <StackPanel Orientation="Horizontal">
                          <TextBlock Text="&#xE896;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                          <TextBlock Text="Export PNG" VerticalAlignment="Center"/>
                        </StackPanel>
                      </Button>
                      <Button x:Name="DeleteBtn" Style="{StaticResource DangerBtn}" Margin="8,0,0,0">
                        <StackPanel Orientation="Horizontal">
                          <TextBlock Text="&#xE74D;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                          <TextBlock x:Name="DeleteText" Text="Delete" VerticalAlignment="Center"/>
                        </StackPanel>
                      </Button>
                    </StackPanel>
                  </StackPanel>
                </Grid>
              </Border>
            </Grid>
          </Grid>

          <!-- ============ HOW IT WORKS ============ -->
          <ScrollViewer x:Name="PageHelp" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <ScrollViewer.RenderTransform><TranslateTransform/></ScrollViewer.RenderTransform>
            <StackPanel Margin="0,0,8,0" MaxWidth="900" HorizontalAlignment="Left">
              <TextBlock Text="How it works" Style="{StaticResource H1}"/>
              <TextBlock Text="Four steps from a PNG on your PC to a skin you can wear in Pixel Gun 3D." Style="{StaticResource Sub}" Margin="0,4,0,22"/>
              <UniformGrid Columns="2">
                <Border Style="{StaticResource Card}" Padding="20" Margin="0,0,14,14">
                  <DockPanel>
                    <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="18" Background="{StaticResource AccentGradient}" VerticalAlignment="Top">
                      <TextBlock Text="1" FontWeight="Bold" FontSize="15" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="16,0,0,0">
                      <TextBlock Text="Close Pixel Gun 3D" FontSize="15" FontWeight="SemiBold"/>
                      <TextBlock Text="The game saves its skin list when it exits, so it has to be closed while skins are added. The status at the top right tells you." Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="19"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Border Style="{StaticResource Card}" Padding="20" Margin="0,0,0,14">
                  <DockPanel>
                    <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="18" Background="{StaticResource AccentGradient}" VerticalAlignment="Top">
                      <TextBlock Text="2" FontWeight="Bold" FontSize="15" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="16,0,0,0">
                      <TextBlock Text="Import your skins" FontSize="15" FontWeight="SemiBold"/>
                      <TextBlock Text="Drop PNGs on the Import page or grab community skins on Get skins. Minecraft skins (64&#xD7;64, slim, HD) are converted to the 64&#xD7;32 Pixel Gun 3D layout automatically." Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="19"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Border Style="{StaticResource Card}" Padding="20" Margin="0,0,14,14">
                  <DockPanel>
                    <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="18" Background="{StaticResource AccentGradient}" VerticalAlignment="Top">
                      <TextBlock Text="3" FontWeight="Bold" FontSize="15" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="16,0,0,0">
                      <TextBlock Text="Wear them" FontSize="15" FontWeight="SemiBold"/>
                      <TextBlock Text="Start the game and open Wear &#x2192; Skins. Imported skins have a phone icon: they are stored on this PC." Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="19"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
                <Border Style="{StaticResource Card}" Padding="20" Margin="0,0,0,14">
                  <DockPanel>
                    <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="18" Background="{StaticResource AccentGradient}" VerticalAlignment="Top">
                      <TextBlock Text="4" FontWeight="Bold" FontSize="15" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <StackPanel Margin="16,0,0,0">
                      <TextBlock Text="Keep them in your account" FontSize="15" FontWeight="SemiBold"/>
                      <TextBlock Text="Open a skin in the in-game Skin Editor and save it. The game uploads it, it gets a cloud icon and follows you to other devices." Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="19"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
              </UniformGrid>
              <Border Style="{StaticResource Card}" Padding="20" Margin="0,8,0,14">
                <DockPanel>
                  <Button x:Name="HelpBackupsBtn" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}" VerticalAlignment="Center" Margin="16,0,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE838;" Style="{StaticResource Icon}" Margin="0,0,8,0"/>
                      <TextBlock Text="Open backups folder" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Button>
                  <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="10" Background="#1A2045" VerticalAlignment="Top">
                    <TextBlock Text="&#xE777;" Style="{StaticResource Icon}" Foreground="#34D399" FontSize="16"/>
                  </Border>
                  <StackPanel Margin="16,0,0,0">
                    <TextBlock Text="Backups and undo" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock Text="Before every change, your local-skin list is saved to a .reg file. Double-click one (with the game closed) to put everything back exactly as it was." Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="19"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <Border Style="{StaticResource Card}" Padding="20">
                <DockPanel>
                  <Border DockPanel.Dock="Left" Width="36" Height="36" CornerRadius="10" Background="#1A2045" VerticalAlignment="Top">
                    <TextBlock Text="&#xE946;" Style="{StaticResource Icon}" Foreground="#22D3EE" FontSize="16"/>
                  </Border>
                  <StackPanel Margin="16,0,0,0">
                    <TextBlock Text="Good to know" FontSize="15" FontWeight="SemiBold"/>
                    <TextBlock Text="This is an unofficial fan-made tool, not made by or affiliated with the game's developers. It only edits the local-skin list on this PC. Your account, currencies and progress are never touched, and nothing is uploaded anywhere." Foreground="#8C95BF" TextWrapping="Wrap" Margin="0,5,0,0" LineHeight="19"/>
                  </StackPanel>
                </DockPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </Grid>

      <!-- toast -->
      <Border x:Name="Toast" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,96" Padding="16,13" CornerRadius="12"
              Background="#1A2042" BorderBrush="#2C3468" BorderThickness="1" Opacity="0" IsHitTestVisible="False" MaxWidth="480">
        <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="6" Opacity="0.5" Color="#000000"/></Border.Effect>
        <Border.RenderTransform><TranslateTransform x:Name="ToastShift" Y="16"/></Border.RenderTransform>
        <DockPanel>
          <TextBlock x:Name="ToastIcon" DockPanel.Dock="Left" Style="{StaticResource Icon}" FontSize="16" VerticalAlignment="Top" Margin="0,1,12,0"/>
          <TextBlock x:Name="ToastText" TextWrapping="Wrap" VerticalAlignment="Center" LineHeight="19"/>
        </DockPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@

$script:UiNames = 'Root', 'LogoImg', 'StatusDot', 'StatusText', 'BtnMin', 'BtnMax', 'BtnClose', 'NavImport', 'NavWeb', 'NavLibrary', 'NavHelp',
  'PageWeb', 'WebBox', 'WebHint', 'FetchBtn', 'FetchText', 'CatchToggle', 'CatchHint', 'SiteGrid', 'Pg3dGrid',
  'PageImport', 'PageLibrary', 'PageHelp', 'DropZone', 'DropRect', 'ClearQueueBtn', 'QueueTitle', 'QueueEmpty', 'QueueList',
  'Stage1', 'Model1', 'Spin1', 'Cam1', 'Cam2', 'PreviewEmpty', 'EmptyLogo', 'DragHint', 'TexImg', 'DetailKind', 'DetailNotes',
  'ImportBtn', 'ImportBtnText', 'GameWarning', 'ReadyHint', 'RefreshBtn', 'LibBackupsBtn', 'LocalCount', 'LocalEmpty', 'LocalList',
  'CloudCount', 'CloudEmpty', 'CloudList', 'Stage2', 'Model2', 'Spin2', 'LibEmpty', 'LibName', 'LibKind', 'LibActions',
  'ExportBtn', 'DeleteBtn', 'DeleteText', 'HelpBackupsBtn', 'Toast', 'ToastShift', 'ToastIcon', 'ToastText'

# ---------------------------------------------------------------- ui helpers

function New-LogoCanvas {
  # Original 8x8 pixel-art mark: an arrow dropping into a tray, on a violet-to-cyan block.
  $rows = '.######.', '###XX###', '###XX###', '#XXXXXX#', '##XXXX##', '###XX###', '#X####X#', '.XXXXXX.'
  $img = New-Canvas 8 8
  for ($y = 0; $y -lt 8; $y++) {
    for ($x = 0; $x -lt 8; $x++) {
      $c = $rows[$y][$x]
      if ($c -eq '.') { continue }
      $i = ($y * 8 + $x) * 4
      if ($c -eq 'X') { $img.Px[$i] = 255; $img.Px[$i + 1] = 255; $img.Px[$i + 2] = 255 }
      else {
        $t = ($x + $y) / 14
        $img.Px[$i] = [byte](255 + (238 - 255) * $t); $img.Px[$i + 1] = [byte](92 + (211 - 92) * $t); $img.Px[$i + 2] = [byte](124 + (34 - 124) * $t)
      }
      $img.Px[$i + 3] = 255
    }
  }
  $img
}

function Start-Animation($target, $property, [double]$to, [int]$ms = 240, $from = $null) {
  $anim = New-Object Windows.Media.Animation.DoubleAnimation ($to, [Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)))
  if ($null -ne $from) { $anim.From = [double]$from }
  $anim.EasingFunction = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }
  $target.BeginAnimation($property, $anim)
}

function Show-Toast([string]$text, [string]$kind = 'ok') {
  $style = @{ ok = @(0xE73E, '#34D399'); error = @(0xE7BA, '#F87171'); info = @(0xE946, '#22D3EE') }[$kind]
  $script:ui.ToastIcon.Text = [string][char]$style[0]
  $script:ui.ToastIcon.Foreground = $style[1]
  $script:ui.ToastText.Text = $text
  Start-Animation $script:ui.Toast ([Windows.UIElement]::OpacityProperty) 1 220
  Start-Animation $script:ui.ToastShift ([Windows.Media.TranslateTransform]::YProperty) 0 320
  $script:ToastTimer.Stop()
  $script:ToastTimer.Interval = [TimeSpan]::FromSeconds($(if ($kind -eq 'error') { 7 } else { 5 }))
  $script:ToastTimer.Start()
}

function Hide-Toast {
  $script:ToastTimer.Stop()
  Start-Animation $script:ui.Toast ([Windows.UIElement]::OpacityProperty) 0 300
  Start-Animation $script:ui.ToastShift ([Windows.Media.TranslateTransform]::YProperty) 16 300
}

function Invoke-Safe([scriptblock]$action) {
  try { & $action } catch { Show-Toast $_.Exception.Message 'error' }
}

function Show-Page([string]$name) {
  foreach ($p in 'PageImport', 'PageWeb', 'PageLibrary', 'PageHelp') { $script:ui[$p].Visibility = $(if ($p -eq $name) { 'Visible' } else { 'Collapsed' }) }
  $page = $script:ui[$name]
  Start-Animation $page ([Windows.UIElement]::OpacityProperty) 1 260 0
  Start-Animation $page.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) 0 320 14
}

function Start-Spin($spin) {
  $from = $spin.Angle
  $anim = New-Object Windows.Media.Animation.DoubleAnimation ($from, ($from + 360), [Windows.Duration]::new([TimeSpan]::FromSeconds(10)))
  $anim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  $spin.BeginAnimation([Windows.Media.Media3D.AxisAngleRotation3D]::AngleProperty, $anim)
}

function Set-CameraFit($camera, [double]$w, [double]$h) {
  # WPF's FieldOfView is horizontal; derive it from the stage shape so the whole body always fits vertically.
  if ($w -le 0 -or $h -le 0) { return }
  $vertical = 36 * [Math]::PI / 180
  $camera.FieldOfView = 2 * [Math]::Atan([Math]::Tan($vertical / 2) * $w / $h) * 180 / [Math]::PI
}

function Initialize-Spinner($stage, $spin, $camera) {
  # Spins on its own; dragging sideways turns it by hand, letting go resumes the spin.
  $stage.Tag = @{ Spin = $spin; Camera = $camera; Drag = $false; X = 0.0; A = 0.0 }
  Start-Spin $spin
  $stage.Add_SizeChanged({ param($s, $e) Set-CameraFit $s.Tag.Camera $e.NewSize.Width $e.NewSize.Height })
  $stage.Add_MouseLeftButtonDown({
    param($s, $e)
    $t = $s.Tag
    $t.A = $t.Spin.Angle
    $t.Spin.BeginAnimation([Windows.Media.Media3D.AxisAngleRotation3D]::AngleProperty, $null)
    $t.Spin.Angle = $t.A
    $t.X = $e.GetPosition($s).X
    $t.Drag = $true
    [void]$s.CaptureMouse()
  })
  $stage.Add_MouseMove({
    param($s, $e)
    $t = $s.Tag
    if ($t.Drag) { $t.Spin.Angle = $t.A + ($e.GetPosition($s).X - $t.X) * 0.9 }
  })
  $stage.Add_MouseLeftButtonUp({
    param($s, $e)
    $t = $s.Tag
    if ($t.Drag) { $t.Drag = $false; $s.ReleaseMouseCapture(); Start-Spin $t.Spin }
  })
}

function New-DollImage($skin, [int]$scale) {
  $img = New-Object Windows.Controls.Image -Property @{ Width = 16 * $scale; Height = 32 * $scale }
  if ($skin) { $img.Source = ConvertTo-Bitmap (New-Doll $skin) }
  [Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'NearestNeighbor')
  $img
}

function Open-Folder([string]$path) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
  Start-Process explorer.exe $path
}

# ---------------------------------------------------------------- import page

function Add-QueueSkin([byte[]]$bytes, [string]$name, [string]$source) {
  # Queues one skin. Returns the new queue item, or $null when that source is already queued; throws if it isn't a usable skin.
  if (@($script:Queue | Where-Object { $_.Path -eq $source }).Count) { return $null }
  $r = Convert-ToPg3dSkin (Read-Pixels $bytes)
  $item = [pscustomobject]@{ Path = $source; Skin = $r.Skin; Kind = $r.Kind; Size = $r.Size; Notes = $r.Notes; Card = $null; NameBox = $null }
  $item.Card = New-QueueCard $item ($name.Substring(0, [Math]::Min(20, $name.Length)))
  [void]$script:Queue.Add($item)
  [void]$script:ui.QueueList.Children.Add($item.Card)
  $item
}

function Add-QueueFiles([string[]]$paths) {
  $first = $null; $skipped = @()
  foreach ($path in $paths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try { $item = Add-QueueSkin ([IO.File]::ReadAllBytes($path)) ([IO.Path]::GetFileNameWithoutExtension($path)) $path }
    catch { $skipped += "$([IO.Path]::GetFileName($path)): $($_.Exception.Message)"; continue }
    if ($item -and -not $first) { $first = $item }
  }
  if ($first) { Select-QueueItem $first }
  Update-QueueState
  if ($skipped.Count) { Show-Toast ("Skipped " + ($skipped -join '  |  ')) 'error' }
}

function New-QueueCard($item, [string]$name) {
  $card = New-Object Windows.Controls.Border -Property @{ CornerRadius = 12; Background = '#141936'; BorderBrush = '#20264A'; BorderThickness = 1; Padding = '10'; Margin = '0,0,0,10'; Cursor = 'Hand'; Tag = $item }
  $grid = New-Object Windows.Controls.Grid
  foreach ($w in 'Auto', '*', 'Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$grid.ColumnDefinitions.Add($cd) }

  $tile = New-Object Windows.Controls.Border -Property @{ Width = 46; Height = 74; CornerRadius = 8; Background = $script:Window.FindResource('TileBrush') }
  $tile.Child = New-DollImage $item.Skin 2
  [void]$grid.Children.Add($tile)

  $mid = New-Object Windows.Controls.StackPanel -Property @{ Margin = '12,0,8,0'; VerticalAlignment = 'Center' }
  $box = New-Object Windows.Controls.TextBox -Property @{ Text = $name; Style = $script:Window.FindResource('Field') }
  $item.NameBox = $box
  $kind = New-Object Windows.Controls.TextBlock -Property @{ Text = "$($item.Kind)  $([char]0xB7)  $($item.Size)"; Foreground = '#7E88B5'; FontSize = 11; Margin = '2,7,0,0'; TextTrimming = 'CharacterEllipsis' }
  [void]$mid.Children.Add($box); [void]$mid.Children.Add($kind)
  [Windows.Controls.Grid]::SetColumn($mid, 1)
  [void]$grid.Children.Add($mid)

  $remove = New-Object Windows.Controls.Button -Property @{ Content = [string][char]0xE711; Style = $script:Window.FindResource('IconBtn'); VerticalAlignment = 'Top'; Tag = $item; ToolTip = 'Remove from queue' }
  $remove.Add_Click({ param($s, $e) Remove-QueueItem $s.Tag })
  [Windows.Controls.Grid]::SetColumn($remove, 2)
  [void]$grid.Children.Add($remove)

  $card.Child = $grid
  $card.Add_PreviewMouseLeftButtonDown({ param($s, $e) Select-QueueItem $s.Tag })
  $card.Add_MouseEnter({ param($s, $e) if ($s.Tag -ne $script:Selected) { $s.BorderBrush = '#3A4275' } })
  $card.Add_MouseLeave({ param($s, $e) if ($s.Tag -ne $script:Selected) { $s.BorderBrush = '#20264A' } })
  $card
}

function Select-QueueItem($item) {
  if ($script:Selected -and $script:Selected.Card) { $script:Selected.Card.BorderBrush = '#20264A'; $script:Selected.Card.Background = '#141936' }
  $script:Selected = $item
  if (-not $item) {
    $script:ui.Model1.Content = $null
    $script:ui.Stage1.Visibility = 'Collapsed'; $script:ui.DragHint.Visibility = 'Collapsed'; $script:ui.PreviewEmpty.Visibility = 'Visible'
    $script:ui.TexImg.Source = $null
    $script:ui.DetailKind.Text = 'Nothing selected'
    $script:ui.DetailNotes.Text = 'Pick a skin in the queue to see how it gets converted.'
    return
  }
  $item.Card.BorderBrush = '#7C5CFF'; $item.Card.Background = '#191F45'
  $script:ui.Model1.Content = New-SkinModel $item.Skin
  $script:ui.Stage1.Visibility = 'Visible'; $script:ui.DragHint.Visibility = 'Visible'; $script:ui.PreviewEmpty.Visibility = 'Collapsed'
  $script:ui.TexImg.Source = ConvertTo-Bitmap $item.Skin
  $script:ui.DetailKind.Text = "$($item.Kind)  ($($item.Size))"
  $script:ui.DetailNotes.Text = ($item.Notes | ForEach-Object { "$($script:Bullet)  $_" }) -join "`n"
}

function Remove-QueueItem($item) {
  $index = $script:Queue.IndexOf($item)
  $script:Queue.Remove($item)
  $script:ui.QueueList.Children.Remove($item.Card)
  if ($script:Selected -eq $item) {
    $script:Selected = $null
    $next = $null
    if ($script:Queue.Count) { $next = $script:Queue[[Math]::Min($index, $script:Queue.Count - 1)] }
    Select-QueueItem $next
  }
  Update-QueueState
}

function Clear-Queue {
  $script:Queue.Clear()
  $script:ui.QueueList.Children.Clear()
  $script:Selected = $null
  Select-QueueItem $null
  Update-QueueState
}

function Update-QueueState {
  $n = $script:Queue.Count
  $script:ui.QueueTitle.Text = $(if ($n) { "QUEUE  $([char]0xB7)  $n" } else { 'QUEUE' })
  $script:ui.QueueEmpty.Visibility = $(if ($n) { 'Collapsed' } else { 'Visible' })
  $script:ui.ClearQueueBtn.Visibility = $(if ($n) { 'Visible' } else { 'Collapsed' })
  $script:ui.ImportBtnText.Text = $(if ($n -gt 1) { "Add $n skins to Pixel Gun 3D" } else { 'Add to Pixel Gun 3D' })
  Update-GameStatus
}

function Invoke-Import {
  if (-not $script:Queue.Count) { return }
  $items = foreach ($q in $script:Queue) { [pscustomobject]@{ Skin = $q.Skin; Name = $q.NameBox.Text } }
  $result = Add-LocalSkins @($items)
  $n = $result.Ids.Count
  Clear-Queue
  Update-Library
  $what = if ($n -eq 1) { '1 skin' } else { "$n skins" }
  Show-Toast "Added $what. Start Pixel Gun 3D and open Wear $($script:Arrow) Skins: look for the phone icon." 'ok'
}

function Open-SkinPicker {
  $dialog = New-Object Microsoft.Win32.OpenFileDialog -Property @{ Filter = 'Skin images (*.png)|*.png|All images|*.png;*.jpg;*.jpeg;*.bmp;*.gif'; Multiselect = $true; Title = 'Choose skins to import' }
  if ($dialog.ShowDialog()) { Add-QueueFiles $dialog.FileNames }
}

# ---------------------------------------------------------------- get skins page

function New-SiteCard($site) {
  $card = New-Object Windows.Controls.Border -Property @{ Style = $script:Window.FindResource('Card'); Padding = '18'; Margin = '0,0,14,14' }
  $dock = New-Object Windows.Controls.DockPanel
  $tile = New-Object Windows.Controls.Border -Property @{ Width = 44; Height = 44; CornerRadius = 12; Background = $script:Window.FindResource($(if ($site.Group -eq 'pg3d') { 'WarmGradient' } else { 'AccentGradient' })); VerticalAlignment = 'Top' }
  $tile.Child = New-Object Windows.Controls.TextBlock -Property @{ Text = $site.Mark; Foreground = 'White'; FontWeight = 'Bold'; FontSize = 14; HorizontalAlignment = 'Center'; VerticalAlignment = 'Center' }
  [Windows.Controls.DockPanel]::SetDock($tile, 'Left')
  [void]$dock.Children.Add($tile)

  $open = New-Object Windows.Controls.Button -Property @{ Style = $script:Window.FindResource('GhostBtn'); VerticalAlignment = 'Top'; Margin = '12,0,0,0'; Tag = $site.Url; ToolTip = $site.Url }
  $label = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal' }
  [void]$label.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = 'Open'; VerticalAlignment = 'Center' }))
  [void]$label.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = [string][char]0xE8A7; FontFamily = $script:Window.FindResource('IconFont'); FontSize = 11; Margin = '8,0,0,0'; VerticalAlignment = 'Center' }))
  $open.Content = $label
  $open.Add_Click({ param($s, $e) Start-Process $s.Tag })
  [Windows.Controls.DockPanel]::SetDock($open, 'Right')
  [void]$dock.Children.Add($open)

  $text = New-Object Windows.Controls.StackPanel -Property @{ Margin = '14,0,0,0' }
  [void]$text.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $site.Name; FontSize = 15; FontWeight = 'SemiBold' }))
  [void]$text.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $site.Domain; FontSize = 12; Foreground = '#5C6590'; Margin = '0,1,0,0' }))
  [void]$text.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $site.About; Foreground = '#8C95BF'; TextWrapping = 'Wrap'; Margin = '0,8,0,0'; LineHeight = 19 }))
  $how = @{
    share    = @(0xE896, 'Download a skin someone shares: it lands in your queue')
    download = @(0xE896, 'Click Download on the site: it lands in your queue')
    paste    = @(0xE71B, 'Paste a skin page link above: instant import')
    username = @(0xE77B, 'Paste a player''s username above: instant import')
  }[$site.How]
  $chip = New-Object Windows.Controls.Border -Property @{ CornerRadius = 8; Background = '#1A2045'; Padding = '9,5'; Margin = '0,12,0,0'; HorizontalAlignment = 'Left' }
  $chipText = New-Object Windows.Controls.TextBlock -Property @{ FontSize = 11; Foreground = '#AEB6DA'; TextWrapping = 'Wrap' }
  $glyph = New-Object Windows.Documents.Run ([string][char]$how[0])
  $glyph.FontFamily = $script:Window.FindResource('IconFont'); $glyph.Foreground = '#22D3EE'
  [void]$chipText.Inlines.Add($glyph)
  [void]$chipText.Inlines.Add((New-Object Windows.Documents.Run ('  ' + $how[1])))
  $chip.Child = $chipText
  [void]$text.Children.Add($chip)
  [void]$dock.Children.Add($text)
  $card.Child = $dock
  $card
}

function Set-FetchBusy([bool]$busy) {
  $script:ui.FetchBtn.IsEnabled = -not $busy
  $script:ui.FetchText.Text = $(if ($busy) { 'Fetching...' } else { 'Fetch skin' })
  # Let the button repaint before the (short) blocking download starts.
  $script:Window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background)
}

function Invoke-WebFetch {
  $text = $script:ui.WebBox.Text
  if (-not $text -or -not $text.Trim()) { [void]$script:ui.WebBox.Focus(); return }
  Set-FetchBusy $true
  try {
    try { $r = Get-SkinFromWeb $text } catch { throw "Couldn't fetch that: $($_.Exception.Message)" }
    try { $item = Add-QueueSkin $r.Bytes $r.Name $r.Source } catch { throw "That download isn't a usable skin: $($_.Exception.Message)" }
    if (-not $item) { Show-Toast 'That skin is already in your queue.' 'info'; return }
    Select-QueueItem $item
    Update-QueueState
    $script:ui.WebBox.Text = ''
    $script:ui.NavImport.IsChecked = $true
    Show-Toast "Fetched ""$($r.Name)"" $($script:Dash) it's in the queue, ready to add." 'ok'
  } finally { Set-FetchBusy $false }
}

function Update-DownloadWatch {
  # Runs on the 1.5 s timer: queues skin-sized PNGs that appeared in Downloads after watching started.
  if (-not $script:ui.CatchToggle.IsChecked) { return }
  try { $files = ([IO.DirectoryInfo]$script:DownloadsDir).GetFiles('*.png') } catch { return }
  $settled = [DateTime]::UtcNow.AddSeconds(-1)   # give the browser a moment to finish writing
  $added = @()
  foreach ($f in $files) {
    if ($f.Extension -ne '.png' -or $f.LastWriteTimeUtc -le $script:WatchSince -or $f.LastWriteTimeUtc -gt $settled) { continue }
    if ($script:SeenDownloads.Contains($f.FullName)) { continue }
    try { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { continue }   # still locked: try again next tick
    [void]$script:SeenDownloads.Add($f.FullName)
    try { $item = Add-QueueSkin $bytes $f.BaseName $f.FullName } catch { continue }   # not a skin (other image sizes): ignore
    if ($item) { $added += $item }
  }
  if ($added.Count) {
    Select-QueueItem $added[0]
    Update-QueueState
    $script:ui.NavImport.IsChecked = $true
    $what = if ($added.Count -eq 1) { """$($added[0].NameBox.Text)""" } else { "$($added.Count) skins" }
    Show-Toast "Caught $what from your Downloads $($script:Dash) it's in the queue." 'info'
  }
}

# ---------------------------------------------------------------- my skins page

function New-SkinCard($entry) {
  $card = New-Object Windows.Controls.Border -Property @{ Width = 146; Margin = '0,0,14,14'; CornerRadius = 14; Background = '#141936'; BorderBrush = '#20264A'; BorderThickness = 1; Padding = '8'; Cursor = 'Hand'; Tag = $entry }
  $stack = New-Object Windows.Controls.StackPanel
  $tile = New-Object Windows.Controls.Border -Property @{ Height = 118; CornerRadius = 10; Background = $script:Window.FindResource('TileBrush') }
  $tile.Child = New-DollImage $entry.Skin 3
  [void]$stack.Children.Add($tile)
  $title = New-Object Windows.Controls.TextBlock -Property @{ Text = $(if ($entry.Name) { $entry.Name } else { '(no name)' }); FontWeight = 'SemiBold'; Margin = '4,10,4,0'; TextTrimming = 'CharacterEllipsis' }
  [void]$stack.Children.Add($title)
  $badge = New-Object Windows.Controls.TextBlock -Property @{ Margin = '4,3,4,2'; FontSize = 11; Foreground = '#7E88B5' }
  $glyph = New-Object Windows.Documents.Run ([string][char]$(if ($entry.Kind -eq 'local') { 0xE8EA } else { 0xE753 }))
  $glyph.FontFamily = $script:Window.FindResource('IconFont')
  $glyph.Foreground = $(if ($entry.Kind -eq 'local') { '#22D3EE' } else { '#A78BFA' })
  [void]$badge.Inlines.Add($glyph)
  [void]$badge.Inlines.Add((New-Object Windows.Documents.Run ($(if ($entry.Kind -eq 'local') { '  On this PC' } else { '  Account' }))))
  [void]$stack.Children.Add($badge)
  $card.Child = $stack
  $card.Add_MouseLeftButtonUp({ param($s, $e) Select-LibraryItem $s })
  $card.Add_MouseEnter({ param($s, $e) if ($s -ne $script:LibCard) { $s.BorderBrush = '#3A4275' } })
  $card.Add_MouseLeave({ param($s, $e) if ($s -ne $script:LibCard) { $s.BorderBrush = '#20264A' } })
  $card
}

function Select-LibraryItem($card) {
  if ($script:LibCard) { $script:LibCard.BorderBrush = '#20264A'; $script:LibCard.Background = '#141936' }
  $script:LibCard = $card
  Reset-DeleteButton
  if (-not $card) {
    $script:ui.Model2.Content = $null
    $script:ui.Stage2.Visibility = 'Collapsed'; $script:ui.LibEmpty.Visibility = 'Visible'
    $script:ui.LibName.Text = ''; $script:ui.LibKind.Text = ''; $script:ui.LibActions.Visibility = 'Collapsed'
    return
  }
  $entry = $card.Tag
  $card.BorderBrush = '#7C5CFF'; $card.Background = '#191F45'
  $script:ui.LibName.Text = $(if ($entry.Name) { $entry.Name } else { '(no name)' })
  $when = if ($entry.Created) { " $($script:Dash) added $($entry.Created.ToString('d MMM yyyy'))" } else { '' }
  $script:ui.LibKind.Text = $(if ($entry.Kind -eq 'local') { "Local skin on this PC$when" } else { "Synced to your account$when" })
  $script:ui.LibActions.Visibility = 'Visible'
  $script:ui.DeleteBtn.Visibility = $(if ($entry.Kind -eq 'local') { 'Visible' } else { 'Collapsed' })
  $script:ui.ExportBtn.IsEnabled = [bool]$entry.Skin
  if ($entry.Skin) {
    $script:ui.Model2.Content = New-SkinModel $entry.Skin
    $script:ui.Stage2.Visibility = 'Visible'; $script:ui.LibEmpty.Visibility = 'Collapsed'
  } else {
    $script:ui.Model2.Content = $null
    $script:ui.Stage2.Visibility = 'Collapsed'; $script:ui.LibEmpty.Visibility = 'Visible'
  }
  Update-GameStatus
}

function Update-Library {
  $selectedId = if ($script:LibCard) { $script:LibCard.Tag.Id } else { $null }
  $script:LibCard = $null
  $script:ui.LocalList.Children.Clear(); $script:ui.CloudList.Children.Clear()
  $local = @(); $cloud = @(); $problem = $null
  try { $local = @(Get-LocalSkins) } catch { $problem = $_.Exception.Message }
  try { $cloud = @(Get-CloudSkins) } catch { if (-not $problem) { $problem = $_.Exception.Message } }
  [Array]::Reverse($local); [Array]::Reverse($cloud)   # newest first
  $reselect = $null
  foreach ($set in @(@($local, $script:ui.LocalList), @($cloud, $script:ui.CloudList))) {
    foreach ($entry in $set[0]) {
      $card = New-SkinCard $entry
      [void]$set[1].Children.Add($card)
      if ($entry.Id -eq $selectedId) { $reselect = $card }
    }
  }
  $script:ui.LocalCount.Text = "   $($local.Count)"
  $script:ui.CloudCount.Text = "   $($cloud.Count)"
  $script:ui.LocalEmpty.Visibility = $(if ($local.Count) { 'Collapsed' } else { 'Visible' })
  $script:ui.CloudEmpty.Visibility = $(if ($cloud.Count) { 'Collapsed' } else { 'Visible' })
  if ($problem) { $script:ui.LocalEmpty.Text = $problem; $script:ui.LocalEmpty.Visibility = 'Visible' }
  Select-LibraryItem $reselect
}

function Reset-DeleteButton {
  $script:DeleteArmed = $false
  if ($script:DeleteTimer) { $script:DeleteTimer.Stop() }
  $script:ui.DeleteText.Text = 'Delete'
  $script:ui.DeleteBtn.ClearValue([Windows.Controls.Control]::BackgroundProperty)
  $script:ui.DeleteBtn.ClearValue([Windows.Controls.Control]::ForegroundProperty)
}

function Invoke-Delete {
  $entry = $script:LibCard.Tag
  if (-not $script:DeleteArmed) {
    # First click arms the button; a second click within 4 seconds deletes.
    $script:DeleteArmed = $true
    $script:ui.DeleteText.Text = 'Click again to delete'
    $script:ui.DeleteBtn.Background = '#B42335'
    $script:ui.DeleteBtn.Foreground = '#FFFFFF'
    $script:DeleteTimer.Start()
    return
  }
  Reset-DeleteButton
  [void](Remove-LocalSkin $entry.Id)
  $script:LibCard = $null
  Update-Library
  Show-Toast "Deleted ""$(if ($entry.Name) { $entry.Name } else { 'skin' })"" from this PC. A backup was saved first." 'ok'
}

function Invoke-Export {
  $entry = $script:LibCard.Tag
  $safe = (($(if ($entry.Name) { $entry.Name } else { 'skin' })) -replace '[\\/:*?"<>|]', '_').Trim()
  $dialog = New-Object Microsoft.Win32.SaveFileDialog -Property @{ Filter = 'PNG image (*.png)|*.png'; FileName = "$safe.png"; Title = 'Export skin' }
  if ($dialog.ShowDialog()) {
    [IO.File]::WriteAllBytes($dialog.FileName, (ConvertTo-Png $entry.Skin))
    Show-Toast "Saved $([IO.Path]::GetFileName($dialog.FileName))" 'ok'
  }
}

# ---------------------------------------------------------------- game status

function Update-GameStatus {
  $running = Test-GameRunning
  if ($running) {
    $script:ui.StatusDot.Fill = '#FBBF24'; $script:ui.StatusText.Text = 'Pixel Gun 3D is running'
  } else {
    $script:ui.StatusDot.Fill = '#34D399'; $script:ui.StatusText.Text = 'Pixel Gun 3D is closed'
  }
  $script:ui.ImportBtn.IsEnabled = ($script:Queue.Count -gt 0) -and -not $running
  $script:ui.GameWarning.Visibility = $(if ($running) { 'Visible' } else { 'Collapsed' })
  $script:ui.ReadyHint.Visibility = $(if ($running) { 'Collapsed' } else { 'Visible' })
  $script:ui.DeleteBtn.IsEnabled = -not $running
  $script:ui.DeleteBtn.ToolTip = $(if ($running) { 'Close Pixel Gun 3D first' } else { $null })
  if ($script:WasRunning -and -not $running) { Update-Library }   # the game may have changed its skins while it ran
  $script:WasRunning = $running
}

# ---------------------------------------------------------------- build the window

function New-ImporterWindow {
  $window = [Windows.Markup.XamlReader]::Parse($script:Xaml)
  $script:Window = $window
  $script:ui = @{}
  foreach ($n in $script:UiNames) { $script:ui[$n] = $window.FindName($n) }
  $script:Queue = New-Object Collections.ArrayList
  $script:Selected = $null
  $script:LibCard = $null
  $script:WasRunning = $false
  $script:DeleteArmed = $false

  $logo = New-LogoCanvas
  $script:ui.LogoImg.Source = ConvertTo-Bitmap $logo
  $script:ui.EmptyLogo.Source = ConvertTo-Bitmap $logo
  $window.Icon = ConvertTo-UpscaledBitmap $logo 4

  # window chrome
  $script:ui.BtnMin.Add_Click({ $script:Window.WindowState = 'Minimized' })
  $script:ui.BtnMax.Add_Click({ $script:Window.WindowState = $(if ($script:Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
  $script:ui.BtnClose.Add_Click({ $script:Window.Close() })
  $window.Add_StateChanged({
    $max = $script:Window.WindowState -eq 'Maximized'
    $script:ui.Root.Margin = $(if ($max) { '7' } else { '0' })   # a maximised chrome-less window overhangs the screen edge
    $script:ui.BtnMax.Content = [string][char]$(if ($max) { 0xE923 } else { 0xE922 })
  })

  # menu
  $script:ui.NavImport.Add_Checked({ Show-Page 'PageImport' })
  $script:ui.NavWeb.Add_Checked({ Show-Page 'PageWeb' })
  $script:ui.NavLibrary.Add_Checked({ Show-Page 'PageLibrary' })
  $script:ui.NavHelp.Add_Checked({ Show-Page 'PageHelp' })

  # import page
  $script:ui.DropZone.Add_MouseLeftButtonUp({ Invoke-Safe { Open-SkinPicker } })
  $window.Add_DragEnter({ $script:ui.DropRect.Stroke = '#22D3EE'; $script:ui.DropRect.Fill = '#141A38' })
  $window.Add_DragLeave({ $script:ui.DropRect.Stroke = '#343C6E'; $script:ui.DropRect.Fill = '#10142A' })
  $window.Add_Drop({
    param($s, $e)
    $script:ui.DropRect.Stroke = '#343C6E'; $script:ui.DropRect.Fill = '#10142A'
    $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    if ($files) {
      $script:ui.NavImport.IsChecked = $true
      Invoke-Safe { Add-QueueFiles $files }
    }
  })
  $script:ui.ClearQueueBtn.Add_Click({ Clear-Queue })
  $script:ui.ImportBtn.Add_Click({ Invoke-Safe { Invoke-Import } })
  Initialize-Spinner $script:ui.Stage1 $script:ui.Spin1 $script:ui.Cam1

  # my skins page
  Initialize-Spinner $script:ui.Stage2 $script:ui.Spin2 $script:ui.Cam2
  $script:ui.RefreshBtn.Add_Click({ Invoke-Safe { Update-Library; Show-Toast 'Skin list refreshed.' 'info' } })
  $script:ui.LibBackupsBtn.Add_Click({ Open-Folder $script:BackupDir })
  $script:ui.HelpBackupsBtn.Add_Click({ Open-Folder $script:BackupDir })
  $script:ui.ExportBtn.Add_Click({ Invoke-Safe { Invoke-Export } })
  $script:ui.DeleteBtn.Add_Click({ Invoke-Safe { Invoke-Delete } })
  $script:DeleteTimer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(4) }
  $script:DeleteTimer.Add_Tick({ Reset-DeleteButton })

  # get skins page
  foreach ($site in $script:Sites) {
    $grid = if ($site.Group -eq 'pg3d') { $script:ui.Pg3dGrid } else { $script:ui.SiteGrid }
    [void]$grid.Children.Add((New-SiteCard $site))
  }
  $script:ui.FetchBtn.Add_Click({ Invoke-Safe { Invoke-WebFetch } })
  $script:ui.WebBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Invoke-Safe { Invoke-WebFetch } } })
  $script:ui.WebBox.Add_TextChanged({ $script:ui.WebHint.Visibility = $(if ($script:ui.WebBox.Text) { 'Collapsed' } else { 'Visible' }) })
  $script:DownloadsDir = Get-DownloadsFolder
  $script:SeenDownloads = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $script:WatchSince = [DateTime]::UtcNow   # only downloads from now on, never old files
  $script:Settings = Get-Settings
  $script:ui.CatchToggle.IsChecked = [bool]$script:Settings.catchDownloads
  $script:ui.CatchHint.Text = "While this app is open, skin PNGs you download from any site go straight into your queue (nothing is added to the game until you click Add). Watching $($script:DownloadsDir)"
  $script:ui.CatchToggle.Add_Click({
    $on = [bool]$script:ui.CatchToggle.IsChecked
    if ($on) { $script:WatchSince = [DateTime]::UtcNow }
    $script:Settings.catchDownloads = $on
    Invoke-Safe { Save-Settings $script:Settings }
  })

  # toast + game watcher
  $script:ToastTimer = New-Object Windows.Threading.DispatcherTimer
  $script:ToastTimer.Add_Tick({ Hide-Toast })
  $script:GameTimer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(1.5) }
  $script:GameTimer.Add_Tick({ Update-GameStatus; Update-DownloadWatch })
  $script:GameTimer.Start()
  $window.Add_Closed({ $script:GameTimer.Stop(); $script:ToastTimer.Stop(); $script:DeleteTimer.Stop() })
  $window.Dispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true; Show-Toast $e.Exception.Message 'error' })

  Update-QueueState
  Update-Library
  $window
}

if ($MyInvocation.InvocationName -ne '.') {
  try {
    $window = New-ImporterWindow
    [void]$window.ShowDialog()
  } catch {
    [void][Windows.MessageBox]::Show("Something went wrong:`n`n$($_.Exception.Message)", 'Skin Importer for Pixel Gun 3D', 'OK', 'Error')
  }
}
