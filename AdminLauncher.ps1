<#
.SYNOPSIS
    Dynamic WPF-based multi-application launcher with Auto-Launch capabilities,
    Windows 11 Mica/Fluent UI, custom icons, and an embedded HTML Config Editor.
.DESCRIPTION
    Self-elevates to provide administrative tokens to all launched child processes.
    Reads configuration from a JSON file, auto-launches designated apps, 
    and dynamically builds the UI for manual launching.
    Includes aggressive Topmost enforcement to always display above the taskbar.
#>
[CmdletBinding()]
param ()

# -------------------------------------------------------------------------
# 1. Self-Elevation Check (Ensure Admin Context)
# -------------------------------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]$currentIdentity
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warning "Elevating permissions..."
    $processParams = @{
        FilePath     = 'powershell.exe'
        ArgumentList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        Verb         = 'RunAs'
        ErrorAction  = 'Stop'
    }
    try {
        Start-Process @processParams
    } catch {
        [System.Windows.MessageBox]::Show("Failed to elevate process.", "Elevation Error", 0, 16)
    }
    exit
}

# -------------------------------------------------------------------------
# 2. Compile C# Interop (Windows 11 DWM & HTML/JS Bridge)
# -------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName Microsoft.CSharp
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$csharpCode = @"
using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Win11Interop8 {
    public class Theme {
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

        [DllImport("dwmapi.dll")]
        public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS pMarInset);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [StructLayout(LayoutKind.Sequential)]
        public struct MARGINS {
            public int cxLeftWidth;
            public int cxRightWidth;
            public int cyTopHeight;
            public int cyBottomHeight;
        }

        public static void ApplyMica(Window window, bool isDark) {
            IntPtr hwnd = new WindowInteropHelper(window).EnsureHandle();
            int isDarkValue = isDark ? 1 : 0;
            int backdropType = 2; // 2 = Mica, 3 = Acrylic
            
            DwmSetWindowAttribute(hwnd, 20, ref isDarkValue, sizeof(int));
            DwmSetWindowAttribute(hwnd, 38, ref backdropType, sizeof(int));

            MARGINS margins = new MARGINS { cxLeftWidth = -1, cxRightWidth = -1, cyTopHeight = -1, cyBottomHeight = -1 };
            DwmExtendFrameIntoClientArea(hwnd, ref margins);

            HwndSource source = HwndSource.FromHwnd(hwnd);
            if (source != null && source.CompositionTarget != null) {
                source.CompositionTarget.BackgroundColor = Colors.Transparent;
            }
        }

        public static void ForceTopmost(Window window) {
            try {
                IntPtr hwnd = new WindowInteropHelper(window).EnsureHandle();
                // HWND_TOPMOST = -1
                // SWP_NOSIZE (0x0001) | SWP_NOMOVE (0x0002) | SWP_NOACTIVATE (0x0010) = 0x0013
                SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0013);
            } catch { }
        }
    }

    [ComVisible(true)]
    public class ConfigBridge {
        public string JsonData { get; set; }
        public Action<string> OnSave { get; set; }
        public Action OnClose { get; set; }
        public Dispatcher UIDispatcher { get; set; } // Required to prevent STA thread exceptions

        public string GetConfig() { return JsonData; }
        
        public void SaveConfig(string json) { 
            if (OnSave != null) { OnSave(json); }
        }
        
        public void Close() { 
            if (OnClose != null) { OnClose(); }
        }

        public string BrowseFile() {
            if (UIDispatcher == null) return "";
            
            // Safely marshal execution to the main WPF UI thread
            return (string)UIDispatcher.Invoke(new Func<string>(() => {
                var dlg = new Microsoft.Win32.OpenFileDialog();
                dlg.Filter = "Programs & Shortcuts|*.exe;*.msc;*.bat;*.cmd;*.ps1;*.lnk|All Files|*.*";
                dlg.Title = "Select Application or Shortcut";
                
                if (dlg.ShowDialog() == true) {
                    string selectedPath = dlg.FileName;
                    if (selectedPath.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)) {
                        try {
                            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                            dynamic shell = Activator.CreateInstance(shellType);
                            dynamic shortcut = shell.CreateShortcut(selectedPath);
                            if (!string.IsNullOrWhiteSpace(shortcut.TargetPath)) {
                                selectedPath = shortcut.TargetPath;
                            }
                        } catch { }
                    }
                    return selectedPath;
                }
                return "";
            }));
        }

        public string BrowseIcon() {
            if (UIDispatcher == null) return "";

            return (string)UIDispatcher.Invoke(new Func<string>(() => {
                var dlg = new Microsoft.Win32.OpenFileDialog();
                dlg.Filter = "Image Files|*.ico;*.png;*.jpg;*.jpeg;*.bmp|All Files|*.*";
                dlg.Title = "Select Custom Icon";
                
                if (dlg.ShowDialog() == true) {
                    return dlg.FileName;
                }
                return "";
            }));
        }
    }
}
"@

if (-not ("Win11Interop8.Theme" -as [type])) {
    try {
        Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies "PresentationFramework", "PresentationCore", "WindowsBase", "System.Xaml", "Microsoft.CSharp"
    } catch {
        Write-Warning "C# compilation failed. Types may already be loaded in this session. $_"
    }
}

# State flag for Settings window to prevent Z-Order conflicts
$global:IsEditing = $false

# -------------------------------------------------------------------------
# 3. Configuration Management
# -------------------------------------------------------------------------
$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "LauncherConfig.json"

function Initialize-Config {
    $defaultConfig = [pscustomobject]@{
        Theme = "Dark"
        Apps = @(
            [pscustomobject]@{ Name = "Command Prompt"; Path = "cmd.exe"; Arguments = ""; Icon = ""; AutoLaunch = $false },
            [pscustomobject]@{ Name = "Registry Editor"; Path = "regedit.exe"; Arguments = ""; Icon = ""; AutoLaunch = $false },
            [pscustomobject]@{ Name = "Computer Mgmt"; Path = "compmgmt.msc"; Arguments = ""; Icon = ""; AutoLaunch = $false },
            [pscustomobject]@{ Name = "PowerShell"; Path = "powershell.exe"; Arguments = ""; Icon = ""; AutoLaunch = $false }
        )
    }
    $defaultConfig | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8
    return $defaultConfig
}

if (-not (Test-Path -Path $ConfigPath)) {
    $global:AppConfig = Initialize-Config
} else {
    try {
        $rawConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        if ($rawConfig -is [array]) {
            $global:AppConfig = [pscustomobject]@{ Theme = "Dark"; Apps = $rawConfig }
            $global:AppConfig | ConvertTo-Json -Depth 3 | Set-Content -Path $ConfigPath -Encoding UTF8
        } else {
            $global:AppConfig = $rawConfig
        }
    } catch {
        $global:AppConfig = Initialize-Config
    }
}

$global:Apps = @($global:AppConfig.Apps)
$global:IsDarkTheme = ($global:AppConfig.Theme -eq "Dark")

# -------------------------------------------------------------------------
# 4. Execution Helper & Icon Extractor
# -------------------------------------------------------------------------
function Invoke-AdminApp {
    param([string]$Path, [string]$Arguments = "")
    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($Path)
    $launchParams = @{ FilePath = $expandedPath; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $launchParams.ArgumentList = [System.Environment]::ExpandEnvironmentVariables($Arguments)
    }
    try {
        Start-Process @launchParams
    } catch {
        [System.Windows.MessageBox]::Show("Failed to launch: $expandedPath`nError: $_", "Execution Error", 0, 16)
    }
}

function Get-AppIconSource {
    param([string]$AppPath, [string]$CustomIconPath)

    if (-not [string]::IsNullOrWhiteSpace($CustomIconPath)) {
        $expandedCustom = [System.Environment]::ExpandEnvironmentVariables($CustomIconPath)
        if (Test-Path $expandedCustom) {
            try {
                $uri = New-Object System.Uri($expandedCustom, [System.UriKind]::Absolute)
                $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.UriSource = $uri
                $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bmp.EndInit()
                return $bmp
            } catch { Write-Warning "Failed to load custom icon: $expandedCustom" }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AppPath)) {
        $targetPath = [System.Environment]::ExpandEnvironmentVariables($AppPath)

        if ($targetPath.EndsWith(".lnk", "OrdinalIgnoreCase")) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($targetPath)
                if (-not [string]::IsNullOrWhiteSpace($shortcut.TargetPath)) {
                    $targetPath = $shortcut.TargetPath
                }
            } catch {}
        }

        if (-not (Test-Path $targetPath)) {
            $foundPath = (Get-Command $targetPath -ErrorAction Ignore).Source
            if ($foundPath) { $targetPath = $foundPath }
        }

        if (Test-Path $targetPath) {
            try {
                $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($targetPath)
                if ($icon) {
                    $imageSource = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                        $icon.Handle,
                        [System.Windows.Int32Rect]::Empty,
                        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
                    )
                    $icon.Dispose()
                    return $imageSource
                }
            } catch { Write-Warning "Failed to extract icon from: $targetPath" }
        }
    }
    return $null
}

$runningProcesses = Get-CimInstance Win32_Process -Property CommandLine

$global:Apps | Where-Object { $_.AutoLaunch -eq $true } | ForEach-Object {
    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($_.Path)
    $expandedArgs = [System.Environment]::ExpandEnvironmentVariables($_.Arguments)
    $fileName = [System.IO.Path]::GetFileName($expandedPath)
    
    $matchPath = if ($expandedPath -match '\\') { [regex]::Escape($expandedPath) } else { [regex]::Escape($fileName) }
    $matchArgs = if (-not [string]::IsNullOrWhiteSpace($expandedArgs)) { [regex]::Escape($expandedArgs) } else { $null }
    
    $isRunning = $false
    foreach ($proc in $runningProcesses) {
        if ([string]::IsNullOrWhiteSpace($proc.CommandLine)) { continue }
        if ($proc.CommandLine -match $matchPath) {
            if (-not $matchArgs -or $proc.CommandLine -match $matchArgs) {
                $isRunning = $true
                break
            }
        }
    }

    if (-not $isRunning) {
        Invoke-AdminApp -Path $_.Path -Arguments $_.Arguments
    }
}

# -------------------------------------------------------------------------
# 5. UI Definition — Main Window (Toolbar Style)
# -------------------------------------------------------------------------

# Theme-aware color values
$fgColor       = if ($global:IsDarkTheme) { "#F8FAFC" }   else { "#1E293B" }
$fgMuted       = if ($global:IsDarkTheme) { "#94A3B8" }   else { "#64748B" }
$headerBg      = if ($global:IsDarkTheme) { "#0F172A" }   else { "#E2E8F0" }
$cardBg        = if ($global:IsDarkTheme) { "#1E293B" }   else { "#FFFFFF" }
$cardBorder    = if ($global:IsDarkTheme) { "#334155" }   else { "#E2E8F0" }
$cardHover     = if ($global:IsDarkTheme) { "#38BDF8" }   else { "#00AEEF" }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Admin App Launcher" Width="700" Height="60" MinWidth="430" MinHeight="45"
        WindowStartupLocation="CenterScreen" Background="Transparent"
        FontFamily="Segoe UI Variable, Segoe UI" WindowStyle="None" Topmost="True"
        ResizeMode="CanResizeWithGrip">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" ResizeBorderThickness="5" GlassFrameThickness="-1" />
    </WindowChrome.WindowChrome>
    <Window.Resources>
        
        <!-- ── App & Settings tile ── -->
        <Style TargetType="Button" x:Key="AppTileButton">
            <Setter Property="Background"      Value="$cardBg"/>
            <Setter Property="Foreground"      Value="$fgColor"/>
            <Setter Property="BorderBrush"     Value="$cardBorder"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="MaxHeight"       Value="48"/>
            <Setter Property="MaxWidth"        Value="48"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="BorderBrush" Value="$cardHover"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="$headerBg"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- ── Close tile button ── -->
        <Style TargetType="Button" x:Key="CloseTileButton">
            <Setter Property="Background"      Value="$cardBg"/>
            <Setter Property="Foreground"      Value="$fgMuted"/>
            <Setter Property="BorderBrush"     Value="Transparent"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="MaxHeight"       Value="48"/>
            <Setter Property="MaxWidth"        Value="48"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="3"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#E81123"/>
                    <Setter Property="Foreground" Value="White"/>
                    <Setter Property="BorderBrush" Value="#E81123"/>
                </Trigger>
                <Trigger Property="IsPressed" Value="True">
                    <Setter Property="Background" Value="#8B0A15"/>
                    <Setter Property="BorderBrush" Value="#8B0A15"/>
                </Trigger>
            </Style.Triggers>
        </Style>

    </Window.Resources>

    <!-- Background set to #01000000 (1% opacity black) to ensure WPF registers mouse clicks for DragMove -->
    <Grid Name="MainGrid" Background="#01000000" Margin="2" Cursor="SizeAll">
        <Grid.ColumnDefinitions>
            <!-- App shortcuts area -->
            <ColumnDefinition Width="*"/>
            <!-- Settings and Close area -->
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- ── App tile grid (StackPanel for stretching height) ── -->
        <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Auto" Margin="0,0,0,0">
            <StackPanel Name="AppContainer" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Stretch"/>
        </ScrollViewer>

        <!-- ── Toolbar Controls ── -->
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Stretch">
            <!-- Separator Line -->
            <Border Width="1" Background="$cardBorder" Margin="2,2,2,2" CornerRadius="8"/>
            
            <!-- Pin Button (Width bounds to height automatically keeping it square) -->
            <Button Name="BtnPin" Style="{StaticResource AppTileButton}" Margin="3" ToolTip="Pinned (Click to Unpin)" Width="{Binding RelativeSource={RelativeSource Self}, Path=ActualHeight}">
                <Viewbox Margin="6" Stretch="Uniform">
                    <TextBlock Name="PinIcon" FontFamily="Segoe Fluent Icons" Text="&#xE718;" Foreground="LightSkyBlue"/>
                </Viewbox>
            </Button>
            
            <!-- Settings Button -->
            <Button Name="BtnEditConfig" Style="{StaticResource AppTileButton}" Margin="3" ToolTip="Settings" Width="{Binding RelativeSource={RelativeSource Self}, Path=ActualHeight}">
                <Viewbox Margin="6" Stretch="Uniform">
                    <TextBlock FontFamily="Segoe Fluent Icons" Text="&#xE713;"/>
                </Viewbox>
            </Button>

            <!-- Close Button -->
            <Button Name="BtnClose" Style="{StaticResource CloseTileButton}" Margin="3" ToolTip="Close" Width="{Binding RelativeSource={RelativeSource Self}, Path=ActualHeight}">
                <Viewbox Margin="6" Stretch="Uniform">
                    <TextBlock FontFamily="Segoe Fluent Icons" Text="&#xE8BB;"/>
                </Viewbox>
            </Button>
        </StackPanel>
    </Grid>
</Window>
"@

$stringReader = [System.IO.StringReader]::new($xaml.OuterXml)
$xmlReader = [System.Xml.XmlReader]::Create($stringReader)
$window = [System.Windows.Markup.XamlReader]::Load($xmlReader)

$AppContainer  = $window.FindName("AppContainer")
$btnEditConfig = $window.FindName("BtnEditConfig")
$btnClose      = $window.FindName("BtnClose")
$btnPin        = $window.FindName("BtnPin")
$pinIcon       = $window.FindName("PinIcon")

# Topmost Pin/Unpin logic
$btnPin.Add_Click({
    $window.Topmost = -not $window.Topmost
    
    if ($window.Topmost) {
        $pinIcon.Foreground = [System.Windows.Media.Brushes]::LightSkyBlue
        $btnPin.ToolTip = "Pinned (Click to Unpin)"
        [Win11Interop8.Theme]::ForceTopmost($window)
    } else {
        $pinIcon.Foreground = [System.Windows.Media.Brushes]::White
        $btnPin.ToolTip = "Always on Top"
    }
})

# Aggressive enforcement of Topmost (Avoids Taskbar overlap bugs)
$window.Add_Deactivated({
    if ($window.Topmost -and -not $global:IsEditing) {
        $window.Dispatcher.BeginInvoke([action]{
            try { [Win11Interop8.Theme]::ForceTopmost($window) } catch {}
        })
    }
})

# Calculate position: Center bottom above taskbar
$window.Add_Loaded({
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $workArea = $screen.WorkingArea
    
    $window.Left = ($workArea.Width - $window.ActualWidth) / 2
    $window.Top = $workArea.Bottom - $window.ActualHeight - 20 
})

# Robust Drag Logic: Intercepts click *before* the ScrollViewer swallows it
$window.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    
    $source = $e.OriginalSource
    $isInteractive = $false
    
    # Walk the visual tree to ensure we didn't click a Button or ScrollBar
    while ($source -ne $null) {
        $typeName = $source.GetType().Name
        if ($typeName -eq 'Button' -or $typeName -eq 'ScrollBar' -or $typeName -eq 'Thumb') {
            $isInteractive = $true
            break
        }
        
        if ($source -is [System.Windows.Media.Visual] -or $source -is [System.Windows.Media.Media3D.Visual3D]) {
            $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
        } elseif ($source -is [System.Windows.FrameworkContentElement]) {
            $source = $source.Parent
        } else {
            break
        }
    }
    
    # If it wasn't a button, we can safely drag the window
    if (-not $isInteractive) {
        if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try { $window.DragMove() } catch { }
        }
    }
})

# Custom close button handler
$btnClose.Add_Click({
    $window.Close()
})

function Update-UIContainer {
    if ($null -eq $window -or $null -eq $AppContainer) { return }

    $window.Dispatcher.Invoke({
        $AppContainer.Children.Clear()
        foreach ($app in $global:Apps) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Margin  = "3"
            $btn.Style   = $window.Resources["AppTileButton"]
            $btn.ToolTip = "$($app.Name)`nPath: $($app.Path)`nArgs: $($app.Arguments)"

            # Bind Width to ActualHeight to keep the button perfectly square
            $widthBinding = New-Object System.Windows.Data.Binding
            $widthBinding.Path = New-Object System.Windows.PropertyPath("ActualHeight")
            $widthBinding.RelativeSource = [System.Windows.Data.RelativeSource]::Self
            $btn.SetBinding([System.Windows.FrameworkElement]::WidthProperty, $widthBinding)

            # Viewbox automatically scales the inner content
            $viewbox = New-Object System.Windows.Controls.Viewbox
            $viewbox.Margin = "2"
            $viewbox.Stretch = [System.Windows.Media.Stretch]::Uniform

            $imgSource = Get-AppIconSource -AppPath $app.Path -CustomIconPath $app.Icon
            if ($imgSource) {
                $img = New-Object System.Windows.Controls.Image
                $img.Source              = $imgSource
                [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
                $viewbox.Child = $img
            }

            $btn.Content = $viewbox
            $btn.Tag     = $app

            $btn.Add_Click({
                param($sender, $e)
                $boundApp = $sender.Tag
                Invoke-AdminApp -Path $boundApp.Path -Arguments $boundApp.Arguments
            })

            $AppContainer.Children.Add($btn) | Out-Null
        }
    })
}

# -------------------------------------------------------------------------
# 6. HTML Config Editor
# -------------------------------------------------------------------------
$btnEditConfig.Add_Click({
    $global:IsEditing = $true
    
    $HtmlContent = @'
<!-- saved from url=(0014)about:internet -->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge" />
    <style>
        /* Base / Light Theme */
        body {
            font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            background-color: #f0f4f8;
            color: #1e293b;
            margin: 0; padding: 0;
            display: flex; flex-direction: column;
            height: 100vh; overflow: hidden;
        }
        [data-theme="Dark"] body { background-color: #0f172a; color: #f8fafc; }

        /* Header */
        header {
            background-color: #e2e8f0;
            padding: 16px 24px;
            display: flex; justify-content: space-between; align-items: center;
            border-bottom: 1px solid #cbd5e1;
            box-shadow: 0 2px 4px rgba(0,0,0,0.05);
            flex-shrink: 0;
            z-index: 10;
        }
        [data-theme="Dark"] header { background-color: #0f172a; border-bottom: 1px solid #1e293b; }

        .header-title { font-size: 1.25rem; font-weight: 700; color: #1e293b; margin: 0; display: flex; align-items: center; }
        .header-title svg { margin-right: 8px; }
        [data-theme="Dark"] .header-title { color: #f8fafc; }

        .actions-group { display: flex; align-items: center; }
        .actions-group > button + button { margin-left: 10px; }

        /* Buttons */
        .btn {
            display: inline-flex; align-items: center;
            padding: 8px 16px; border-radius: 8px;
            font-weight: 600; font-size: 14px;
            cursor: pointer; transition: all 0.2s;
            border: 1px solid transparent;
            outline: none;
        }
        .btn svg { margin-right: 6px; }
        .btn:active { transform: scale(0.95); }

        /* Primary = Pelican pink */
        .btn-primary { background-color: #E31876; color: #ffffff; border-color: #E31876; }
        .btn-primary:hover { background-color: #be125e; border-color: #be125e; }

        /* Secondary = Pelican navy */
        .btn-secondary { background-color: #001941; color: #ffffff; border-color: #001941; }
        .btn-secondary:hover { background-color: #00102a; border-color: #00102a; }
        [data-theme="Dark"] .btn-secondary { background-color: #38bdf8; color: #0f172a; border-color: #38bdf8; }
        [data-theme="Dark"] .btn-secondary:hover { background-color: #0284c7; color: #ffffff; border-color: #0284c7; }

        .btn-ghost { background-color: transparent; color: #1e293b; border: 1px solid #cbd5e1; }
        .btn-ghost:hover { background-color: #cbd5e1; }
        [data-theme="Dark"] .btn-ghost { color: #f8fafc; border: 1px solid #334155; }
        [data-theme="Dark"] .btn-ghost:hover { background-color: #334155; }

        .btn-cancel { color: #e11d48; border: 1px solid #fecdd3; background-color: #fff1f2; }
        .btn-cancel:hover { background-color: #ffe4e6; }
        [data-theme="Dark"] .btn-cancel { color: #fca5a5; border: 1px solid #9f1239; background-color: #4c0519; }
        [data-theme="Dark"] .btn-cancel:hover { background-color: #881337; }

        .icon-btn {
            background: transparent; border: none; padding: 6px;
            border-radius: 50%; cursor: pointer; color: #64748b;
            transition: all 0.2s; display: inline-flex;
        }
        .icon-btn:hover { background-color: #e2e8f0; color: #1e293b; }
        .icon-btn.danger:hover { color: #e11d48; background-color: #ffe4e6; }
        [data-theme="Dark"] .icon-btn { color: #94a3b8; }
        [data-theme="Dark"] .icon-btn:hover { background-color: #334155; color: #f8fafc; }
        [data-theme="Dark"] .icon-btn.danger:hover { color: #fca5a5; background-color: #881337; }

        /* Up/Down reorder buttons */
        .order-btn {
            background: transparent; border: 1px solid #e2e8f0;
            padding: 3px 7px; border-radius: 6px; cursor: pointer;
            color: #64748b; font-size: 12px; line-height: 1;
            transition: all 0.15s; display: inline-flex; align-items: center;
        }
        .order-btn:hover { background-color: #e2e8f0; color: #1e293b; }
        .order-btn:disabled { opacity: 0.3; cursor: default; }
        [data-theme="Dark"] .order-btn { border-color: #334155; color: #94a3b8; }
        [data-theme="Dark"] .order-btn:hover { background-color: #334155; color: #f8fafc; }

        /* Main Content */
        main { flex: 1; overflow-y: auto; padding: 24px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); align-content: start; }
        .grid > div { margin: 8px; }

        .card {
            background-color: #ffffff;
            border: 1px solid #e2e8f0;
            border-radius: 16px; padding: 20px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.05);
            transition: border-color 0.2s;
            position: relative;
        }
        .card:hover { border-color: #00AEEF; }
        [data-theme="Dark"] .card { background-color: #1e293b; border: 1px solid #334155; }
        [data-theme="Dark"] .card:hover { border-color: #38bdf8; }

        .card-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 12px; }
        .card-title { font-weight: 700; font-size: 1.05rem; color: #1e293b; display: flex; align-items: center; }
        [data-theme="Dark"] .card-title { color: #f8fafc; }

        .card-detail { font-size: 0.875rem; color: #64748b; margin-bottom: 6px; display: flex; }
        [data-theme="Dark"] .card-detail { color: #94a3b8; }
        .card-label { font-weight: 600; min-width: 40px; color: #1e293b; margin-right: 8px; }
        [data-theme="Dark"] .card-label { color: #f8fafc; }
        .card-value { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

        .badge { font-size: 0.65rem; background: #f0f4f8; color: #1e293b; padding: 2px 6px; border-radius: 9999px; font-weight: bold; border: 1px solid #e2e8f0; margin-left: 8px; }
        [data-theme="Dark"] .badge { background: #0f172a; color: #f8fafc; border: 1px solid #334155; }

        /* Action buttons row in card header */
        .card-actions { display: flex; align-items: center; }
        .card-actions > * + * { margin-left: 4px; }

        /* Modal */
        .modal-overlay {
            position: fixed; top: 0; left: 0; right: 0; bottom: 0;
            background-color: rgba(0,0,0,0.6);
            display: none; align-items: center; justify-content: center;
            z-index: 50; padding: 16px;
        }
        .modal {
            background-color: #ffffff;
            border-radius: 24px; width: 100%; max-width: 600px;
            box-shadow: 0 25px 50px -12px rgba(0,0,0,0.25);
            border: 1px solid #e2e8f0;
            display: flex; flex-direction: column; max-height: 90vh;
        }
        [data-theme="Dark"] .modal { background-color: #1e293b; border: 1px solid #334155; }

        .modal-header { padding: 24px; border-bottom: 1px solid #e2e8f0; display: flex; justify-content: space-between; align-items: center; }
        [data-theme="Dark"] .modal-header { border-bottom: 1px solid #334155; }
        .modal-title { font-size: 1.25rem; font-weight: 700; color: #1e293b; margin: 0; }
        [data-theme="Dark"] .modal-title { color: #f8fafc; }

        .modal-body { padding: 24px; overflow-y: auto; }
        .modal-footer { padding: 16px 24px; border-top: 1px solid #e2e8f0; display: flex; justify-content: flex-end; }
        .modal-footer > button + button { margin-left: 12px; }
        [data-theme="Dark"] .modal-footer { border-top: 1px solid #334155; }

        /* Inputs */
        .input-group { margin-bottom: 16px; display: flex; flex-direction: column; }
        .input-group > label { margin-bottom: 4px; }
        .input-label { font-size: 0.75rem; font-weight: 700; color: #64748b; text-transform: uppercase; letter-spacing: 0.05em; margin-left: 4px; }
        [data-theme="Dark"] .input-label { color: #94a3b8; }
        .input-control {
            background-color: #f0f4f8; border: 1px solid #e2e8f0;
            color: #1e293b; border-radius: 12px; padding: 10px 16px;
            font-size: 0.875rem; width: 100%; box-sizing: border-box; outline: none; transition: border 0.2s;
        }
        .input-control:focus { border-color: #00AEEF; }
        [data-theme="Dark"] .input-control { background-color: #0f172a; border: 1px solid #334155; color: #f8fafc; }
        [data-theme="Dark"] .input-control:focus { border-color: #38bdf8; }

        .input-row { display: flex; align-items: center; }
        .input-row > input { margin-right: 8px; }

        .checkbox-wrapper { display: flex; align-items: center; cursor: pointer; margin-top: 8px; padding: 12px; background: #f0f4f8; border-radius: 12px; border: 1px solid #e2e8f0; }
        [data-theme="Dark"] .checkbox-wrapper { background: #0f172a; border: 1px solid #334155; }
        .checkbox-wrapper input { width: 18px; height: 18px; accent-color: #00AEEF; cursor: pointer; margin-right: 8px; }
        .checkbox-label { font-size: 0.875rem; font-weight: 500; color: #1e293b; }
        [data-theme="Dark"] .checkbox-label { color: #f8fafc; }

        .empty-state { text-align: center; color: #64748b; padding: 48px; grid-column: 1 / -1; }
        [data-theme="Dark"] .empty-state { color: #94a3b8; }
    </style>
</head>
<body>

    <header>
        <h1 class="header-title">
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.38a2 2 0 0 0-.73-2.73l-.15-.1a2 2 0 0 1-1-1.72v-.51a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"></path><circle cx="12" cy="12" r="3"></circle></svg>
            Launcher Configuration
        </h1>
        <div class="actions-group">
            <button class="btn btn-ghost" onclick="toggleTheme()">
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>
                Theme
            </button>
            <button class="btn btn-secondary" onclick="openModal(-1)">
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"></path></svg>
                Add App
            </button>
            <button class="btn btn-primary" onclick="saveConfig()">
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"></path><polyline points="17 21 17 13 7 13 7 21"></polyline><polyline points="7 3 7 8 15 8"></polyline></svg>
                Save
            </button>
            <button class="btn btn-cancel" onclick="closeUI()">
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"></path></svg>
                Cancel
            </button>
        </div>
    </header>

    <main>
        <div id="appGrid" class="grid"></div>
    </main>

    <!-- Modal for Editing/Adding Apps -->
    <div id="editModal" class="modal-overlay">
        <div class="modal">
            <div class="modal-header">
                <h2 class="modal-title" id="modalTitle">Edit Application</h2>
                <button class="icon-btn" onclick="closeModal()">
                    <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 6 6 18M6 6l12 12"></path></svg>
                </button>
            </div>
            <div class="modal-body">
                <div class="input-group">
                    <label class="input-label">Display Name</label>
                    <input type="text" id="appName" class="input-control" placeholder="e.g., Command Prompt" />
                </div>
                <div class="input-group">
                    <label class="input-label">Executable / Target Path</label>
                    <div class="input-row">
                        <input type="text" id="appPath" class="input-control" placeholder="C:\Path\to\app.exe" />
                        <button class="btn btn-secondary" style="border-radius:12px; padding:10px 16px; white-space:nowrap;" onclick="browsePath()">Browse</button>
                    </div>
                </div>
                <div class="input-group">
                    <label class="input-label">Custom Icon Path (Optional)</label>
                    <div class="input-row">
                        <input type="text" id="appIcon" class="input-control" placeholder="Leave blank to extract from exe" />
                        <button class="btn btn-secondary" style="border-radius:12px; padding:10px 16px; white-space:nowrap;" onclick="browseIcon()">Browse</button>
                    </div>
                </div>
                <div class="input-group">
                    <label class="input-label">Arguments (Optional)</label>
                    <input type="text" id="appArgs" class="input-control" placeholder="-v --silent" />
                </div>
                <label class="checkbox-wrapper">
                    <input type="checkbox" id="appAuto" />
                    <span class="checkbox-label">Run automatically on startup (Hidden)</span>
                </label>
            </div>
            <div class="modal-footer">
                <button class="btn btn-ghost" onclick="closeModal()">Cancel</button>
                <button class="btn btn-primary" onclick="saveApp()">Save Changes</button>
            </div>
        </div>
    </div>

    <script>
        // ── State ──────────────────────────────────────────────────────────
        var configObj    = {};
        var apps         = [];
        var currentTheme = "Dark";
        var editingIndex = -1;

        // ── Init ───────────────────────────────────────────────────────────
        try { configObj = JSON.parse(window.external.GetConfig()); } catch(e) {}
        apps         = configObj.Apps  || [];
        currentTheme = configObj.Theme || "Dark";
        document.documentElement.setAttribute('data-theme', currentTheme);

        // ── Theme toggle ───────────────────────────────────────────────────
        function toggleTheme() {
            currentTheme = (currentTheme === "Dark") ? "Light" : "Dark";
            document.documentElement.setAttribute('data-theme', currentTheme);
        }

        // ── Reorder helpers (replaces broken HTML5 drag-and-drop) ──────────
        // IE11/Trident does not fire ondragstart/ondragover on elements,
        // causing "Unable to get property 'add' of undefined or null reference".
        // Up/Down buttons manipulate the array directly and re-render.
        function moveUp(index) {
            if (index <= 0) return;
            var tmp = apps[index - 1];
            apps[index - 1] = apps[index];
            apps[index]     = tmp;
            renderGrid();
        }

        function moveDown(index) {
            if (index >= apps.length - 1) return;
            var tmp = apps[index + 1];
            apps[index + 1] = apps[index];
            apps[index]     = tmp;
            renderGrid();
        }

        // ── Render ─────────────────────────────────────────────────────────
        function renderGrid() {
            var container = document.getElementById('appGrid');
            if (!apps || apps.length === 0) {
                container.innerHTML = '<div class="empty-state"><h3>No applications configured</h3><p>Click "Add App" to get started.</p></div>';
                return;
            }

            var html = '';
            for (var i = 0; i < apps.length; i++) {
                var app  = apps[i];
                var name = app.Name      || 'Unnamed App';
                var path = app.Path      || '-';
                var args = app.Arguments || 'None';
                var autoHtml = app.AutoLaunch ? '<span class="badge">Auto-Launch</span>' : '';

                var upDisabled   = (i === 0)              ? ' disabled' : '';
                var downDisabled = (i === apps.length - 1) ? ' disabled' : '';

                html +=
                    '<div class="card">' +
                        '<div class="card-header">' +
                            '<div class="card-title">' + name + autoHtml + '</div>' +
                            '<div class="card-actions">' +
                                '<button class="order-btn" onclick="moveUp('   + i + ')"' + upDisabled   + ' title="Move up">&#9650;</button>' +
                                '<button class="order-btn" onclick="moveDown(' + i + ')"' + downDisabled + ' title="Move down">&#9660;</button>' +
                                '<button class="icon-btn"  onclick="openModal(' + i + ')" title="Edit" style="margin-left:4px;">' +
                                    '<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>' +
                                '</button>' +
                                '<button class="icon-btn danger" onclick="removeApp(' + i + ')" title="Remove">' +
                                    '<svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/></svg>' +
                                '</button>' +
                            '</div>' +
                        '</div>' +
                        '<div class="card-detail"><span class="card-label">Path:</span><span class="card-value" title="' + path + '">' + path + '</span></div>' +
                        '<div class="card-detail"><span class="card-label">Args:</span><span class="card-value" title="' + args + '">' + args + '</span></div>' +
                    '</div>';
            }
            container.innerHTML = html;
        }

        // ── Modal logic ────────────────────────────────────────────────────
        function openModal(index) {
            editingIndex = index;
            document.getElementById('modalTitle').innerText = (index === -1) ? 'Add New Application' : 'Edit Application';
            var app = (index === -1) ? { Name:'', Path:'', Arguments:'', Icon:'', AutoLaunch:false } : apps[index];
            document.getElementById('appName').value  = app.Name      || '';
            document.getElementById('appPath').value  = app.Path      || '';
            document.getElementById('appIcon').value  = app.Icon      || '';
            document.getElementById('appArgs').value  = app.Arguments || '';
            document.getElementById('appAuto').checked = !!app.AutoLaunch;
            document.getElementById('editModal').style.display = 'flex';
        }

        function closeModal() {
            document.getElementById('editModal').style.display = 'none';
        }

        function saveApp() {
            var updated = {
                Name:       document.getElementById('appName').value,
                Path:       document.getElementById('appPath').value,
                Icon:       document.getElementById('appIcon').value,
                Arguments:  document.getElementById('appArgs').value,
                AutoLaunch: document.getElementById('appAuto').checked
            };
            if (editingIndex === -1) { apps.push(updated); }
            else                     { apps[editingIndex] = updated; }
            closeModal();
            renderGrid();
        }

        function removeApp(index) {
            if (confirm("Remove '" + apps[index].Name + "' from the launcher?")) {
                apps.splice(index, 1);
                renderGrid();
            }
        }

        // ── C# COM Bridge wrappers ─────────────────────────────────────────
        function browsePath() {
            var p = window.external.BrowseFile();
            if (p) document.getElementById('appPath').value = p;
        }

        function browseIcon() {
            var p = window.external.BrowseIcon();
            if (p) document.getElementById('appIcon').value = p;
        }

        function saveConfig() {
            configObj.Theme = currentTheme;
            configObj.Apps  = apps;
            window.external.SaveConfig(JSON.stringify(configObj, null, 4));
        }

        function closeUI() {
            window.external.Close();
        }

        // ── Initial render ─────────────────────────────────────────────────
        renderGrid();
    </script>
</body>
</html>
'@

    $TempHtmlPath = Join-Path $env:TEMP "LauncherConfigEditor.html"
    $HtmlContent | Set-Content -Path $TempHtmlPath -Encoding UTF8

    $editorWindow = New-Object System.Windows.Window
    $editorWindow.Title                 = "Launcher Configuration"
    $editorWindow.Width                 = 850
    $editorWindow.Height                = 750
    $editorWindow.WindowStartupLocation = "CenterOwner"
    $editorWindow.Owner                 = $window

    if ($global:IsDarkTheme) {
        $editorWindow.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(15, 23, 42))
    } else {
        $editorWindow.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(240, 244, 248))
    }

    $editorWindow.Add_SourceInitialized({
        [Win11Interop8.Theme]::ApplyMica($editorWindow, $global:IsDarkTheme)
    })

    $browser = New-Object System.Windows.Controls.WebBrowser
    $editorWindow.Content = $browser

    $bridge          = New-Object Win11Interop8.ConfigBridge
    $bridge.UIDispatcher = $window.Dispatcher
    $bridge.JsonData = (Get-Content $ConfigPath -Raw)

    $bridge.OnSave = [System.Action[string]]{
        param($updatedJson)
        # Write the updated config to disk
        $updatedJson | Set-Content $ConfigPath -Encoding UTF8

        $window.Dispatcher.Invoke({
            # Reload config into globals so the refreshed UI reflects all changes
            try {
                $reloaded = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
                $global:AppConfig   = $reloaded
                $global:Apps        = @($reloaded.Apps)
                $global:IsDarkTheme = ($reloaded.Theme -eq "Dark")
            } catch {
                Write-Warning "Failed to reload config after save: $_"
            }

            # Refresh the tile grid without touching the main window
            Update-UIContainer

            # Close only the editor window; the launcher stays open
            $editorWindow.Close()
        })
    }

    $bridge.OnClose = [System.Action]{
        $window.Dispatcher.Invoke({ $editorWindow.Close() })
    }

    $browser.ObjectForScripting = $bridge
    $browser.Navigate("file:///$TempHtmlPath")

    $editorWindow.ShowDialog() | Out-Null
    
    # Release edit state lock
    $global:IsEditing = $false
})

# -------------------------------------------------------------------------
# 7. Final Initialization
# -------------------------------------------------------------------------
Update-UIContainer

$window.Add_SourceInitialized({
    [Win11Interop8.Theme]::ApplyMica($window, $global:IsDarkTheme)
    
    # Force topmost on startup to prevent initially loading behind the taskbar
    if ($window.Topmost) {
        [Win11Interop8.Theme]::ForceTopmost($window)
    }
})

$window.ShowDialog() | Out-Null