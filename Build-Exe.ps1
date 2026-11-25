<#
  Builds "dist\PG3D Skin Importer.exe", a standalone Windows app.
  The .exe is a tiny launcher (compiled with the C# compiler that ships with .NET Framework 4.x) that carries
  PG3D-Skin-Importer.ps1 inside it and runs it in-process: no console window, no execution-policy prompt.

  Re-run after editing the script:   powershell -NoProfile -ExecutionPolicy Bypass -File Build-Exe.ps1
  Add -Install to copy it to %LOCALAPPDATA%\Programs\PG3D Skin Importer with Desktop and Start menu shortcuts.
#>
param([switch]$Install)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$app  = Join-Path $root 'PG3D-Skin-Importer.ps1'
$dist = Join-Path $root 'dist'
$exe  = Join-Path $dist 'PG3D Skin Importer.exe'
$work = Join-Path $env:TEMP 'pg3d-skin-importer-build'
New-Item -ItemType Directory -Force -Path $dist, $work | Out-Null

. $app   # reuse the app's pixel helpers for the icon (dot-sourcing doesn't open the window)

# ---------------------------------------------------------------- icon from the pixel-art logo

function ConvertTo-IconDib($c) {
  # 32-bit BMP-style icon image: header, bottom-up BGRA rows, then an empty AND mask (alpha does the work).
  $ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms
  $bw.Write([int]40); $bw.Write([int]$c.W); $bw.Write([int]($c.H * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
  for ($i = 0; $i -lt 6; $i++) { $bw.Write([int]0) }
  for ($y = $c.H - 1; $y -ge 0; $y--) { $bw.Write($c.Px, $y * $c.W * 4, $c.W * 4) }
  $bw.Write((New-Object byte[] ([int]([Math]::Ceiling($c.W / 32)) * 4 * $c.H)))
  $bw.Flush()
  , $ms.ToArray()
}

$logo = New-LogoCanvas
$images = @()
foreach ($size in 16, 24, 32, 48, 64, 256) {
  $big = Resize-Nearest $logo ($size / 8)
  $data = if ($size -eq 256) { ConvertTo-Png $big } else { ConvertTo-IconDib $big }
  $images += , @($size, $data)
}
$ico = Join-Path $work 'app.ico'
$ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
  $dim = [byte]$(if ($img[0] -ge 256) { 0 } else { $img[0] })
  $bw.Write($dim); $bw.Write($dim); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]$img[1].Length); $bw.Write([int]$offset)
  $offset += $img[1].Length
}
foreach ($img in $images) { $bw.Write([byte[]]$img[1]) }
$bw.Flush()
[IO.File]::WriteAllBytes($ico, $ms.ToArray())

# ---------------------------------------------------------------- launcher

$source = @'
using System;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("PG3D Skin Importer")]
[assembly: AssemblyProduct("Skin Importer for Pixel Gun 3D")]
[assembly: AssemblyDescription("Skin Importer for Pixel Gun 3D")]
[assembly: AssemblyCopyright("Unofficial fan-made tool")]
[assembly: AssemblyVersion("{{VERSION}}")]
[assembly: AssemblyFileVersion("{{VERSION}}")]

static class Program
{
    [STAThread]
    static int Main()
    {
        try
        {
            string script;
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ps1"))
            using (StreamReader r = new StreamReader(s))
            {
                script = r.ReadToEnd();
            }
            using (Runspace rs = RunspaceFactory.CreateRunspace())
            {
                // The window has to live on this STA thread, so the script runs right here.
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    ps.Invoke();
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Skin Importer could not start:\n\n" + ex.Message, "Skin Importer for Pixel Gun 3D", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }
}
'@
$cs = Join-Path $work 'Launcher.cs'
[IO.File]::WriteAllText($cs, $source.Replace('{{VERSION}}', "$($script:Version).0.0"))

$fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
if (-not (Test-Path (Join-Path $fw 'csc.exe'))) { $fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319' }
$refs = "/r:$([PSObject].Assembly.Location)", "/r:$fw\WPF\PresentationFramework.dll", "/r:$fw\WPF\PresentationCore.dll", "/r:$fw\WPF\WindowsBase.dll", "/r:$fw\System.Xaml.dll"
$log = & (Join-Path $fw 'csc.exe') /nologo /optimize+ /target:winexe "/out:$exe" "/win32icon:$ico" "/resource:$app,app.ps1" @refs $cs 2>&1
if ($LASTEXITCODE -ne 0) { $log; throw 'Compiling the launcher failed.' }
"Built $exe ($([int]((Get-Item -LiteralPath $exe).Length / 1KB)) KB)"

# ---------------------------------------------------------------- install

if ($Install) {
  if (Get-Process -Name 'PG3D Skin Importer' -ErrorAction SilentlyContinue) { throw 'Close PG3D Skin Importer first, then install again.' }
  $dir = Join-Path $env:LOCALAPPDATA 'Programs\PG3D Skin Importer'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $target = Join-Path $dir 'PG3D Skin Importer.exe'
  Copy-Item -LiteralPath $exe -Destination $target -Force
  $shell = New-Object -ComObject WScript.Shell
  foreach ($folder in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    $lnk = $shell.CreateShortcut((Join-Path $folder 'PG3D Skin Importer.lnk'))
    $lnk.TargetPath = $target
    $lnk.WorkingDirectory = $dir
    $lnk.IconLocation = "$target,0"
    $lnk.Description = 'Skin Importer for Pixel Gun 3D'
    $lnk.Save()
  }
  "Installed $target with Desktop and Start menu shortcuts"
}
