# ---- build ----------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

# Copy the project file alone first so restore is cached independently of source
# changes; editing a .cs file then costs a compile, not a full package restore.
COPY LocationTracker.Api.csproj ./
RUN dotnet restore

COPY . ./
RUN dotnet publish -c Release -o /app/publish --no-restore /p:UseAppHost=false

# ---- runtime --------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
WORKDIR /app

# Needed by the compose healthcheck; the aspnet image ships neither curl nor wget.
# Installed before dropping privileges, and the apt lists are removed to keep the
# layer small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

# A container compromise should not also be root. The aspnet image ships this
# unprivileged account for exactly this purpose.
USER $APP_UID

COPY --from=build /app/publish ./

# TLS is terminated by nginx; inside the compose network this speaks plain HTTP.
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

ENTRYPOINT ["dotnet", "LocationTracker.Api.dll"]
