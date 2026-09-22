namespace LocationTracker.Api.Common;

public static class GeoMath
{
    /// <summary>Mean Earth radius (WGS-84), metres.</summary>
    private const double EarthRadiusMeters = 6_371_008.8;

    /// <summary>
    /// Great-circle distance in metres. Haversine is used rather than PostGIS/NTS: at
    /// point-to-point scale the spherical-vs-ellipsoidal error is a fraction of a percent,
    /// well inside GPS noise, and it keeps the database free of the PostGIS extension.
    /// </summary>
    public static double HaversineMeters(double lat1, double lon1, double lat2, double lon2)
    {
        var phi1 = ToRadians(lat1);
        var phi2 = ToRadians(lat2);
        var deltaPhi = ToRadians(lat2 - lat1);
        var deltaLambda = ToRadians(lon2 - lon1);

        var sinPhi = Math.Sin(deltaPhi / 2);
        var sinLambda = Math.Sin(deltaLambda / 2);

        var a = (sinPhi * sinPhi) + (Math.Cos(phi1) * Math.Cos(phi2) * sinLambda * sinLambda);

        // Clamp guards against a > 1 from floating-point drift, which would make Sqrt return NaN.
        var c = 2 * Math.Asin(Math.Sqrt(Math.Clamp(a, 0d, 1d)));

        return EarthRadiusMeters * c;
    }

    private static double ToRadians(double degrees) => degrees * Math.PI / 180d;

    public static bool IsValidLatitude(double value) => value is >= -90d and <= 90d && !double.IsNaN(value);

    public static bool IsValidLongitude(double value) => value is >= -180d and <= 180d && !double.IsNaN(value);
}
