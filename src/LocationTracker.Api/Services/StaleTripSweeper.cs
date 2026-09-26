using LocationTracker.Api.Common;
using LocationTracker.Api.Data;
using LocationTracker.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace LocationTracker.Api.Services;

/// <summary>
/// Trips are otherwise only ever closed by the arrival of a later point. A user who kills the
/// app mid-journey would leave one open forever, blocking the next trip via the one-open-trip
/// index and reporting a duration that grows without bound. This closes them out of band.
/// </summary>
public class StaleTripSweeper : BackgroundService
{
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly TripDetectionOptions _options;
    private readonly ILogger<StaleTripSweeper> _logger;

    public StaleTripSweeper(
        IServiceScopeFactory scopeFactory,
        IOptions<TripDetectionOptions> options,
        ILogger<StaleTripSweeper> logger)
    {
        _scopeFactory = scopeFactory;
        _options = options.Value;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = TimeSpan.FromSeconds(Math.Max(10, _options.SweepIntervalSeconds));
        using var timer = new PeriodicTimer(interval);

        _logger.LogInformation("Stale trip sweeper running every {Interval}", interval);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await SweepAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // A failed sweep must not take the background service down; the next tick retries.
                _logger.LogError(ex, "Trip sweep failed");
            }

            try
            {
                if (!await timer.WaitForNextTickAsync(stoppingToken)) break;
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task SweepAsync(CancellationToken ct)
    {
        using var scope = _scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        var detector = scope.ServiceProvider.GetRequiredService<ITripDetector>();

        var cutoff = DateTime.UtcNow.AddMinutes(-_options.GapTimeoutMinutes);

        // Only trips whose *last* activity predates the cutoff. Filtering on StartedAtUtc
        // instead would kill long journeys that are still actively reporting.
        var stale = await db.Trips
            .Where(t => t.EndedAtUtc == null && t.LastMovingAtUtc < cutoff)
            .Where(t => !db.Locations.Any(l => l.UserId == t.UserId && l.RecordedAtUtc > cutoff))
            .ToListAsync(ct);

        if (stale.Count == 0) return;

        var finalizer = scope.ServiceProvider.GetRequiredService<ITripFinalizer>();

        foreach (var trip in stale)
            detector.CloseTrip(trip, TripEndReason.Swept);

        await using var transaction = await db.Database.BeginTransactionAsync(ct);

        await db.SaveChangesAsync(ct);
        var discarded = await finalizer.FinalizeAsync(stale, ct);

        await transaction.CommitAsync(ct);

        _logger.LogInformation("Swept {Closed} stale trip(s), discarded {Discarded} as too short or noise",
            stale.Count, discarded);
    }
}
