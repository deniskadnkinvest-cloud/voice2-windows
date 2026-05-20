using System.Windows;

namespace Voice2;

public partial class App : Application
{
    private System.Windows.Forms.NotifyIcon? _trayIcon;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        SetupTray();

        if (!UsageTracker.Instance.IsRegistered)
        {
            new LoginWindow().Show();
        }
        else
        {
            new MainWindow().Show();
        }
    }

    private void SetupTray()
    {
        string exePath = Environment.ProcessPath
                         ?? System.Reflection.Assembly.GetExecutingAssembly().Location;
        _trayIcon = new System.Windows.Forms.NotifyIcon
        {
            Icon    = System.Drawing.Icon.ExtractAssociatedIcon(exePath),
            Visible = true,
            Text    = "Voice2"
        };

        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("Открыть", null, (_, _) => ShowMainWindow());
        menu.Items.Add("Выход",   null, (_, _) => { _trayIcon.Visible = false; Shutdown(); });
        _trayIcon.ContextMenuStrip   = menu;
        _trayIcon.DoubleClick        += (_, _) => ShowMainWindow();
    }

    private void ShowMainWindow()
    {
        if (MainWindow is MainWindow mw)
        {
            mw.Show();
            mw.Activate();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        base.OnExit(e);
    }
}
