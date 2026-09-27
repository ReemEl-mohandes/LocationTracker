using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace LocationTracker.Api.Data;

/// <summary>
/// Used only by "dotnet ef" at design time. Without it EF executes Program.cs to find the
/// context, which trips the startup signing-key validation and needs a reachable database
/// just to scaffold a migration.
/// </summary>
public class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<AppDbContext>
{
    public AppDbContext CreateDbContext(string[] args)
    {
        var connection = Environment.GetEnvironmentVariable("ConnectionStrings__Default")
                         ?? "Host=localhost;Port=5432;Database=locationtracker;Username=locationtracker;Password=devpassword";

        var options = new DbContextOptionsBuilder<AppDbContext>()
            .UseNpgsql(connection)
            .Options;

        return new AppDbContext(options);
    }
}
