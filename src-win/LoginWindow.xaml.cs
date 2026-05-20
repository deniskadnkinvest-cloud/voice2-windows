using System.Windows;
using System.Windows.Input;

namespace Voice2;

public partial class LoginWindow : Window
{
    public LoginWindow()
    {
        InitializeComponent();
        EmailBox.Focus();
    }

    private void OnTextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        string text = EmailBox.Text.Trim();
        StartBtn.IsEnabled = text.Contains('@') && text.Contains('.');
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && StartBtn.IsEnabled) OnStart(sender, e);
    }

    private void OnStart(object sender, RoutedEventArgs e)
    {
        UsageTracker.Instance.SaveEmail(EmailBox.Text);
        var main = new MainWindow();
        main.Show();
        Close();
    }
}
