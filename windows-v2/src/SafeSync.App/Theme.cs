using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace SafeSync.App;

internal static class Theme
{
    private static readonly string[] Roles = ["Window","Surface","Subtle","Heading","MenuBorder","Input","Border","BorderSoft","Text","Muted","Accent","AccentDark","SuccessSurface","SuccessText","ActivitySurface","ActivityText","ActivityMuted","Warning","Danger"];
    private static readonly string[] Dark = ["#171B22","#20262F","#282F3A","#303B4B","#090C11","#1B222C","#465164","#354052","#F3F6FA","#B3BECE","#4C91FF","#2E6FC9","#193A2A","#72D49D","#0F131A","#E7EDF6","#A9B8CE","#F4A340","#F26B62"];
    private static readonly string[] Light = ["#F5F7FB","#FFFFFF","#EEF2F8","#DCE8F7","#E7ECF3","#FFFFFF","#D7DEEA","#DEE5EF","#182033","#64748B","#246BFD","#163B75","#E8F7EE","#16794A","#EEF3F9","#263548","#52677F","#D97706","#C83B3B"];
    public static void Apply(Window window,string mode)
    {
        var colors = mode == "Dark" ? Dark : Light;
        var brushes = new Dictionary<string,SolidColorBrush>();
        for (int i=0;i<Roles.Length;i++)
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
            brush.Freeze();brushes[Roles[i]]=brush;
            window.Resources["SafeSync" + Roles[i] + "Brush"] = brush;
        }
        foreach (var pair in new (ResourceKey Key,string Role)[]
        {
            (SystemColors.WindowBrushKey,"Input"),(SystemColors.WindowTextBrushKey,"Text"),
            (SystemColors.ControlBrushKey,"Surface"),(SystemColors.ControlTextBrushKey,"Text"),
            (SystemColors.MenuBrushKey,"Surface"),(SystemColors.MenuTextBrushKey,"Text"),
            (SystemColors.HighlightBrushKey,"Accent"),(SystemColors.HighlightTextBrushKey,"Text"),
            (SystemColors.GrayTextBrushKey,"Muted"),(SystemColors.ControlLightBrushKey,"Subtle"),
            (SystemColors.ControlDarkBrushKey,"MenuBorder")
        }) window.Resources[pair.Key]=brushes[pair.Role];
        window.Foreground=brushes["Text"];
        if (window.Content is System.Windows.Controls.Panel panel) panel.Background=brushes["Window"];
    }
}
