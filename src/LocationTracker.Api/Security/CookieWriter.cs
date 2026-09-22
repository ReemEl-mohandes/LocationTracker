using LocationTracker.Api.Security;

namespace LocationTracker.Api.Security;

public interface ICookieWriter
{
    void WriteAuthCookies(HttpResponse response, string accessToken, string refreshToken, string csrfToken);
    void ClearAuthCookies(HttpResponse response);
}

public class CookieWriter : ICookieWriter
{
    private readonly JwtOptions _jwt;

    public CookieWriter(Microsoft.Extensions.Options.IOptions<JwtOptions> jwt) => _jwt = jwt.Value;

    public void WriteAuthCookies(HttpResponse response, string accessToken, string refreshToken, string csrfToken)
    {
        var now = DateTimeOffset.UtcNow;

        // HttpOnly keeps the token out of reach of any XSS payload; Secure keeps it off plaintext
        // transports; SameSite=Strict stops the browser attaching it to cross-site requests.
        response.Cookies.Append(CookieNames.AccessToken, accessToken, new CookieOptions
        {
            HttpOnly = true,
            Secure = true,
            SameSite = SameSiteMode.Strict,
            Path = "/",
            Expires = now.AddMinutes(_jwt.AccessTokenMinutes)
        });

        response.Cookies.Append(CookieNames.RefreshToken, refreshToken, new CookieOptions
        {
            HttpOnly = true,
            Secure = true,
            SameSite = SameSiteMode.Strict,
            Path = CookieNames.RefreshPath,
            Expires = now.AddDays(_jwt.RefreshTokenDays)
        });

        // The CSRF half of the double-submit pair must be readable, so HttpOnly is false here
        // by design: the client reads it and echoes it back in a header the browser will not
        // set automatically on a cross-site request.
        response.Cookies.Append(CookieNames.Csrf, csrfToken, new CookieOptions
        {
            HttpOnly = false,
            Secure = true,
            SameSite = SameSiteMode.Strict,
            Path = "/",
            Expires = now.AddDays(_jwt.RefreshTokenDays)
        });
    }

    public void ClearAuthCookies(HttpResponse response)
    {
        // Deletion must repeat the attributes the cookie was written with, or the browser
        // treats it as a different cookie and the original survives.
        response.Cookies.Delete(CookieNames.AccessToken, new CookieOptions
        {
            HttpOnly = true, Secure = true, SameSite = SameSiteMode.Strict, Path = "/"
        });

        response.Cookies.Delete(CookieNames.RefreshToken, new CookieOptions
        {
            HttpOnly = true, Secure = true, SameSite = SameSiteMode.Strict, Path = CookieNames.RefreshPath
        });

        response.Cookies.Delete(CookieNames.Csrf, new CookieOptions
        {
            HttpOnly = false, Secure = true, SameSite = SameSiteMode.Strict, Path = "/"
        });
    }
}
