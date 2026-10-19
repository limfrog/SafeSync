using System.Globalization;

namespace SafeSync.Core;

public static class TrashDates
{
    public static bool TryParse(string name,out DateTime date)
    {
        foreach(var format in new[]{"yyyyMMdd-HHmmssfff","yyyyMMdd-HHmmss"})
            if(name.Length>=format.Length && (name.Length==format.Length || name[format.Length]=='-') &&
                DateTime.TryParseExact(name[..format.Length],format,CultureInfo.InvariantCulture,DateTimeStyles.None,out date))return true;
        date=default;return false;
    }
}
