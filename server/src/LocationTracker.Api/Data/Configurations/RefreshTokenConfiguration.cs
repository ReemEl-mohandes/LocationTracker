using LocationTracker.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace LocationTracker.Api.Data.Configurations;

public class RefreshTokenConfiguration : IEntityTypeConfiguration<RefreshToken>
{
    public void Configure(EntityTypeBuilder<RefreshToken> builder)
    {
        builder.ToTable("RefreshTokens");
        builder.HasKey(r => r.Id);

        builder.Property(r => r.TokenHash).IsRequired().HasMaxLength(88);
        builder.Property(r => r.ReplacedByTokenHash).HasMaxLength(88);
        builder.Property(r => r.CreatedByIp).HasMaxLength(64);

        builder.HasOne(r => r.User)
            .WithMany(u => u.RefreshTokens)
            .HasForeignKey(r => r.UserId)
            .OnDelete(DeleteBehavior.Cascade);

        // Lookup on presentation is by hash alone, and a hash must map to exactly one token.
        builder.HasIndex(r => r.TokenHash)
            .IsUnique()
            .HasDatabaseName("UX_RefreshTokens_TokenHash");

        builder.HasIndex(r => r.UserId).HasDatabaseName("IX_RefreshTokens_UserId");
    }
}
