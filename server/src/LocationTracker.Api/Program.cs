using System.Text;
using LocationTracker.Api.Common;
using LocationTracker.Api.Data;
using LocationTracker.Api.Entities;
using LocationTracker.Api.Security;
using LocationTracker.Api.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSerilog((context, config) => config
    .ReadFrom.Configuration(context.Configuration)
    .Enrich.FromLogContext()
    .WriteTo.Console());

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------
builder.Services.Configure<JwtOptions>(builder.Configuration.GetSection(JwtOptions.SectionName));
builder.Services.Configure<TripDetectionOptions>(builder.Configuration.GetSection(TripDetectionOptions.SectionName));

var jwtOptions = builder.Configuration.GetSection(JwtOptions.SectionName).Get<JwtOptions>() ?? new JwtOptions();

// Fail at startup rather than issue tokens anyone can forge. HMAC-SHA256 needs at least
// 256 bits of key; a short or missing key is a deployment mistake, not a runtime condition.
if (Encoding.UTF8.GetByteCount(jwtOptions.SigningKey) < 32)
{
    throw new InvalidOperationException(
        "Jwt:SigningKey must be at least 32 bytes. Set it via the JWT__SIGNINGKEY environment variable.");
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------
builder.Services.AddDbContext<AppDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("Default")));

// ---------------------------------------------------------------------------
// Identity - API only. AddIdentityCore rather than AddIdentity: the latter registers the
// Identity.Application cookie scheme and makes it the default, which silently takes over
// from JwtBearer. No Razor Pages and no scaffolded Identity UI are wired up.
// ---------------------------------------------------------------------------
builder.Services
    .AddIdentityCore<ApplicationUser>(options =>
    {
        // Brute-force defence, layer one. Identity owns the counter; AuthService only has to
        // pass lockoutOnFailure: true.
        options.Lockout.MaxFailedAccessAttempts = 5;
        options.Lockout.DefaultLockoutTimeSpan = TimeSpan.FromMinutes(15);
        options.Lockout.AllowedForNewUsers = true;

        options.Password.RequiredLength = 12;
        options.Password.RequireDigit = true;
        options.Password.RequireLowercase = true;
        options.Password.RequireUppercase = true;
        options.Password.RequireNonAlphanumeric = true;

        options.User.RequireUniqueEmail = true;
        options.SignIn.RequireConfirmedAccount = false;
    })
    .AddRoles<ApplicationRole>()
    .AddEntityFrameworkStores<AppDbContext>()
    .AddSignInManager()
    .AddDefaultTokenProviders();

// The default is already PBKDF2-HMAC-SHA256; raising the iteration count above the shipped
// default keeps offline cracking of a leaked hash expensive.
builder.Services.Configure<PasswordHasherOptions>(options => options.IterationCount = 210_000);

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------
builder.Services
    .AddAuthentication(options =>
    {
        options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
        options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
    })
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = jwtOptions.Issuer,
            ValidAudience = jwtOptions.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtOptions.SigningKey)),

            // The default allows five minutes of grace, which meaningfully extends the life
            // of a 15-minute token.
            ClockSkew = TimeSpan.Zero
        };

        options.Events = new JwtBearerEvents
        {
            // JwtBearer only reads the Authorization header by default. The token lives in an
            // HttpOnly cookie precisely so script cannot reach it, so it is lifted here.
            OnMessageReceived = context =>
            {
                if (string.IsNullOrEmpty(context.Token) &&
                    context.Request.Cookies.TryGetValue(CookieNames.AccessToken, out var cookieToken))
                {
                    context.Token = cookieToken;
                }

                return Task.CompletedTask;
            }
        };
    });

builder.Services.AddApiAuthorization();

// ---------------------------------------------------------------------------
// Rate limiting, CORS
// ---------------------------------------------------------------------------
builder.Services.AddApiRateLimiting();

var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? Array.Empty<string>();

builder.Services.AddCors(options => options.AddDefaultPolicy(policy =>
{
    // AllowAnyOrigin is invalid alongside AllowCredentials, and cookie auth requires
    // credentials, so the origin list has to be explicit.
    policy.WithOrigins(allowedOrigins)
        .AllowAnyHeader()
        .AllowAnyMethod()
        .AllowCredentials();
}));

// X-Forwarded-* arrive from the nginx container. Without clearing KnownNetworks/KnownProxies
// the middleware ignores headers from an unrecognised proxy and RemoteIpAddress stays the
// container's, which would collapse every caller into one rate-limit partition.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownNetworks.Clear();
    options.KnownProxies.Clear();
});

// ---------------------------------------------------------------------------
// Application services
// ---------------------------------------------------------------------------
builder.Services.AddScoped<ITokenService, TokenService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<ITripDetector, TripDetector>();
builder.Services.AddScoped<ITripFinalizer, TripFinalizer>();
builder.Services.AddScoped<ILocationService, LocationService>();
builder.Services.AddSingleton<ICookieWriter, CookieWriter>();
builder.Services.AddHostedService<StaleTripSweeper>();

builder.Services.AddControllers()
    .AddJsonOptions(options =>
    {
        // Without this TripEndReason serializes as a bare 0/1/2, which forces every client to
        // hard-code the ordinal. Strings also match how the column is stored.
        options.JsonSerializerOptions.Converters.Add(
            new System.Text.Json.Serialization.JsonStringEnumConverter());
    });
builder.Services.AddHealthChecks().AddDbContextCheck<AppDbContext>();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
    options.SwaggerDoc("v1", new OpenApiInfo { Title = "Location Tracker API", Version = "v1" }));

var app = builder.Build();

// ---------------------------------------------------------------------------
// Migrate and seed
// ---------------------------------------------------------------------------
using (var scope = app.Services.CreateScope())
{
    var logger = scope.ServiceProvider.GetRequiredService<ILogger<Program>>();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();

    await db.Database.MigrateAsync();
    await IdentitySeeder.SeedAsync(scope.ServiceProvider, app.Configuration, logger);
}

// ---------------------------------------------------------------------------
// Pipeline. Order is load-bearing:
//   ForwardedHeaders must precede UseRateLimiter so partitions key on the real client IP.
//   CsrfMiddleware sits after authentication and before authorization.
// ---------------------------------------------------------------------------
app.UseForwardedHeaders();

app.UseMiddleware<ExceptionHandlingMiddleware>();

// Swagger is on in Development and opt-in elsewhere via Swagger:Enabled, so exposing the API
// surface is a deliberate deployment choice rather than a side effect of the environment name.
if (app.Environment.IsDevelopment() || app.Configuration.GetValue<bool>("Swagger:Enabled"))
{
    app.UseSwagger();
    app.UseSwaggerUI(options =>
        // The UI runs same-origin, so it can read the non-HttpOnly csrf_token cookie and echo it
        // as the double-submit header. Without this every "Try it out" POST fails with 403.
        options.UseRequestInterceptor(
            "(req) => { const m = document.cookie.match(/(?:^|; )csrf_token=([^;]*)/); " +
            "if (m) req.headers['X-CSRF-Token'] = decodeURIComponent(m[1]); return req; }"));
}

if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
}

// The admin live map (/admin/) is served by nginx from client/wwwroot, not by the API.

app.UseSerilogRequestLogging();

app.UseRateLimiter();
app.UseCors();

app.UseAuthentication();
app.UseMiddleware<CsrfMiddleware>();
app.UseAuthorization();

app.MapControllers();
app.MapHealthChecks("/health").AllowAnonymous();

app.Run();

/// <summary>Exposed so an integration test project can drive the app via WebApplicationFactory.</summary>
public partial class Program { }
