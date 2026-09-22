using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Security;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace LocationTracker.Api.Services;

public interface ITokenService
{
    (string Token, DateTime ExpiresAtUtc) CreateAccessToken(ApplicationUser user, IEnumerable<string> roles);
    string CreateSecureRandomToken();
    string Hash(string token);
}

public class TokenService : ITokenService
{
    public const string SecurityStampClaim = "sstamp";

    private readonly JwtOptions _options;

    public TokenService(IOptions<JwtOptions> options) => _options = options.Value;

    public (string Token, DateTime ExpiresAtUtc) CreateAccessToken(ApplicationUser user, IEnumerable<string> roles)
    {
        var expires = DateTime.UtcNow.AddMinutes(_options.AccessTokenMinutes);

        var claims = new List<Claim>
        {
            new(JwtRegisteredClaimNames.Sub, user.Id.ToString()),
            new(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new(JwtRegisteredClaimNames.Email, user.Email ?? string.Empty),
            new(ClaimTypes.Name, user.DisplayName),
            new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString()),

            // Carrying the Identity security stamp makes "log out everywhere" possible:
            // UpdateSecurityStampAsync invalidates every outstanding token at refresh time.
            new(SecurityStampClaim, user.SecurityStamp ?? string.Empty)
        };

        claims.AddRange(roles.Select(r => new Claim(ClaimTypes.Role, r)));

        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_options.SigningKey));
        var credentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        var token = new JwtSecurityToken(
            issuer: _options.Issuer,
            audience: _options.Audience,
            claims: claims,
            notBefore: DateTime.UtcNow,
            expires: expires,
            signingCredentials: credentials);

        return (new JwtSecurityTokenHandler().WriteToken(token), expires);
    }

    /// <summary>
    /// Base64**url**, not plain base64. These values travel as cookies, and ASP.NET Core
    /// percent-encodes a cookie value on write then decodes it on read. Header values are not
    /// decoded, so a client echoing the CSRF cookie verbatim into X-CSRF-Token would send the
    /// encoded form while the server compared the decoded one — a mismatch whenever the token
    /// contained '+' or '/', which is most of the time. Restricting the alphabet to
    /// [A-Za-z0-9_-] makes the encoded and decoded forms identical.
    /// </summary>
    public string CreateSecureRandomToken() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(48))
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');

    /// <summary>
    /// Refresh tokens are stored hashed. A database leak then yields no usable credentials.
    /// Plain SHA-256 is right here, unlike for passwords: the input is 48 bytes of CSPRNG
    /// output, so there is nothing to brute-force and no need for a slow KDF.
    /// </summary>
    public string Hash(string token) =>
        Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
}
