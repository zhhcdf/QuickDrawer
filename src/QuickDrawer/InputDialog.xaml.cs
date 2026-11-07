using System.Windows;

namespace QuickDrawer;

/// <summary>
/// 简单输入对话框。用于"新建分类"等轻量输入。
/// </summary>
public partial class InputDialog : Window
{
    public string Answer => AnswerBox.Text;

    public InputDialog(string title, string prompt, string initialValue = "")
    {
        InitializeComponent();
        Title = title;
        PromptText.Text = prompt;
        AnswerBox.Text = initialValue;
        AnswerBox.Focus();
        AnswerBox.SelectAll();
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
