<#
.SYNOPSIS
    Compiles RouterApp.ps1 (GUI) into a standalone PCRouter.exe
#>

$SourceGUI = Join-Path $PSScriptRoot "RouterApp.ps1"
$SourceCore = Join-Path $PSScriptRoot "Core-Router.psm1"
$ConfigExample = Join-Path $PSScriptRoot "config.example.json"
$OutputExe = Join-Path $PSScriptRoot "PCRouter.exe"

if (-not (Test-Path $SourceGUI)) { Write-Error "Source GUI not found!"; exit }
if (-not (Test-Path $SourceCore)) { Write-Error "Source Core not found!"; exit }

# Read and Encode Scripts
$ContentGUI = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([System.IO.File]::ReadAllText($SourceGUI)))
$ContentCore = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([System.IO.File]::ReadAllText($SourceCore)))

# C# Wrapper Code
$CSharpCode = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Threading;
// using System.Windows.Forms; // Requires Reference

public class Program {
    [STAThread] // Required for GUI
    public static void Main(string[] args) {
        // 1. Mutex to prevent multiple instances
        bool createdNew;
        Mutex mutex = new Mutex(true, "PCRouterAppMutex", out createdNew);
        if (!createdNew) {
            return; // Already running
        }

        // 2. Admin Check
        if (!IsAdmin()) {
            try {
                ProcessStartInfo proc = new ProcessStartInfo();
                proc.UseShellExecute = true;
                proc.WorkingDirectory = Environment.CurrentDirectory;
                proc.FileName = System.Reflection.Assembly.GetEntryAssembly().Location;
                proc.Verb = "runas";
                Process.Start(proc);
                return;
            } catch {
                return; // User cancelled
            }
        }

        try {
            string tempDir = Path.Combine(Path.GetTempPath(), "PCRouter_" + Guid.NewGuid().ToString().Substring(0, 8));
            Directory.CreateDirectory(tempDir);
            
            // Extract Files
            WriteFile(tempDir, "RouterApp.ps1", "$ContentGUI");
            WriteFile(tempDir, "Core-Router.psm1", "$ContentCore");
            
            string scriptPath = Path.Combine(tempDir, "RouterApp.ps1");
            string exeDir = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);

            // Execute Hidden PowerShell
            ProcessStartInfo item = new ProcessStartInfo();
            item.FileName = "powershell.exe";
            item.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\" -BaseDir \"" + exeDir + "\"";
            item.UseShellExecute = false;
            item.CreateNoWindow = true; // Important for Tray App
            
            Process p = Process.Start(item);
            p.WaitForExit(); // Wait until App.ps1 exits (User clicks Exit in Tray)
            
            // Cleanup
            try { Directory.Delete(tempDir, true); } catch {}
            
        } catch {
            // Log error?
        }
    }

    static void WriteFile(string dir, string name, string b64) {
        byte[] bytes = Convert.FromBase64String(b64);
        string text = Encoding.Unicode.GetString(bytes);
        File.WriteAllText(Path.Combine(dir, name), text);
    }

    static bool IsAdmin() {
        WindowsIdentity id = WindowsIdentity.GetCurrent();
        WindowsPrincipal principal = new WindowsPrincipal(id);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }
}
"@

Write-Host "Compiling PCRouter.exe (GUI)..." -ForegroundColor Cyan

$ReferencedAssemblies = @("System.dll", "System.Core.dll", "System.Windows.Forms.dll")

try {
    Add-Type -TypeDefinition $CSharpCode `
        -OutputAssembly $OutputExe `
        -OutputType WindowsApplication `
        -ReferencedAssemblies $ReferencedAssemblies `
        -Language CSharp
             
    Write-Host "Compilation Success!" -ForegroundColor Green
    Write-Host "Created: $OutputExe"
}
catch {
    Write-Error "Compilation Failed: $_"
}
