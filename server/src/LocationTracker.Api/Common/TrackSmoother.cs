namespace LocationTracker.Api.Common;

public readonly record struct TrackInput(double Latitude, double Longitude, double? AccuracyMeters, DateTime RecordedAtUtc);

public readonly record struct SmoothedPoint(double Latitude, double Longitude, DateTime RecordedAtUtc, double SpeedMps);

/// <summary>
/// Kalman filter with a Rauch–Tung–Striebel backward pass over a whole track.
///
/// Summing raw point-to-point distances counts noise as travel: with ±40 m fixes once a
/// second, every fix wobbles tens of metres sideways and each wobble adds distance. The
/// smoother instead estimates the most likely path, weighting each fix by its reported
/// accuracy against a constant-velocity motion model. Distance and speed are then read off
/// that path. The backward pass uses later fixes to correct earlier ones, which a live
/// filter cannot do, so the result is noticeably tighter than filtering alone.
///
/// The model is independent per axis in a local tangent plane (metres east and north of the
/// first fix), which is exact enough at city scale and keeps every matrix 2×2.
/// </summary>
public static class TrackSmoother
{
    /// <summary>Stand-in for fixes that report no accuracy at all.</summary>
    private const double DefaultAccuracyMeters = 10d;

    private const double MetersPerDegreeLatitude = 110_540d;
    private const double MetersPerDegreeLongitudeAtEquator = 111_320d;

    public static IReadOnlyList<SmoothedPoint> Smooth(IReadOnlyList<TrackInput> points, double accelerationNoise)
    {
        if (points.Count == 0) return Array.Empty<SmoothedPoint>();
        if (points.Count == 1)
            return new[] { new SmoothedPoint(points[0].Latitude, points[0].Longitude, points[0].RecordedAtUtc, 0d) };

        var lat0 = points[0].Latitude;
        var lon0 = points[0].Longitude;
        var metersPerDegreeLon = MetersPerDegreeLongitudeAtEquator * Math.Cos(lat0 * Math.PI / 180d);

        var east = new double[points.Count];
        var north = new double[points.Count];
        var variance = new double[points.Count];
        var elapsed = new double[points.Count];

        for (var i = 0; i < points.Count; i++)
        {
            east[i] = (points[i].Longitude - lon0) * metersPerDegreeLon;
            north[i] = (points[i].Latitude - lat0) * MetersPerDegreeLatitude;
            var accuracy = points[i].AccuracyMeters is > 0 ? points[i].AccuracyMeters!.Value : DefaultAccuracyMeters;
            variance[i] = accuracy * accuracy;
            elapsed[i] = i == 0 ? 0d : Math.Max(0d, (points[i].RecordedAtUtc - points[i - 1].RecordedAtUtc).TotalSeconds);
        }

        var (smoothedEast, velocityEast) = SmoothAxis(east, variance, elapsed, accelerationNoise);
        var (smoothedNorth, velocityNorth) = SmoothAxis(north, variance, elapsed, accelerationNoise);

        var result = new SmoothedPoint[points.Count];
        for (var i = 0; i < points.Count; i++)
        {
            result[i] = new SmoothedPoint(
                lat0 + (smoothedNorth[i] / MetersPerDegreeLatitude),
                lon0 + (smoothedEast[i] / metersPerDegreeLon),
                points[i].RecordedAtUtc,
                Math.Sqrt((velocityEast[i] * velocityEast[i]) + (velocityNorth[i] * velocityNorth[i])));
        }

        return result;
    }

    public static double DistanceMeters(IReadOnlyList<SmoothedPoint> track)
    {
        var total = 0d;
        for (var i = 1; i < track.Count; i++)
            total += GeoMath.HaversineMeters(track[i - 1].Latitude, track[i - 1].Longitude, track[i].Latitude, track[i].Longitude);
        return total;
    }

    /// <summary>Furthest the track gets from its own start: how far the journey really went.</summary>
    public static double ExtentMeters(IReadOnlyList<SmoothedPoint> track)
    {
        if (track.Count == 0) return 0d;
        var start = track[0];
        return track.Max(p => GeoMath.HaversineMeters(start.Latitude, start.Longitude, p.Latitude, p.Longitude));
    }

    /// <summary>
    /// One axis of the filter. State is (position, velocity); z are the measured positions,
    /// r their variances, dt the seconds since the previous fix.
    /// </summary>
    private static (double[] Position, double[] Velocity) SmoothAxis(double[] z, double[] r, double[] dt, double q)
    {
        var n = z.Length;

        // Forward (filter) pass. Kept: filtered state/covariance and the one-step prediction.
        var x0 = new double[n]; var x1 = new double[n];
        var p00 = new double[n]; var p01 = new double[n]; var p11 = new double[n];
        var px0 = new double[n]; var px1 = new double[n];
        var pp00 = new double[n]; var pp01 = new double[n]; var pp11 = new double[n];

        // Start at the first fix, velocity unknown (±10 m/s).
        double sx0 = z[0], sx1 = 0d, s00 = r[0], s01 = 0d, s11 = 100d;

        for (var i = 0; i < n; i++)
        {
            var t = dt[i];

            // Predict: x = F x, P = F P Fᵀ + Q, with F = [[1, t], [0, 1]] and white-noise
            // acceleration Q scaled by q².
            var q2 = q * q;
            var predX0 = sx0 + (t * sx1);
            var predX1 = sx1;
            var pred00 = s00 + (2 * t * s01) + (t * t * s11) + (q2 * t * t * t * t / 4d);
            var pred01 = s01 + (t * s11) + (q2 * t * t * t / 2d);
            var pred11 = s11 + (q2 * t * t);

            px0[i] = predX0; px1[i] = predX1;
            pp00[i] = pred00; pp01[i] = pred01; pp11[i] = pred11;

            // Update with the measured position, weighted by its variance.
            var innovation = z[i] - predX0;
            var s = pred00 + r[i];
            var k0 = pred00 / s;
            var k1 = pred01 / s;

            sx0 = predX0 + (k0 * innovation);
            sx1 = predX1 + (k1 * innovation);
            s00 = (1 - k0) * pred00;
            s01 = (1 - k0) * pred01;
            s11 = pred11 - (k1 * pred01);

            x0[i] = sx0; x1[i] = sx1;
            p00[i] = s00; p01[i] = s01; p11[i] = s11;
        }

        // Backward (RTS) pass: blend each filtered state with the smoothed state after it.
        var outPos = new double[n];
        var outVel = new double[n];
        outPos[n - 1] = x0[n - 1];
        outVel[n - 1] = x1[n - 1];

        for (var i = n - 2; i >= 0; i--)
        {
            var t = dt[i + 1];

            // C = P Fᵀ (P_pred)⁻¹ for the step i → i+1.
            var a00 = p00[i] + (t * p01[i]);
            var a01 = p01[i];
            var a10 = p01[i] + (t * p11[i]);
            var a11 = p11[i];

            var det = (pp00[i + 1] * pp11[i + 1]) - (pp01[i + 1] * pp01[i + 1]);
            if (Math.Abs(det) < 1e-12)
            {
                outPos[i] = x0[i];
                outVel[i] = x1[i];
                continue;
            }

            var inv00 = pp11[i + 1] / det;
            var inv01 = -pp01[i + 1] / det;
            var inv11 = pp00[i + 1] / det;

            var c00 = (a00 * inv00) + (a01 * inv01);
            var c01 = (a00 * inv01) + (a01 * inv11);
            var c10 = (a10 * inv00) + (a11 * inv01);
            var c11 = (a10 * inv01) + (a11 * inv11);

            var d0 = outPos[i + 1] - px0[i + 1];
            var d1 = outVel[i + 1] - px1[i + 1];

            outPos[i] = x0[i] + (c00 * d0) + (c01 * d1);
            outVel[i] = x1[i] + (c10 * d0) + (c11 * d1);
        }

        return (outPos, outVel);
    }
}
