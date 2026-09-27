using LocationTracker.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace LocationTracker.Api.Data.Configurations;

public class TripConfiguration : IEntityTypeConfiguration<Trip>
{
    public void Configure(EntityTypeBuilder<Trip> builder)
    {
        builder.ToTable("Trips");
        builder.HasKey(t => t.Id);

        builder.Property(t => t.StartedAtUtc).IsRequired();
        builder.Property(t => t.DistanceMeters).IsRequired();
        builder.Property(t => t.EndReason).HasConversion<string>().HasMaxLength(32);

        builder.HasOne(t => t.User)
            .WithMany(u => u.Trips)
            .HasForeignKey(t => t.UserId)
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasIndex(t => new { t.UserId, t.StartedAtUtc })
            .IsDescending(false, true)
            .HasDatabaseName("IX_Trips_UserId_StartedAtUtc");

        // A user can never hold two open trips at once. Enforced in the database, not only in
        // application code: a concurrent ping and a batch upload would otherwise race into two.
        builder.HasIndex(t => t.UserId)
            .IsUnique()
            .HasFilter("\"EndedAtUtc\" IS NULL")
            .HasDatabaseName("UX_Trips_UserId_Active");
    }
}
