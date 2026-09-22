using Microsoft.AspNetCore.Identity;

namespace LocationTracker.Api.Entities;

public class ApplicationRole : IdentityRole<Guid>
{
    public ApplicationRole() { }

    public ApplicationRole(string roleName) : base(roleName) { }
}

public static class RoleNames
{
    public const string User = "User";
    public const string Admin = "Admin";
}
