using LocationTracker.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace LocationTracker.Api.Data.Configurations;

public class LocationConfiguration : IEntityTypeConfiguration<Location>
{
    public void Configure(EntityTypeBuilder<Location> builder)
    {
        builder.ToTable("Locations");
        builder.HasKey(l => l.Id);

        builder.Property(l => l.Latitude).IsRequired();
        builder.Property(l => l.Longitude).IsRequired();
        builder.Property(l => l.RecordedAtUtc).IsRequired();
        builder.Property(l => l.ReceivedAtUtc).IsRequired();

        builder.HasOne(l => l.User)
            .WithMany(u => u.Locations)
            .HasForeignKey(l => l.UserId)
            .OnDelete(DeleteBehavior.Cascade);

        // A trip is a derived rollup; deleting one must not take the raw points with it.
        // Discarded trivial trips detach their points by nulling TripId instead.
        builder.HasOne(l => l.Trip)
            .WithMany(t => t.Locations)
            .HasForeignKey(l => l.TripId)
            .OnDelete(DeleteBehavior.SetNull);

        // Serves both "latest position" and "history between two dates" without a sort step.
        builder.HasIndex(l => new { l.UserId, l.RecordedAtUtc })
            .IsDescending(false, true)
            .HasDatabaseName("IX_Locations_UserId_RecordedAtUtc");

        // Replaying one trip's path in order.
        builder.HasIndex(l => new { l.TripId, l.RecordedAtUtc })
            .HasDatabaseName("IX_Locations_TripId_RecordedAtUtc");
    }
}
